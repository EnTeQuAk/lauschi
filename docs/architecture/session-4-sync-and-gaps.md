# Architecture Planning Session 4: Sync Model & Remaining Gaps

Sessions 1-3 converged well. This session corrects one wrong assumption and probes the remaining design gaps before we consolidate a final plan.

## Correction: Music streaming content is NOT static

In session 3 you said:
> "Music streaming content is static (albums don't change)"
> "Spotify: Not practical. No push mechanism, strict rate limits, albums are static."

This is wrong for Hörspiel. Active series get new albums regularly:
- **Die drei ??? Kids**: new Folge every 2-3 months (album per episode)
- **TKKG**: new Folge every 2-3 months
- **Ninjago**: ongoing releases tied to TV seasons
- **Bibi & Tina**: new albums quarterly
- **Fünf Freunde**: ongoing

When a parent subscribes to "TKKG" on Spotify or Apple Music, they expect new Folgen to appear in the tile automatically, just like new ARD episodes appear via show subscription sync.

**This means sync should work for all providers**, not just ARD. The mechanism differs:
- **ARD**: Poll programSet for new items (efficient, has `lastItemAdded` change detection)
- **Spotify/Apple Music/Tidal**: Poll artist discography for new albums matching the series keywords + episode pattern. Compare against existing `TileItem` providerUris to find new ones.

The `ShowSubscriptions` table already has `provider`, `externalShowId`, `lastSyncedAt`, and `remoteLastItemAdded`. For music streaming, `externalShowId` would be the artist ID, and sync means "query this artist's albums, match with catalog keywords, insert new ones".

**Questions for you:**
1. Is this a fundamental change to the sync architecture, or just a different sync implementation per provider?
2. Should the sync interval differ per provider? (ARD daily, Spotify weekly?)
3. Rate limits: Spotify allows 100 req/30sec. If a user subscribes to 20 series, that's 20 artist lookups per sync. Feasible?

## Gap 1: The `PlayerBackend.play()` question (still unresolved)

In session 2, we agreed that `PlayerNotifier` handles startup branching and backends handle uniform operations. But we never defined the `play()` contract clearly.

Current reality:
```dart
// ARD (DirectPlayer):
await directPlayer.play(audioUrl: url, trackInfo: info, positionMs: saved);

// Spotify (SpotifyBackend):
// There IS no play() on the backend. PlayerNotifier calls:
await _api.play(deviceId: bridge.deviceId, contextUri: uri, offset: trackNumber);
// Then the bridge reports state changes via stateStream
```

So the startup is fundamentally asymmetric:
- DirectPlayer: backend owns the play command
- SpotifyBackend: play goes through Web API, backend just listens

For Apple Music via `music_kit`:
```dart
await musicKit.setQueue('albums', item: albumJson);
await musicKit.play();
// Then listen to onMusicPlayerStateChanged
```

This is closer to the Spotify pattern -- you command the SDK, then listen for state.

**Proposed resolution**: `PlayerBackend` should NOT have a `play()` method at all. The play/start sequence is provider-specific and lives in `PlayerNotifier`. The backend interface is only for:
- `pause()`, `resume()`, `seek()`, `stop()`, `dispose()`
- `stateStream` (what's happening right now)
- `currentPositionMs`, `currentTrackNumber`, `hasNextTrack`

This is actually what we have today. The `DirectPlayer.play()` method is NOT on the `PlayerBackend` interface -- it's a concrete method called by `PlayerNotifier`. Same for `SpotifyBackend`'s play path through the Web API.

Do you agree this is the right split? Or should we try harder to unify the play command?

## Gap 2: Backend creation and lifecycle

Currently `PlayerNotifier.playCard()` creates backends inline:

```dart
if (card.provider == 'spotify') {
  final backend = SpotifyBackend(_bridge, _api);
  // ... call Spotify Web API to start playback ...
  _active = _ActiveBackend(backend, backend.stateStream.listen(...));
} else {
  final backend = DirectPlayer();
  await backend.play(audioUrl: card.audioUrl!, ...);
  _active = _ActiveBackend(backend, backend.stateStream.listen(...));
}
```

For multi-provider, this branching grows. Options:

**Option A: Factory method on PlayerNotifier** (current, just extend the if/else)
```dart
PlayerBackend _createBackend(TileItem card) {
  return switch (card.provider) {
    'spotify' => SpotifyBackend(_bridge, _api),
    'ard_audiothek' => DirectPlayer(),
    'apple_music' => AppleMusicBackend(_musicKit),
    _ => throw StateError('Unknown provider: ${card.provider}'),
  };
}
```

**Option B: Provider registry with factory**
```dart
class ProviderRegistry {
  PlayerBackend createBackend(ProviderType type) { ... }
  Future<void> startPlayback(PlayerBackend backend, TileItem card) { ... }
}
```

**Option C: Keep it in PlayerNotifier, use a switch expression**

Option A/C are essentially the same and match KISS. Option B adds a layer that might not pay for itself. Your call?

## Gap 3: What does the final catalog YAML look like?

We agreed on series-level identifiers. But I want to nail down the exact schema before implementation. Here's my concrete proposal:

```yaml
series:
  - id: tkkg
    title: TKKG
    aliases: ["TKKG -"]
    keywords: [tkkg]
    episode_pattern: '(?:Folge|Episode)\s+(\d+)'
    cover_url: https://...
    
    # Provider identifiers for discovery AND sync
    providers:
      spotify:
        artist_ids: ["0bDd9k1a8s6y3K8z1b9s3K"]
      apple_music:
        artist_id: "123456789"
      tidal:
        artist_id: "56789"
      ard_audiothek:
        program_set_id: "12345"
```

Questions:
- Should the catalog also store per-provider `episode_pattern` overrides? (Spotify titles format differently than ARD titles)
- Should `cover_url` be per-provider? (Different artwork sources)
- Should the `albums:` field (pre-validated Spotify albums) remain for backwards compat, or rip it out?

## Gap 4: ProviderType as enum vs string

Session 3 proposed `ProviderType` enum. But the DB stores strings ('spotify', 'ard_audiothek'). And the catalog YAML uses strings too.

Options:
- **Enum in Dart, string in DB/YAML**: Convert at boundaries. Type-safe in code, flexible in data.
- **String everywhere**: No conversion needed, but typos possible.

I lean toward enum in Dart with string serialization. What's your take?

## What I want from this session

1. Updated sync model that accounts for music streaming series getting new releases
2. Final answer on `PlayerBackend.play()` -- unified or not
3. Backend creation pattern recommendation
4. Finalized catalog YAML schema
5. ProviderType decision
