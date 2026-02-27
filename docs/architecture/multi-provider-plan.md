# Multi-Provider Architecture Plan

Consolidated from 4 planning sessions (Claude + Kimi K2.5, Feb 2026).

## Overview

lauschi supports multiple audio content providers. Parents connect their
streaming subscriptions; kids see cards and don't know or care which provider
delivers the audio.

### Provider landscape

| Provider | Auth | Playback | Content model | Status |
|----------|------|----------|---------------|--------|
| ARD Audiothek | None | Direct HTTP (just_audio) | Structured shows/episodes | ✅ Working |
| Spotify | OAuth PKCE | WebView SDK bridge | Unstructured (albums, search) | ✅ Personal/testing only |
| Apple Music | MusicKit (JWT + user token) | `music_kit` Flutter plugin | Unstructured (catalog search) | 🔜 Next |
| Tidal | OAuth PKCE | WebView SDK (like Spotify) | Unstructured (catalog search) | 🔜 Deferred |
| SRF / ORF | None | Direct HTTP (like ARD) | Structured shows/episodes | 🔜 Future |

### Key decisions

- **Single flat DB table** for TileItems. Provider-specific fields are nullable columns.
- **No cross-provider resume**. Each TileItem is independent with its own position.
- **Three separate abstractions**: auth, catalog/search, playback.
- **PlayerNotifier keeps startup branching**. Backends handle uniform operations only.
- **Catalog YAML has series-level provider identifiers**. Episode discovery at runtime.
- **Sync works for all providers** via `ShowSubscriptions`. Music streaming series
  (TKKG, Die drei ???) get new albums regularly -- sync polls artist discographies.

---

## 1. Provider type

Dart enum, string in DB/YAML:

```dart
enum ProviderType {
  spotify('spotify'),
  ardAudiothek('ard_audiothek'),
  appleMusic('apple_music'),
  tidal('tidal');

  final String value;
  const ProviderType(this.value);

  static ProviderType fromString(String s) =>
    values.firstWhere((e) => e.value == s,
      orElse: () => throw ArgumentError('Unknown provider: $s'));
}
```

---

## 2. Auth

```dart
abstract class ProviderAuth {
  ProviderType get type;
  String get displayName;    // "Apple Music", "Spotify"
  bool get requiresAuth;     // false for ARD
  bool get isAuthenticated;
  Future<void> configure();  // One-time setup (dev tokens, API keys)
  Future<bool> authenticate(); // OAuth/MusicKit user auth
  Future<void> logout();
}
```

Implementations:
- `ArdAuth` -- always authenticated, all methods no-op
- `SpotifyAuth` -- existing PKCE flow, wraps `SpotifyAuthProvider`
- `AppleMusicAuth` -- developer JWT + MusicKit user token (two-step)
- `TidalAuth` -- OAuth PKCE (similar to Spotify)

---

## 3. Playback backends

`PlayerBackend` is the uniform control interface. No `play()` method --
startup is provider-specific and lives in `PlayerNotifier.playCard()`.

```dart
abstract class PlayerBackend {
  Stream<PlaybackState> get stateStream;
  int get currentPositionMs;
  int get currentTrackNumber;
  bool get hasNextTrack;

  Future<void> pause();
  Future<void> resume();
  Future<void> seek(int positionMs);
  Future<void> stop();
  Future<void> dispose();

  Future<void> nextTrack() async {}
  Future<void> prevTrack() async {}
}
```

Backend creation is a switch expression in `PlayerNotifier`:

```dart
PlayerBackend _createBackend(ProviderType type) => switch (type) {
  ProviderType.ardAudiothek => DirectPlayer(),
  ProviderType.spotify => SpotifyBackend(_bridge, _api),
  ProviderType.appleMusic => AppleMusicBackend(_musicKit),
  ProviderType.tidal => TidalBackend(_tidalBridge),
};
```

Each provider's play/start sequence in `playCard()`:
- **ARD**: Create DirectPlayer, call `backend.play(audioUrl, trackInfo, position)`
- **Spotify**: Call Web API to start playback, then attach SpotifyBackend as listener
- **Apple Music**: Call `musicKit.setQueue()` + `musicKit.play()`, attach backend
- **Tidal**: Similar to Spotify (WebView SDK command, then listen)

---

## 4. Catalog

### Purpose

The catalog maps known Hörspiel series to provider-specific identifiers for:
1. **Discovery**: Parent searches "TKKG" and finds it across providers
2. **Episode extraction**: Extract episode numbers from provider-specific title formats
3. **Sync**: Artist/show IDs for polling new releases

The catalog is needed for **unstructured providers** (Spotify, Apple Music, Tidal)
where Hörspiel is scattered across artist/album metadata. **Structured providers**
(ARD, SRF, ORF) have built-in show/episode hierarchy and don't need the catalog.

### YAML schema

