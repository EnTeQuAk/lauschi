/// Cross-provider playback smoke tests.
///
/// Single-test design: one patrolTest authenticates all providers, seeds
/// the DB with known content, then runs the same playback suite (play
/// starts, duration populated, pause snapshot, position advances after
/// resume) against ARD, Spotify, and Apple Music in sequence inside ONE
/// app launch.
///
/// Why one big test instead of one-per-behavior:
/// - The AndroidX Test Orchestrator runs each patrolTest method in a
///   fresh instrumentation process, cold-starting the app each time.
///   On a Fairphone 6 that's roughly 30-60s of overhead per test method
///   for service init, provider auth check, and WebView warm-up,
///   dwarfing the actual assertion work.
/// - Splitting into 12+ tests pushed total runtime past 25 minutes with
///   no improvement in signal: a failure in "play starts" would already
///   tell us "this provider's playback is broken" without needing the
///   subsequent assertions to also fail.
/// - Sharing one playback session per provider also dodges Spotify and
///   Apple Music SDK position-state caching across playCard restarts
///   (see commentary on `_runPlaybackSuite`).
///
/// Why not batched (3 patrolTests, one per provider)?
/// We considered three patrolTests as a middle ground: ARD, Spotify,
/// Apple Music. It buys some CI granularity but each test pays the
/// orchestrator cold-start tax (~30-60s) and still re-runs auth + DB
/// seed. Total ~3-4 minutes vs ~37s for one test, with the same blast
/// radius on failure: a Spotify SDK glitch in test 2 still tells us
/// nothing about Apple Music in test 3. The labeled `print` markers
/// inside this single test give us per-provider granularity in CI logs
/// without paying the orchestrator price.
///
/// Tradeoff: if one assertion fails, subsequent assertions for the same
/// provider don't run. The test prints labeled progress markers so CI
/// logs pinpoint exactly which behavior failed.
///
/// Content uses stable URIs from `assets/catalog/series.yaml`:
/// - Spotify: Die drei ??? Folge 1 (album, won't disappear)
/// - Apple Music: Asterix Folge 1 (album, won't disappear)
/// - ARD: Ohrenbär episode (discovered at runtime; audio URLs expire)
///
///
/// Spotify and Apple Music require pre-authentication on the device:
/// run `mise run dev` and log into both providers before the first
/// integration run. Tokens persist in FlutterSecureStorage across
/// `mise run test-integration` invocations because we set
/// `clearPackageData=false` in build.gradle.kts. The test calls
/// `clearAppState()` early to wipe the SQLite DB so leftover content
/// from previous tests doesn't poison count assertions.
library;

// Integration test diagnostic output. Routed through print to keep
// progress visible in `patrol test` stdout, separate from production
// Log/Sentry plumbing.
// ignore_for_file: avoid_print

import 'dart:async' show unawaited;

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

// ── Stable content from assets/catalog/series.yaml ─────────────────────────

// Spotify: Die drei ??? Folge 1
const _spotifyUri = 'spotify:album:4N9tvSjWfZXx3eHKblYEWQ';
const _spotifyTitle = '001/und der Super-Papagei';

// Apple Music: Asterix Folge 1
const _appleMusicAlbumId = '1686063678';
const _appleMusicUri = 'apple_music:album:$_appleMusicAlbumId';
const _appleMusicTitle = '01: Asterix der Gallier';

// ARD: Ohrenbär (rbb). 600+ short episodes, always available.
// Audio URLs expire, so we discover a fresh episode at setup time.
const _ardShowId = '25705746';
const _ardShowTitle = 'Ohrenbär';
const _minEpisodeDuration = 30; // seconds

// ── Auth helpers ───────────────────────────────────────────────────────────

/// Result of an auth check. Distinguishes "ready to use" from the
/// different ways auth can fail, so skip messages in CI logs explain
/// what happened instead of just "not authenticated".
enum _AuthResult {
  /// Provider is authenticated and ready to play.
  ok,

  /// No tokens found in FlutterSecureStorage. The user never logged in
  /// on this device, or `clearPackageData` wiped them. Fix: run
  /// `mise run dev` and log into the provider.
  notLoggedIn,

  /// Token refresh or `connect()` produced an error state. Tokens may
  /// be revoked, the network may be down, or the provider's auth
  /// service may be misbehaving.
  errored,

  /// Auth state never settled within the timeout. Most likely a network
  /// hang or a provider SDK that isn't responding.
  timedOut,
}

/// Human-readable message for a non-OK auth result, used in skip prints.
String _authReason(_AuthResult r, String provider) => switch (r) {
  _AuthResult.ok => 'authenticated',
  _AuthResult.notLoggedIn =>
    'no stored credentials. Run `mise run dev` and log into $provider.',
  _AuthResult.errored => 'auth state errored (refresh failed or revoked).',
  _AuthResult.timedOut =>
    'auth state never settled within the timeout '
        '(network hang or provider SDK stuck).',
};

