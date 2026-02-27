# Architecture Planning: Multi-Provider Support & Catalog Redesign

This is session 1 of a multi-session architecture planning effort. I want your deep, critical analysis. Push back on bad ideas. Suggest alternatives. Don't rush.

## Context

**lauschi** is a kids audio player (Flutter, DACH market). Parents curate content as visual cards; kids tap a card to play. No algorithms, no recommendations.

### Current provider landscape

**ARD Audiothek** (working, good):
- Free, no auth, public GraphQL API
- Direct audio URLs (MP3) played via just_audio (`DirectPlayer`)
- Content discovery: browse kids shows, subscribe to shows, auto-sync episodes
- Some content has expiration dates (`availableUntil`)

**Spotify** (working but dead-end):
- PKCE OAuth, no app review/approval path for indie apps
- Playback via WebView hosting Spotify Web Playback SDK (JS bridge)
- Catalog matching: 162 DACH Hörspiel series in `series.yaml` with keyword + artist ID matching
- Chris has a personal account, works for his family, but can't ship to other users
- Will keep as "personal/testing" provider but not invest more

**Providers being evaluated for user-facing integration:**

1. **Apple Music (MusicKit)** -- official Flutter plugin `music_kit` exists (iOS + Android). Uses native MusicKit on iOS, JitPack SDK on Android. Full playback, queue control, subscription check. Requires Apple Developer Program membership and developer token (JWT). **The plugin supports full track playback for subscribed users.**

2. **Tidal** -- open-source SDK (`tidal-sdk-android`, `tidal-sdk-ios`). Full-length playback when authenticated via OAuth Authorization Code Flow (not just previews). No existing Flutter plugin -- would need platform channels or a WebView approach like we did with Spotify. Dart API client package (`tidal` on pub.dev) exists for catalog search.

3. **Other free sources** (future): SRF (Swiss), ORF (Austrian) public radio -- similar to ARD pattern (free, direct audio URLs, no auth).

### Current architecture

The playback system has two layers:

**PlayerBackend (abstract class)** -- controls a single playback session:
- `DirectPlayer` -- plays HTTP audio URLs via `just_audio`. Used for ARD.
- `SpotifyBackend` -- controls Spotify via WebView bridge + Web API. Used for Spotify.

**PlayerNotifier (Riverpod)** -- the coordinator:
- `playCard(cardId)` loads a `TileItem` from DB, picks the right backend based on `provider` field, starts playback
- Manages generation counter for rapid switching, position saving, media session, auto-advance
- Currently does `if (card.provider == 'spotify') ... else ...` to pick backend

**Database**: `TileItem` has `provider` field ('spotify', 'ard_audiothek'), `providerUri` (e.g. 'spotify:album:xxx', 'ard:item:123'), `audioUrl` (null for SDK providers), `spotifyArtistIds` (Spotify-specific).

**Catalog**: `series.yaml` is Spotify-only (keyword/artist-ID matching for DACH Hörspiel). ARD content is browsed live via API.

### Content importer

`ContentImporter` is already somewhat provider-agnostic:
- Screens build `PendingCard` objects with provider-specific fields
- `importToGroup()` handles find-or-create tile, insert items, skip duplicates
- But `PendingCard` still has Spotify-specific fields (`spotifyArtistIds`, `totalTracks`) mixed with ARD-specific fields (`audioUrl`, `durationMs`, `availableUntil`)

## What I want to discuss

### 1. Catalog architecture

The current `series.yaml` is Spotify-centric. For multi-provider, we need to think about:

- Should the catalog be provider-agnostic? (series "TKKG" exists on Spotify, Apple Music, Tidal, and ARD)
- How do we match content across providers? (same series, different provider IDs)
- Should we keep a curated catalog at all, or shift to provider-native browse/search?
- What role does the catalog play when the user has Apple Music but not Spotify?

My instinct: the catalog should describe *series* (TKKG, Die drei ???, Bibi Blocksberg) with per-provider identifiers. The browse/search UI queries the user's active provider(s).

### 2. Provider abstraction

Beyond playback (`PlayerBackend`), each provider needs:
- **Auth**: OAuth flows, token management, subscription checks
- **Search/Browse**: Finding content in the provider's catalog
- **Content identity**: URIs, IDs, metadata format
- **Playback**: The actual audio rendering

Questions:
- Should there be a `ContentProvider` interface that bundles auth + search + playback?
- Or keep them separate (auth is a separate concern from playback)?
- How do we handle the case where ARD needs no auth but Apple Music does?
- Should the DB schema know about providers at all, or should `providerUri` be the only link?

### 3. UI/UX for multiple providers

Current flow: parent dashboard -> browse catalog (Spotify) OR discover (ARD). Two separate screens.

With 3+ providers, we need:
- Unified search across providers? Or per-provider browse tabs?
- How does the parent know which provider a piece of content comes from?
- What happens when the parent has Apple Music but the kid's device doesn't?
- Badge/icon treatment for providers in the tile grid?

### 4. Playback backend for Apple Music and Tidal

Apple Music: `music_kit` plugin handles playback natively. Similar to `DirectPlayer` but goes through MusicKit SDK. No WebView hack needed.

Tidal: No Flutter plugin. Options:
a) Write platform channels wrapping `tidal-sdk-android` and `tidal-sdk-ios`
b) WebView approach like Spotify (Tidal has a Web SDK)
c) Wait for community/official Flutter plugin

Which approach for each?

### 5. Database schema evolution

Current `TileItem` (Cards table) has:
- `provider` (string: 'spotify', 'ard_audiothek')
- `providerUri` (string: 'spotify:album:xxx', 'ard:item:123')
- `spotifyArtistIds` (Spotify-specific, used for catalog matching)
- `audioUrl` (null for SDK providers)
- `totalTracks` (Spotify album concept)
- `lastTrackUri`, `lastTrackNumber` (multi-track album resume, Spotify-specific)

For a clean multi-provider schema:
- Which fields are truly universal?
- Which are provider-specific and should go elsewhere?
- How do we handle resume state across different provider playback models?

## My constraints

- This is a side project. I can't build three provider integrations simultaneously.
- DACH market: Apple Music has ~15% market share, Spotify ~35%, Tidal tiny but growing with audiophile parents
- ARD is the foundation (free, no auth, rich kids content). Other providers are add-ons.
- Kids don't care about providers. They see cards. The provider is invisible to them.
- Parents care about "can I use my existing music subscription?"

## What I want from you

1. Critique my instincts. Where am I wrong?
2. Propose a catalog architecture that works for multi-provider
3. Propose a provider abstraction that's clean without being over-engineered
4. UI/UX thoughts on the parent flow
5. Prioritization: what to build first, what to defer

Be thorough. This is the foundation for the next year of development.
