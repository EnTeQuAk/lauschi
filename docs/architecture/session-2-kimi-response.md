cd /home/chris/Projects/lauschi && pi --model kimi-k2.5 --thinking xhigh -p - < /tmp/kimi-architecture-session-2.md
[chris@desky lauschi]$ cd /home/chris/Projects/lauschi && pi --model kimi-k2.5 --thinking xhigh -p - < /tmp/kimi-architecture-session-2.md
Warning: No models match pattern "opencode/kimi-k2.5-free"
 You're raising excellent points. Let me work through each one honestly.

---

## 1. Flat Table vs Normalized — You're Right

Your reasoning is sound. We query `TileItem` by ID, not by provider-specific fields. The current nullable columns (`audioUrl`, `spotifyArtistIds`) work fine. Adding `appleMusicId`, `tidalId` as nullable strings is simpler than joins.

**Where I was wrong**: I was premature-optimizing for "clean schema" at the cost of maintenance burden. For a side project with ~4 providers, 8-10 nullable columns is not technical debt—it's pragmatic schema design.

**Resume state stays flat too**: `lastPositionMs` is universal. `lastTrackIndex` covers multi-track for Apple Music/Spotify; it's NULL for ARD single-track. One table, one row per `TileItem`.

---

## 2. `providerDataJson` — Agreed, Anti-Pattern

Kill it. Either real columns or nothing. If we need extensibility later, we add a migration. SQLite migrations in Drift are straightforward.

---

## 3. Cross-Provider Identity — You're Right, It's Hard

Your revised thinking is correct. Cross-provider resume is nice-to-have, not MVP requirement. Each `TileItem` is a distinct content instance with its own resume state.

Parent adds "TKKG Folge 5" from Apple Music → one `TileItem` with `provider=apple_music`.
Parent also adds ARD version → separate `TileItem` with `provider=ard`.
Kid plays each independently. Resume state is per-`TileItem`.

This eliminates:
- Complex episode number normalization across providers
- "Sonderfolgen" edge cases
- Remastered vs original edition confusion

Catalog YAML maps series → provider identifiers for *discovery*. Episode resolution is runtime per-provider.

---

## 4. CatalogProvider Interface — Needs Redesign

Your questions expose the flaws. Let me rethink:

```dart
/// Per-provider episode result from search or browse
@immutable
class CatalogEpisode {
  final String providerUri;     // 'ard://episode/12345' or 'apple://track/67890'
  final String title;
  final String? episodeNumber;  // Extracted or null
  final String? seriesId;       // Catalog canonical ID if matched, else null
  final String? coverUrl;
  final Duration? duration;
}

/// Provider-specific browse capabilities (ARD has kids shows, Apple has genres)
abstract class CatalogBrowseDelegate {
  Future<List<CatalogEpisode>> browseKidsShows();
  Future<List<CatalogEpisode>> browseBySeries(String catalogSeriesId);
}

/// Core interface - every provider implements
abstract class CatalogProvider {
  ProviderType get type;
  
  /// Discovery: search across provider's catalog
  Future<List<CatalogEpisode>> search(String query);
  
  /// Optional: provider-specific browse (ARD kids shows, Apple genres)
  CatalogBrowseDelegate? get browseDelegate;
}
```

Key decisions here:
- `providerUri` is the provider's native identifier wrapped in a URI scheme (makes it typed and unambiguous)
- `seriesId` in results is the *catalog's* canonical ID when the provider's episode matches a known series via `episode_pattern`
- Browse is opt-in via delegate—providers expose what they support
- No `resolve()` here—that belongs in playback layer

---

## 5. PlayerBackend Naming and Responsibilities

Stick with `PlayerBackend` (matches current codebase).

You're right about the split. `play()` startup differs too much per provider:

```dart
/// Backend handles uniform lifecycle operations
abstract class PlayerBackend {
  ProviderType get type;
  
  /// Current playback state
  PlaybackState get state;
  Stream<PlaybackState> get stateStream;
  
  /// Uniform controls (every provider supports these)
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> dispose();
}

/// Provider-specific initialization is OUTSIDE this interface
/// PlayerNotifier handles the divergence:
/// 
/// ARD:    lookup audioUrl → create DirectPlayer backend → backend.play()
/// Apple:  lookup appleMusicId → MusicKit queue → backend tracks SDK state
/// Spotify: call Web API /me/player/play → backend listens to bridge events
```

