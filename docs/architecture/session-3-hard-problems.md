# Architecture Planning Session 3: Hard Problems & Migration Path

Sessions 1-2 converged on key decisions. This session focuses on the hard remaining questions and the migration path from current state to target state.

## Agreed decisions from sessions 1-2

1. **Single flat TileItem table** with nullable provider-specific columns
2. **No cross-provider resume** -- each TileItem is independent  
3. **Three separate abstractions**: auth, catalog search, playback
4. **PlayerNotifier keeps startup branching**, backends handle uniform ops
5. **Catalog YAML**: series-level provider identifiers only, runtime episode discovery
6. **Apple Music via music_kit plugin**, Tidal via WebView (deferred)

## Hard problem 1: The catalog's real purpose

Let's be honest about what the catalog does today:

1. **Match imported Spotify albums to known series** -- so the parent sees "This is TKKG Folge 5" instead of just "Draculas Erben"
2. **Extract episode numbers** from titles for sorting
3. **Series-level discovery** -- browse grid of known Hörspiel series

For ARD, the catalog is NOT used. ARD has its own programSets (shows) with episode structure built in. The parent browses ARD shows directly via the API.

So the catalog is really a **Spotify/Apple Music/Tidal concern** -- matching unstructured album/track titles to known series. ARD already has structured metadata.

**Question**: Should the catalog be optional per provider? ARD doesn't need it. Future public radio providers (SRF, ORF) probably won't either -- they'll have their own structured show/episode metadata. The catalog is only needed for music-streaming providers where Hörspiel is scattered across artist/album metadata.

If so, the architecture becomes:
- **Structured providers** (ARD, SRF, ORF): have built-in show/episode hierarchy. Browse directly.
- **Unstructured providers** (Spotify, Apple Music, Tidal): need the catalog to identify and organize Hörspiel content from flat search results.

Does this distinction belong in the provider abstraction?

## Hard problem 2: The browse/add flow

Currently there are two add flows:
1. **BrowseCatalogScreen**: search Spotify, see catalog series grid, add albums
2. **DiscoverScreen**: browse ARD kids shows, tap show -> see episodes -> add

These are structurally different because the providers offer different content organization:
- ARD: curated categories (kids), shows (programSets), episodes -- hierarchical
- Spotify: flat search results that we match against our catalog -- flat with matching

For multi-provider, what's the parent flow?

**Option A: One "Add Content" screen with provider tabs**
```
[ARD Audiothek] [Apple Music] [Spotify]
   ↓                ↓             ↓
   Browse shows     Search+match  Search+match
```
Each tab has its own UI because the data model differs.

**Option B: Unified search with results from all providers**
```
Search: "Bibi Blocks..." 
Results:
  📀 Bibi Blocksberg Folge 1 [Apple Music]
  📀 Bibi Blocksberg Folge 1 [Spotify]  
  📻 Bibi Blocksberg [ARD] (Show - 45 episodes)
```
One screen, mixed results.

**Option C: Hybrid**
Default view shows provider-specific browse (ARD featured shows, catalog grid for music providers). Search triggers unified cross-provider results.

Which scales better? Which is simpler to build incrementally?

## Hard problem 3: Migration path

The current codebase has to keep working throughout the migration. We can't pause feature work for weeks to restructure.

**Current state**:
- `PlayerNotifier` branches on `card.provider == 'spotify'`
- `CatalogService` is Spotify-only
- `ArdApi` is standalone
- Auth is Spotify-specific (`SpotifyAuth`, `SpotifyAuthProvider`)
- `ContentImporter` is somewhat generic but has Spotify fields in `PendingCard`

**Target state**:
- Provider interfaces with registry
- Catalog YAML with multi-provider identifiers
- Unified content model

**Question**: What's the incremental migration path? What can we do file-by-file without breaking things?

Rough idea:
1. Introduce `ProviderType` enum (replaces string 'spotify', 'ard_audiothek')
2. Extract provider interface for auth (ARD = no-op, Spotify = existing)
3. Make `CatalogService` provider-aware (add `providers:` to YAML, keep existing fields as fallback)
4. Introduce `CatalogProvider` interface, implement for ARD (wrap ArdApi)
5. Add Apple Music when we have the SDK keys

Is this the right order? What are the riskiest steps?

## Hard problem 4: Show subscriptions across providers

Current `ShowSubscriptions` table tracks ARD show subscriptions for auto-sync (new episodes appear automatically). 

For Apple Music/Tidal, the equivalent would be: "sync all episodes from this artist/series". But:
- ARD sync is straightforward: poll programSet for new items, insert as TileItems
- Apple Music sync would need periodic MusicKit API queries by artist ID
- Spotify sync isn't practical (no push, rate-limited API)

Should `ShowSubscriptions` become provider-generic? Or is auto-sync an ARD-only feature?

My instinct: auto-sync makes sense for any provider with structured show/series data. ARD, SRF, ORF, potentially Apple Music podcasts. Less so for music-streaming providers where content is static (Spotify albums don't get new tracks).

## Hard problem 5: Provider settings/configuration UX

Where in the app does the parent configure providers?

Current: Spotify auth is in onboarding + settings. ARD just works (no config).

For multi-provider:
```
Settings
├── Anbieter (Providers)
│   ├── ARD Audiothek ✅ (always on, no config)
│   ├── Apple Music [Verbinden] / [Verbunden ✅]
│   ├── Spotify [Verbinden] / [Verbunden ✅]
│   └── Tidal [Verbinden] / [Verbunden ✅]
```

Questions:
- Do we show providers the user doesn't have? ("Get Apple Music" link?)
- Can the parent disable a provider they're signed into? (Hide all Apple Music content)
- What happens to existing TileItems when a provider is disconnected? Keep them grayed out? Delete them?

## Hard problem 6: What happens when a provider subscription lapses?

Kid taps a card that was from Apple Music. Parent's Apple Music subscription expired last week.

Options:
a) Show "Inhalte nicht verfügbar" error (like we do for expired ARD content)
b) Prompt parent to re-authenticate
c) Silently skip and play next available content

This is similar to the existing `PlayerError.contentUnavailable` path. But the cause is different (subscription lapsed vs content expired). Do we need different error types?

## What I want from this session

1. Answer each hard problem with a concrete recommendation
2. For the migration path: specific file-by-file plan
3. For the browse/add flow: mockup of the recommended UI approach
4. Identify which hard problems we should solve NOW vs defer

Don't try to solve everything. Some of these should be explicitly deferred with a "good enough for now" answer.