/// Wait for Spotify to auto-authenticate from stored tokens.
/// Fast-fails when state is terminal (Unauthenticated/Error).
Future<_AuthResult> _waitForSpotify(
  PatrolIntegrationTester $, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final container = getContainer($);
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    final state = container.read(spotifySessionProvider);
    if (state is SpotifyAuthenticated) return _AuthResult.ok;
    if (state is SpotifyUnauthenticated) return _AuthResult.notLoggedIn;
    if (state is SpotifyError) return _AuthResult.errored;
    await $.pump(const Duration(milliseconds: 500));
  }
  return _AuthResult.timedOut;
}

/// Wait for Apple Music to auto-authenticate from stored tokens.
/// On Android, triggers `connect()` if stored tokens aren't found
/// (auto-completes without user interaction via MusicKit JS).
Future<_AuthResult> _waitForAppleMusic(
  PatrolIntegrationTester $, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  final container = getContainer($);

  // Give _initAndroid a moment to load stored tokens.
  await $.pump(const Duration(seconds: 2));

  // If auto-load didn't authenticate, trigger connect(). On Android the
  // connect flow auto-completes via MusicKit JS without user interaction
  // when stored web tokens are present.
  if (container.read(appleMusicSessionProvider) is! AppleMusicAuthenticated) {
    unawaited(container.read(appleMusicSessionProvider.notifier).connect());
  }

  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    final state = container.read(appleMusicSessionProvider);
    if (state is AppleMusicAuthenticated) return _AuthResult.ok;
    if (state is AppleMusicUnauthenticated) return _AuthResult.notLoggedIn;
    if (state is AppleMusicError) return _AuthResult.errored;
    // AppleMusicLoading: keep polling.
    await $.pump(const Duration(milliseconds: 500));
  }
  return _AuthResult.timedOut;
}

// ── Combined playback suite ────────────────────────────────────────────────
//
// One play session per provider. All behaviors are observed within a
// SINGLE continuous playback session. This avoids cross-call state
// issues that bit the original test:
//
// - Spotify Web Playback SDK: the bridge's position state persists
//   across playCard calls. Restarting playback on the same album leaves
//   the bridge filtering low positions as "backwards jitter" until the
//   SDK catches up to the previous position.
// - Apple Music DRM/WebView: the MusicKit JS pipeline degrades after
//   repeated cold restarts (the original flakiness this rewrite targets).
//
// Position-advance is verified by the pause→resume sequence rather than
// a standalone "position increases over time" check, because:
//
// - Spotify Web Playback SDK only emits `player_state_changed` events on
//   actual state changes (play/pause/seek/track change), NOT periodically.
//   `playerProvider.positionMs` is therefore frozen between state events.
//   The UI smooths this with a local Ticker (see `interpolated_progress.dart`),
//   but the raw provider value can't be polled to observe natural advance.
// - Same applies to Apple Music's MusicKit JS event stream.
// - just_audio (ARD) DOES emit periodic position events, but for
//   consistency we use the same assertion shape across all providers.
//
// Pause/resume gives us TWO discrete state events, which forces the SDK
// to emit two position values: pre-pause and post-resume. The post-resume
// position is observably higher than pre-pause, which proves playback is
// actually progressing.

