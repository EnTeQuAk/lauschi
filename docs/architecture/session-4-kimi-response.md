cd /home/chris/Projects/lauschi && pi --model kimi-k2.5 --thinking xhigh -p - < /tmp/kimi-architecture-session-4.md
[chris@desky lauschi]$ cd /home/chris/Projects/lauschi && pi --model kimi-k2.5 --thinking xhigh -p - < /tmp/kimi-architecture-session-4.md
Warning: No models match pattern "opencode/kimi-k2.5-free"
 You've identified the core insight: **sync architecture is unified, implementations vary by provider.** This isn't a fundamental change—it's exactly what `ShowSubscriptions` was designed for.

Let me work through each gap:

## 1. Sync Model (Correction Accepted)

You're right. The `ShowSubscriptions` table already supports this:

| Field | ARD Usage | Spotify Usage |
|-------|-----------|---------------|
| `provider` | `'ard_audiothek'` | `'spotify'` |
| `externalShowId` | `programSetId` | `artistId` |
| `lastSyncedAt` | timestamp | timestamp |
| `remoteLastItemAdded` | `lastItemAdded` | `latestReleaseDate` (or null) |

**Sync intervals per provider:**
- ARD: Daily (efficient `lastItemAdded` check, cheap)
- Spotify: Weekly (album releases are predictable, rate limits)
- Apple Music: Weekly
- Tidal: Weekly (if we add it)

**Rate limits:** 20 series × 1 request = 20 requests. Spotify's 100/30sec limit gives us 5× headroom. Feasible.

**Implementation:** Different `SyncStrategy` classes registered by provider type. Same table, same scheduler, different query logic.

## 2. `PlayerBackend.play()` — Your Proposed Resolution is Correct

Agreed. `PlayerBackend` should **not** have `play()`. The interface is:

```dart
abstract class PlayerBackend {
  Stream<PlayerState> get stateStream;
  int get currentPositionMs;
  int? get currentTrackNumber;
  bool get hasNextTrack;
  
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(int positionMs);
  Future<void> stop();
  Future<void> dispose();
}
```

Startup is `PlayerNotifier`'s job:

```dart
// In PlayerNotifier.playCard()
switch (card.provider) {
  case ProviderType.spotify:
    // Call Web API directly, then attach SpotifyBackend listener
  case ProviderType.ardAudiothek:
    // Create DirectPlayer, call .play() with URL
  case ProviderType.appleMusic:
    // Call music_kit setQueue+play, then attach AppleMusicBackend listener
}
```

This matches reality: you can't abstract away "how do I start playing this provider's content" without creating a leaky abstraction.

## 3. Backend Creation — Option A/C (Switch in PlayerNotifier)

Keep it simple. No registry.

```dart
PlayerBackend _createBackend(TileItem card, PlayerNotifier notifier) {
  return switch (card.provider) {
    ProviderType.spotify => SpotifyBackend(_bridge, notifier),
    ProviderType.ardAudiothek => DirectPlayer(),
    ProviderType.appleMusic => AppleMusicBackend(_musicKit, notifier),
  };
}
```

The provider-specific startup sequence lives in `playCard()` anyway, so the backend creation is just one line of that sequence.

## 4. Catalog YAML Schema

Your schema is good. Minor refinements:

```yaml
series:
  - id: tkkg
    title: TKKG
    aliases: ["TKKG -"]
    keywords: [tkkg]
    episode_pattern: '(?:Folge|Episode)\s+(\d+)'
    cover_url: https://...  # Default/fallback
    
    providers:
      spotify:
        artist_ids: ["0bDd9k1a8s6y3K8z1b9s3K"]
        episode_pattern: 'TKKG\s+Folge\s+(\d+)'  # Optional override
        cover_url: https://...  # Optional provider-specific
      apple_music:
        artist_id: "123456789"
      ard_audiothek:
        program_set_id: "12345"
        episode_pattern: 'Episode\s+(\d+)'  # ARD uses different naming
```

**Per-provider episode_pattern:** Yes, include it. Spotify titles often include series name ("TKKG Folge 123") while ARD might just be "Folge 123".

**Per-provider cover_url:** Optional. Most series use same artwork, but some providers have better/different art.

**Albums field:** Deprecate, don't delete. Keep for backwards compat during transition, remove in v2.

## 5. ProviderType — Enum in Dart, String at Boundaries

```dart
enum ProviderType {
  spotify('spotify'),
  ardAudiothek('ard_audiothek'),
  appleMusic('apple_music');
  
  final String value;
  const ProviderType(this.value);
  
  static ProviderType fromString(String s) => 
    values.firstWhere((e) => e.value == s, orElse: () => throw ArgumentError('Unknown provider: $s'));
}
```

Conversion happens at DB read/write and YAML parsing. Everything inside the app uses the enum.

---

## Summary

| Item | Decision |
|------|----------|
| Sync model | Unified `ShowSubscriptions` table, provider-specific `SyncStrategy` implementations |
| `PlayerBackend.play()` | **No** — startup is provider-specific in `PlayerNotifier` |
| Backend creation | Switch expression in `PlayerNotifier`, no registry |
| Catalog YAML | Your schema + optional per-provider `episode_pattern` and `cover_url` |
| ProviderType | Dart enum, string in DB/YAML |

Ready to consolidate this into a final architecture document?
[chris@desky lauschi]$ 
