# Apple Music Integration Plan

Planning phase for Apple Music as the third content provider in lauschi.
Week-long planning before implementation, covering product, architecture,
event storming, and implementation details.

## Planning Sessions

| # | Topic | Status | Doc |
|---|-------|--------|-----|
| 1 | Product requirements and user stories | 🔜 | [Session 1](#session-1-product) |
| 2 | Apple Music API and MusicKit capabilities | 🔜 | [Session 2](#session-2-api-landscape) |
| 3 | Architecture and component design | 🔜 | [Session 3](#session-3-architecture) |
| 4 | Event storming: auth, browse, playback, sync | 🔜 | [Session 4](#session-4-event-storming) |
| 5 | Error handling, edge cases, degraded states | 🔜 | [Session 5](#session-5-errors-and-edges) |
| 6 | DB migrations, catalog YAML, data model | 🔜 | [Session 6](#session-6-data-model) |
| 7 | Implementation plan, task breakdown, risks | 🔜 | [Session 7](#session-7-implementation-plan) |

Each session produces a prompt for Kimi K2.5 review, followed by
integration of feedback.

---

## Context

### What exists today

- **ProviderType.appleMusic** enum value (string: `apple_music`)
- **Placeholder in AddContentScreen**: `_ComingSoon` widget for Apple Music tab
- **Placeholder in PlayerNotifier**: `case ProviderType.appleMusic: throw UnimplementedError()`
- **Provider registry**: Only ARD and Spotify registered; Apple Music will slot in
- **Multi-provider architecture**: Phases 1-3 complete (auth abstraction, tabbed
  browse, provider settings, auto-assign). Phase 4 is Apple Music.

### Key prior decisions (from multi-provider-plan.md)

- Apple Music via `music_kit` Flutter plugin (native iOS MusicKit + Android JitPack SDK)
- No WebView approach (unlike Spotify)
- Developer JWT + MusicKit user token (two-step auth)
- `AppleMusicAuth` implements `ProviderAuth` interface
- `AppleMusicBackend` implements `PlayerBackend` interface
- Catalog YAML already has `providers.apple_music.artist_id` slot
- Sync: weekly artist album polling, same as Spotify
- Single flat TileItem table, `appleMusicId` as nullable column

### Target platforms

- **iOS**: Native MusicKit framework (first-class support)
- **Android**: MusicKit SDK for Android via JitPack (requires Apple Music app installed)

### Flutter plugin

`music_kit` (pub.dev/packages/music_kit) by misiio:
- iOS + Android support
- Auth: `requestAuthorizationStatus()`, `requestUserToken(developerToken)`
- Playback: `setQueue()`, `play()`, `pause()`, `skipToNextEntry()`, etc.
- State: `onMusicPlayerStateChanged` stream, `onNowPlayingItemChanged` stream
- Subscription: `onSubscriptionUpdated` stream
- Catalog: uses Apple Music API via developer token for search

---

## Session 1: Product {#session-1-product}

### User stories

#### Parent: connecting Apple Music
- As a parent, I can connect my Apple Music account in Settings
- As a parent, I see Apple Music as a provider option alongside ARD and Spotify
- As a parent, I can disconnect Apple Music (tiles stay, grayed out)
- As a parent, I see a clear indication if my Apple Music subscription lapses

#### Parent: adding Apple Music content
- As a parent, I can browse/search Apple Music in the "Add content" tab
- As a parent, I can search for Hörspiel series (TKKG, Die drei ???, etc.)
- As a parent, I can add individual albums or entire series
- As a parent, I see which episodes are already added (like Spotify)
- As a parent, I can subscribe to a series for automatic new-episode sync

#### Kid: playback
- As a kid, I tap a card and it plays (don't know/care it's Apple Music)
- As a kid, I see the same controls regardless of provider
- As a kid, I see the album art and track info
- As a kid, playback resumes where I left off
- As a kid, episodes auto-advance to the next one

#### Kid: error states
- As a kid, I see "Diese Geschichte ist weggeflogen" if content unavailable
- As a kid, I never see Apple Music branding or error messages

### Product requirements

1. **Zero provider awareness for kids.** No Apple Music logo, no "open in
   Apple Music", no subscription prompts. Cards play or show the bird.

2. **Same content model.** Albums become TileItems with episode numbers.
   Series become Tiles. Catalog matching works the same as Spotify.

3. **Subscription dependency.** Apple Music requires an active subscription
   for full playback. Preview clips (30s) available without subscription.
   We do NOT use preview clips -- full playback or error.

4. **Platform differences.**
   - iOS: Native MusicKit, no app dependency
   - Android: Requires Apple Music app installed
   - If Apple Music app not installed on Android: show setup instructions

5. **Offline not in scope.** Apple Music supports offline downloads via their
   app. We don't manage downloads. If offline, content unavailable.

### Open product questions

- [ ] Do we support Apple Music free trial signup from within the app?
- [ ] Do we show "requires Apple Music app" on Android during onboarding?
- [ ] Album-level vs song-level queue: Hörspiel albums are usually one
      continuous story split into tracks. Do we queue the album and let
      MusicKit handle track transitions, or manage tracks individually?
- [ ] Apple Music editorial content / curated playlists: useful for
      Hörspiel discovery? (e.g. "Hörspiele für Kinder" playlists)

---

## Session 2: API Landscape {#session-2-api-landscape}

### Apple Music API (REST)

Base: `https://api.music.apple.com/v1/`

Key endpoints:
- `GET /v1/catalog/{storefront}/search?term=TKKG&types=artists,albums`
- `GET /v1/catalog/{storefront}/artists/{id}`
- `GET /v1/catalog/{storefront}/artists/{id}/albums`
- `GET /v1/catalog/{storefront}/albums/{id}`
- `GET /v1/catalog/{storefront}/albums/{id}/tracks`

Auth: Developer JWT token in `Authorization: Bearer` header.
Storefront: `de` for Germany/DACH.

Rate limits: 2,500 requests/hour per developer token (generous).

### MusicKit Flutter plugin API

```dart
final musicKit = MusicKit();

// Auth
final status = await musicKit.requestAuthorizationStatus();
// MusicAuthorizationStatusAuthorized / Denied / NotDetermined / Restricted
final userToken = await musicKit.requestUserToken(developerToken);

// Playback
await musicKit.setQueue('albums', item: {'id': 'albumId'});
await musicKit.play();
await musicKit.pause();
await musicKit.skipToNextEntry();
await musicKit.skipToPreviousEntry();
await musicKit.setShuffleMode(ShuffleMode.off);
await musicKit.setRepeatMode(RepeatMode.none);

// State streams
musicKit.onMusicPlayerStateChanged.listen((MusicPlayerState state) {
  // state.playbackStatus: playing, paused, stopped, etc.
  // state.playbackRate
});
musicKit.onNowPlayingItemChanged.listen((MusicItem? item) {
  // item.id, item.title, item.artistName, item.albumTitle
  // item.artworkUrl, item.duration, item.playbackTime
});
musicKit.onSubscriptionUpdated.listen((MusicSubscription sub) {
  // sub.canPlayCatalogContent, sub.hasCloudLibraryEnabled
});
```

### Key differences from Spotify

| Aspect | Spotify | Apple Music |
|--------|---------|-------------|
| Playback | WebView SDK (JS bridge) | Native plugin (method channels) |
| Auth | OAuth PKCE (web redirect) | MusicKit (OS prompt on iOS, app on Android) |
| API auth | User access token | Developer JWT (catalog) + user token (playback) |
| Queue | Web API `PUT /play` with offset | `setQueue('albums', item:)` |
| State | JS `player_state_changed` event | `onMusicPlayerStateChanged` stream |
| Track info | State payload has full metadata | `onNowPlayingItemChanged` separate stream |
| Position | State payload `position_ms` | `MusicPlayerState.playbackTime` (seconds) |
| Resume | Web API with `position_ms` param | `setQueue` + seek to position |
| Multi-track | Handled by Spotify player | Handled by MusicKit queue |

### Open API questions

- [ ] Does `setQueue('albums', ...)` respect track order? (critical for Hörspiel)
- [ ] Can we seek to a position within a queued album? How?
- [ ] What metadata is available in `MusicItem`? Track number? Disc number?
- [ ] How does the plugin report track transitions within an album?
- [ ] What happens when subscription lapses mid-playback?
- [ ] Can we detect "Apple Music app not installed" on Android before auth?
- [ ] Rate limits for catalog search API with developer token?

---

## Session 3: Architecture {#session-3-architecture}

*To be filled after Kimi review of sessions 1-2*

---

## Session 4: Event Storming {#session-4-event-storming}

*To be filled after session 3*

---

## Session 5: Errors and Edge Cases {#session-5-errors-and-edges}

*To be filled after session 4*

---

## Session 6: Data Model {#session-6-data-model}

*To be filled after session 5*

---

## Session 7: Implementation Plan {#session-7-implementation-plan}

*To be filled after session 6*

---

## Kimi Review Log

| Session | Prompt file | Response | Key feedback |
|---------|------------|----------|-------------|
| 1 | `/tmp/kimi-apple-session1.md` | pending | |