/// Run the full playback assertion suite for one provider in a single
/// playback session. Each labeled step prints to stdout so CI logs
/// pinpoint exactly which behavior failed.
Future<void> _runPlaybackSuite(
  PatrolIntegrationTester $,
  String label,
  String itemId,
) async {
  final container = getContainer($);
  final notifier = container.read(playerProvider.notifier);

  // Fresh start: clear any saved position so playCard restarts from 0
  // instead of resuming where the previous suite left off.
  await container
      .read(tileItemRepositoryProvider)
      .resetPlaybackPosition(itemId);

  // ── 1. Play starts ───────────────────────────────────────────────────
  print('▶ [$label] play starts');
  expect(
    container.read(playerProvider).activeCardId,
    isNot(itemId),
    reason: '[$label] precondition: this card not active',
  );

  unawaited(notifier.playCard(itemId));
  await waitForPlayback($, timeout: const Duration(seconds: 45));

  final started = container.read(playerProvider);
  expect(started.isPlaying, isTrue, reason: '[$label] isPlaying after start');
  expect(started.activeCardId, itemId, reason: '[$label] activeCardId set');
  expect(started.error, isNull, reason: '[$label] no error after start');
  expect(started.track, isNotNull, reason: '[$label] track metadata set');
  // resetPlaybackPosition above must have actually cleared the saved
  // position. If it didn't, the playback state would inherit the
  // previous suite's position and the pause-resume math below would lie.
  expect(
    started.positionMs,
    lessThan(2000),
    reason:
        '[$label] fresh start: position should be near 0 right after '
        'playCard, got ${started.positionMs}ms',
  );

  // ── 2. Duration populated ────────────────────────────────────────────
  //
  // All three test items (Die drei ??? Folge 1, Asterix Folge 1,
  // Ohrenbär episode) are at least ~30 seconds long. A duration below
  // that means the provider returned a nonsense placeholder, not a
  // real track length, and we should fail the test instead of accepting
  // it just because it's `>0`.
  print('▶ [$label] duration populated');
  await waitForCondition(
    $,
    () async => container.read(playerProvider).durationMs >= 30000,
    description: '[$label] duration >=30s',
    timeout: const Duration(seconds: 10),
  );

  // ── 3. Pause emits a non-zero position ───────────────────────────────
  //
  // For Spotify and Apple Music, position is ONLY updated when the SDK
  // emits a state event. There are no periodic position events while
  // playing — the UI uses a local Ticker (`InterpolatedProgress`) to
  // animate between discrete state events.
  //
  // The pause command forces the SDK to fire a state event, and the
  // native side reads the live `player.currentPosition` at that moment.
  // So the value we read AFTER waitForPause is the player's actual
  // position at pause time, which proves audio was advancing.
  //
  // Letting real audio play for a few seconds before pausing makes the
  // assertion meaningful: a non-zero position after 3s of playback
  // proves the player is actually progressing through the track.
  print('▶ [$label] pause, resume, position advances');
  // Pump 5 seconds of real time before pausing. The first ~1.5s is
  // typically eaten by Spotify SDK / Apple Music DRM startup before
  // audio actually begins, so 5s gives us ~3.5s of real playback to
  // assert against.
  await $.pump(const Duration(seconds: 5));

  await notifier.pause();
  await waitForPause($);

  final pausedPos = container.read(playerProvider).positionMs;
  // After ~5s of real time, real playback should have advanced ≥2s.
  // The lower bound is loose to absorb startup jitter but tight enough
  // to catch a stuck-at-zero counter.
  expect(
    pausedPos,
    greaterThan(2000),
    reason:
        '[$label] paused position should be >2s after 5s of playback '
        '(got ${pausedPos}ms)',
  );

  // Position must not advance while paused.
  await $.pump(const Duration(seconds: 1));
  expect(
    currentPositionMs($),
    closeTo(pausedPos, 500),
    reason: '[$label] position stable while paused',
  );

  // Resume, let it play, pause again to sample position. The second
  // pause forces another state event, giving us a fresh position
  // snapshot we can compare against pausedPos.
  await notifier.resume();
  await waitForPlayback($);
  await $.pump(const Duration(seconds: 3));

  await notifier.pause();
  await waitForPause($);

  final resumedPos = container.read(playerProvider).positionMs;
  expect(
    resumedPos,
    greaterThan(pausedPos + 1000),
    reason:
        '[$label] position should advance ≥1s during resumed playback '
        '(was ${pausedPos}ms, now ${resumedPos}ms)',
  );

  expect(
    container.read(playerProvider).error,
    isNull,
    reason: '[$label] no error after resume',
  );

  // ── Cleanup ──────────────────────────────────────────────────────────
  await stopPlayback($);
  print('✓ [$label] all assertions passed');
}

// ── The single big test ────────────────────────────────────────────────────