This preserves your current architecture: `PlayerNotifier` has provider-specific branching for startup, then delegates uniform operations to `PlayerBackend`.

---

## 6. Auth Lifecycle — Needs `configure()`, Not Just `getToken`

```dart
abstract class AuthProvider {
  ProviderType get type;
  
  /// Human-readable name for UI ("Apple Music", "Spotify")
  String get displayName;
  
  /// One-time setup (API keys, developer tokens, etc)
  /// Called at app startup or when provider is first enabled
  Future<void> configure();
  
  /// Whether user has completed OAuth/token flow
  bool get isAuthenticated;
  
  /// Trigger OAuth flow or platform auth (MusicKit)
  /// Returns true if successful
  Future<bool> authenticate();
  
  /// Clear tokens/credentials
  Future<void> logout();
  
  /// Valid token for API calls (null if isAuthenticated is false)
  /// For providers without auth (ARD), always returns empty/placeholder
  Future<AuthToken?> getValidToken();
}

class AuthToken {
  final String accessToken;
  final DateTime? expiresAt;
  final String? refreshToken;
}
```

Apple Music specifics handled in implementation:
- `configure()`: fetch developer JWT from your server
- `authenticate()`: call `MusicKit.requestUserToken()`
- `getValidToken()`: returns both developer + user token combined for API calls

ARD implementation is trivial:
- `configure()`: noop
- `isAuthenticated`: always true
- `authenticate()`: always true
- `getValidToken()`: returns placeholder

---

## 7. Catalog YAML — Series-Level Only, Runtime Discovery

You're absolutely right. Per-episode mappings are unmaintainable.

```yaml
series:
  - id: tkkg
    title: TKKG
    keywords: [tkkg, "TKKG - "]  # Match tokens for keyword search
    episode_pattern: '(?:Folge|Episode)\\s+(\\d+)'
    cover_override: tkkg_cover.png  # Optional custom tile image
    
    providers:
      spotify:
        artist_ids: ["0bDd9k1a8s6y3K8z1b9s3K"]
        # Episode matching: album titles containing keyword + artist match
        
      apple_music:
        artist_id: "123456789"
        # Episode matching: track titles matching episode_pattern
        
      ard_audiothek:
        program_set_id: "12345"
        # Episode matching: items in programSet, titles match episode_pattern
        
      tidal:
        artist_id: "56789"
        # Future: similar pattern
```

**Episode discovery at runtime**:
1. User searches "TKKG" → hits catalog series match
2. `CatalogService.getEpisodes('tkkg')` queries enabled providers:
   - ARD: `ArdApi.getEpisodesForProgramSet('12345')`
   - Apple Music: search tracks by artist "123456789", filter by `episode_pattern`
   - Spotify: search albums by artist, filter by `episode_pattern`
3. Each provider returns `CatalogEpisode` list with `providerUri`, `title`, `episodeNumber`
4. UI shows unified list with provider badges

No per-episode YAML. No 16,000 line files. Series metadata only.

---

## 8. Offline Content — Acknowledge but Don't Build

Add a placeholder for future, but don't architect for it now:

```dart
enum ProviderType {
  ard,
  spotify,
  appleMusic,
  tidal,
  // local, // Future: downloaded files
}
```

The `PlayerBackend` interface works for local files (just a different URI scheme). Don't build the UI or sync logic yet.

---

## Summary Decisions

| Decision | Direction |
|----------|-----------|
| Database | Single `TileItem` table, nullable provider-specific columns |
| Cross-provider resume | No—each `TileItem` has independent resume state |
| CatalogProvider | Search + optional browse delegate, `providerUri` for identity |
| PlayerBackend | Uniform controls only, `PlayerNotifier` handles startup divergence |
| AuthProvider | `configure()` for setup, `authenticate()` for user auth |
| Catalog YAML | Series-level provider identifiers only, runtime episode discovery |
| Offline | Acknowledge as future `local` provider, don't build |

This supports ARD (no auth, direct HTTP, browse kids shows) + Apple Music (dev token + user token, MusicKit SDK, genre browse) without over-building for Tidal.

Sound right? Want me to draft the actual Dart files with these interfaces?
[chris@desky lauschi]$ 