```yaml
series:
  - id: tkkg
    title: TKKG
    aliases: ["TKKG -"]
    keywords: [tkkg]
    episode_pattern: '(?:Folge|Episode)\s+(\d+)'
    cover_url: https://...

    providers:
      spotify:
        artist_ids: ["0bDd9k1a8s6y3K8z1b9s3K"]
        episode_pattern: 'TKKG\s+Folge\s+(\d+)'  # optional override
      apple_music:
        artist_id: "123456789"
      tidal:
        artist_id: "56789"
      ard_audiothek:
        program_set_id: "12345"
```

Existing `spotify_artist_ids` and `albums` fields kept during transition,
deprecated in code, removed in a future pass.

---

## 5. Database

Single `TileItem` table (DB: `cards`). No normalized provider-specific tables.

Provider-specific columns are nullable:
- `audioUrl` -- ARD, SRF, ORF (direct HTTP providers)
- `spotifyArtistIds` -- Spotify catalog matching
- `totalTracks` -- Spotify/Apple Music (multi-track albums)
- `lastTrackUri` -- Spotify/Apple Music (resume within album)
- `availableUntil` -- ARD (content expiration)
- `durationMs` -- all providers (stored at import time for direct, from SDK for others)

New columns when needed (e.g. `appleMusicId`), added via Drift migration.

Resume state is per-TileItem:
- `lastPositionMs` -- universal
- `lastTrackNumber` -- multi-track albums (null for single-file)
- `lastPlayedAt` -- universal

---

## 6. Sync

`ShowSubscriptions` is already provider-generic. Sync strategy differs:

| Provider | What to poll | Change detection | Interval |
|----------|-------------|------------------|----------|
| ARD | `programSet` items | `lastItemAdded` timestamp | Daily |
| Spotify | Artist albums | Compare against existing URIs | Weekly |
| Apple Music | Artist albums | Compare against existing URIs | Weekly |
| Tidal | Artist albums | Compare against existing URIs | Weekly |

For music streaming, sync means:
1. Fetch artist's album list from API
2. Match against series keywords + episode pattern
3. Compare providerUris against existing TileItems
4. Insert new matches as TileItems in the subscribed tile

Rate limits are feasible: 20 series x 1 request = 20 requests per sync.
Spotify allows 100 req/30sec.

---

## 7. UI/UX

### Parent: adding content

Provider tabs as default view, search is per-provider:

```
"Inhalte hinzufügen"
├── [ARD Audiothek] → DiscoverScreen (hierarchical: featured → shows → episodes)
├── [Apple Music]   → BrowseCatalogScreen (catalog grid + search)
└── [Spotify]       → BrowseCatalogScreen (catalog grid + search)
```

Cross-provider unified search is deferred until 3+ providers and user feedback.

### Parent: settings

```
Einstellungen → Anbieter
├── ARD Audiothek     [Immer aktiv ℹ️]
├── Apple Music       [Verbinden] / [Verbunden ✅]
├── Spotify           [Verbinden] / [Verbunden ✅]
└── Tidal             [Demnächst verfügbar]
```

Disconnect keeps existing TileItems grayed out. Kid sees "Inhalt nicht verfügbar"
on tap (same error path as expired ARD content).

### Kid: no change

Kids see cards. Provider is invisible. Error handling via
`PlayerError.contentUnavailable` covers both expired content and lapsed
subscriptions, with provider-specific detail in error metadata for parent toast.

---

## 8. Migration path

### Phase 1: Foundation (low risk)

1. `lib/core/providers/provider_type.dart` -- enum
2. Use `ProviderType` in PlayerNotifier switch (replaces string comparison)
3. Update `CatalogService` to parse `providers:` map in YAML (keep old fields)

### Phase 2: Auth abstraction (medium risk)

4. `lib/core/providers/provider_auth.dart` -- interface
5. Wrap existing `SpotifyAuth` to implement it
6. Add `ArdAuth` (trivial no-op)
7. Provider settings screen iterates registered providers

### Phase 3: Catalog evolution (medium risk)

8. Add provider identifiers to `series.yaml` (keep existing Spotify fields)
9. `CatalogService.match()` takes optional `ProviderType` parameter
10. Browse/add screens use provider tabs

### Phase 4: Apple Music integration

11. Apple Developer Program enrollment + MusicKit key setup
12. `music_kit` plugin dependency
13. `AppleMusicAuth` implementation
14. `AppleMusicBackend` (wraps music_kit for PlayerBackend interface)
15. Apple Music browse/search screen

Each phase ends with all tests passing. No big-bang migration.

---

## Planning session history

- `docs/architecture/session-1-*` -- initial proposal and response
- `docs/architecture/session-2-*` -- pushback on schema, catalog, interfaces
- `docs/architecture/session-3-*` -- hard problems (migration, sync, UX, errors)
- `docs/architecture/session-4-*` -- sync correction, final gaps, consolidation