void main() {
  patrolTest(
    'cross-provider playback (ARD + Spotify + Apple Music)',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});

      // Wipe DB before anything else: with `clearPackageData=false` the
      // SQLite file persists across patrolTests, so leftover content from
      // the previous test run could survive into ours.
      await clearAppState($);

      final container = getContainer($);

      // Sanity: DB really is empty before we start seeding.
      expect(
        await container.read(tileRepositoryProvider).getAllFlat(),
        isEmpty,
        reason: 'clearAppState should leave 0 tiles',
      );
      expect(
        await container.read(tileItemRepositoryProvider).getAll(),
        isEmpty,
        reason: 'clearAppState should leave 0 items',
      );

      // ── Auth check ──────────────────────────────────────────────────────

      print('▶ Setup: checking provider auth');
      final spotifyAuth = await _waitForSpotify($);
      final appleMusicAuth = await _waitForAppleMusic($);
      final spotifyOk = spotifyAuth == _AuthResult.ok;
      final appleMusicOk = appleMusicAuth == _AuthResult.ok;
      print(
        '  spotify=${_authReason(spotifyAuth, "Spotify")}',
      );
      print(
        '  appleMusic=${_authReason(appleMusicAuth, "Apple Music")}',
      );

      // ── ARD episode discovery ───────────────────────────────────────────

      print('▶ Setup: discovering ARD episodes');
      final ardApi = container.read(ardApiProvider);
      final page = await ardApi.getItems(
        programSetId: _ardShowId,
        first: 10,
      );
      final episodes =
          page.items
              .where(
                (e) =>
                    e.bestAudioUrl != null && e.duration >= _minEpisodeDuration,
              )
              .take(2)
              .toList();
      if (episodes.length < 2) {
        fail(
          'Need 2+ playable $_ardShowTitle episodes, '
          'got ${episodes.length}.',
        );
      }
      print('  found ${episodes.length} episodes');

      // ── DB seeding ──────────────────────────────────────────────────────
      //
      // We seed exactly one tile + one item per available provider.
      // We deliberately do NOT seed nested-folder content here even
      // though the catalog has Folge 2 entries for Spotify and Apple
      // Music. Folder navigation tests are a separate concern and
      // should seed their own data when they're written. Keeping that
      // dead code here is YAGNI.

      print('▶ Setup: seeding DB');
      final items = container.read(tileItemRepositoryProvider);
      final tiles = container.read(tileRepositoryProvider);
      // DB was already wiped via clearAppState() above.

      // ARD (always available — no auth)
      final ardTileId = await tiles.insert(title: _ardShowTitle);
      final ardItemId = await items.insertArdEpisode(
        title: episodes[0].title,
        providerUri: episodes[0].providerUri,
        audioUrl: episodes[0].bestAudioUrl!,
        durationMs: episodes[0].duration * 1000,
        tileId: ardTileId,
      );

      String? spotifyItemId;
      if (spotifyOk) {
        final spotifyTileId = await tiles.insert(title: 'Die drei ???');
        spotifyItemId = await items.insertIfAbsent(
          title: _spotifyTitle,
          providerUri: _spotifyUri,
          cardType: 'album',
        );
        await items.assignToTile(
          itemId: spotifyItemId,
          tileId: spotifyTileId,
        );
      }

      String? amItemId;
      if (appleMusicOk) {
        final amTileId = await tiles.insert(title: 'Asterix');
        amItemId = await items.insertIfAbsent(
          title: _appleMusicTitle,
          providerUri: _appleMusicUri,
          cardType: 'album',
          provider: ProviderType.appleMusic,
        );
        await items.assignToTile(itemId: amItemId, tileId: amTileId);
      }

      await pumpFrames($);

      // ── Verify the seed actually landed ────────────────────────────────
      //
      // If a repository bug or constraint violation silently swallows an
      // insert, the playback suites later fail with a confusing "item
      // not found" rather than a clear "seed produced 0 items". These
      // assertions catch that.

      final expectedItemCount =
          1 + (spotifyOk ? 1 : 0) + (appleMusicOk ? 1 : 0);
      final allItems = await items.getAll();
      expect(
        allItems,
        hasLength(expectedItemCount),
        reason:
            'Seed should produce $expectedItemCount items '
            '(1 ARD + Spotify? + AppleMusic?)',
      );

      final allTiles = await tiles.getAllFlat();
      expect(
        allTiles,
        hasLength(expectedItemCount),
        reason: 'One tile per seeded item',
      );

      // ARD episode is the linchpin — it always exists. Verify the
      // round-trip from insertArdEpisode to getById preserved the data.
      final ardItem = await items.getById(ardItemId);
      expect(ardItem, isNotNull, reason: 'ARD item must be retrievable');
      expect(
        ardItem!.audioUrl,
        episodes[0].bestAudioUrl,
        reason: 'ARD audio URL must round-trip through DB',
      );
      expect(
        ardItem.providerUri,
        episodes[0].providerUri,
        reason: 'ARD providerUri must round-trip through DB',
      );

      if (spotifyOk) {
        final spotifyItem = await items.getByProviderUri(_spotifyUri);
        expect(
          spotifyItem,
          isNotNull,
          reason: 'Spotify item must be retrievable by URI',
        );
      }
      if (appleMusicOk) {
        final amItem = await items.getByProviderUri(_appleMusicUri);
        expect(
          amItem,
          isNotNull,
          reason: 'Apple Music item must be retrievable by URI',
        );
      }

      print('  DB seeded ($expectedItemCount items, $expectedItemCount tiles)');

      // ── Run playback suites ─────────────────────────────────────────────

      await _runPlaybackSuite($, 'ARD', ardItemId);

      if (spotifyOk && spotifyItemId != null) {
        await _runPlaybackSuite($, 'Spotify', spotifyItemId);
      } else {
        print(
          '⏭ Skipping Spotify suite: '
          '${_authReason(spotifyAuth, "Spotify")}',
        );
      }

      if (appleMusicOk && amItemId != null) {
        await _runPlaybackSuite($, 'Apple Music', amItemId);
      } else {
        print(
          '⏭ Skipping Apple Music suite: '
          '${_authReason(appleMusicAuth, "Apple Music")}',
        );
      }

      print('✓ All playback suites complete');
    },
  );
}
