# Architecture Planning Session 2: Drilling Into Provider Abstraction & Catalog

This is session 2. In session 1 you gave a solid first pass. Now I want to stress-test specific proposals and go deeper on the tricky parts.

## Session 1 recap -- what I agree with

- Three separate abstractions (auth, catalog, playback) rather than one monolith. Correct.
- Keep curated catalog for discovery + cross-provider identity. Yes.
- Per-provider browse tabs + unified search. Good UI direction.
- Apple Music via `music_kit` plugin (native), Tidal via WebView first. Pragmatic.
- Spotify stays as personal/testing provider. Agreed -- it's the reference implementation.

## Where I want to push back or go deeper

### 1. The provider-specific detail tables are over-engineering

Your proposal:
```
TileItems (core) + SpotifyItemDetails + ArdItemDetails + ...
```

This is N extra tables, N joins, and N migration paths. For what? A few nullable columns.

**Counter-proposal**: Keep a single `TileItem` table. Provider-specific fields that only one provider uses should be nullable columns. The table already has `audioUrl` (ARD-only) and `spotifyArtistIds` (Spotify-only) as nullable, and it works fine. Adding `appleMusicId` as another nullable column is simpler than a join table.

The only field worth extracting is resume state, and even that is questionable. `lastPositionMs` is universal. `lastTrackUri` + `lastTrackNumber` is Spotify/Apple Music (multi-track albums), and it's harmless as nullable on the main table.

**My rule**: Normalize when you query against the specific columns. We never `SELECT * FROM ard_item_details WHERE audioUrl LIKE ...`. We look up by `id` and use whatever fields are populated.

What do you think? Am I being too lazy, or is this pragmatic for a side project?

### 2. providerDataJson is an anti-pattern

You suggested `providerDataJson` as a catch-all. This is the worst of both worlds: untyped, unindexable, and a maintenance trap. Let's either use real columns or not pretend.

### 3. Cross-provider episode identity is harder than you think

You proposed episode numbers as the universal key. But consider:

- ARD Audiothek doesn't always have episode numbers. Many shows use publish dates or are just unnumbered items in a feed.
- Spotify albums for a series might be numbered differently. "TKKG Folge 1" on Spotify might be a re-release with different track listings.
- Some series have "Sonderfolgen" (specials) that don't have canonical numbers.
- Different providers might have different editions of the same episode (original vs. remastered).

**My revised thinking**: Cross-provider resume is a nice-to-have, not a requirement. For MVP, each provider's content is independent. The catalog maps series -> provider identifiers for *discovery*, not for cross-provider playback continuity.

The kid plays "TKKG Folge 5" from Apple Music. That's a specific `providerUri`. If the parent also adds the ARD version, it's a different `TileItem` with a different `providerUri`. They don't share resume state. Is this OK for now?

### 4. The CatalogProvider interface needs more thought

Your proposed `CatalogProvider`:
```dart
abstract class CatalogProvider {
  Future<SearchResults> search(String query, {SearchOptions? options});
  Future<List<Episode>> getSeriesEpisodes(String seriesId);
  Future<PlayableContent?> resolve(String providerUri);
}
```

Questions:
- What is `seriesId` here? Is it the catalog's canonical ID ("tkkg") or the provider's own ID? If catalog, how does the provider know its own mapping?
- `resolve` converts a URI to playable content -- but for SDK providers (Apple Music), "resolve" means "queue it in the SDK player". The content isn't a URL. Is `PlayableContent` an abstraction over "thing that can be played"?
- How does browse/discovery work? ARD has `getKidsShows()`. Apple Music has genre browsing. These are structurally different. Does `CatalogProvider` need a `browse` method, or is browse provider-specific UI?

### 5. The PlaybackBackend vs PlayerBackend naming

We already have `PlayerBackend` as the abstract class. Your proposal uses `PlaybackBackend`. Let's settle on naming now before we go further.

Also, your `PlaybackBackend.play()` takes `PlayableContent`. But the current `PlayerNotifier.playCard()` does significant work *before* calling the backend:
1. Load card from DB
2. Determine provider
3. Create backend instance
4. For Spotify: call Web API to start playback, then listen to bridge events
5. For ARD: call `DirectPlayer.play(audioUrl)` directly

The "play" step is fundamentally different per provider. The backend interface should handle pause/resume/seek/stop/dispose (uniform operations), but the initial "start playing this content" differs too much to unify behind a single `play(PlayableContent)`.

Current approach: `PlayerNotifier` has provider-specific branching for the play path, then delegates uniform operations to `PlayerBackend`. Is this the right split?

### 6. Auth lifecycle and provider availability

You proposed:
```dart
abstract class AuthProvider {
  bool get requiresAuth;  // false for ARD
  Future<String?> getValidToken();
}
```

But auth isn't just about tokens:
- **Apple Music**: needs developer token (server-side JWT) + user music token (per-device). Two different auth steps.
- **Tidal**: OAuth with Authorization Code + PKCE, similar to Spotify
- **ARD**: No auth at all
- **SRF/ORF (future)**: Probably no auth, like ARD

Should `AuthProvider` have a `setup()` step for one-time configuration (developer token generation, API key validation)? Or is that out-of-band?

### 7. The catalog YAML: do we need per-episode provider mappings?

Your proposed:
```yaml
episodes:
  1:
    spotify: 25u9Clfj4qnEJD3jjxOwPR
    apple_music: 987654321
```

This is 162 series x N episodes x M providers = potentially tens of thousands of YAML entries. Maintaining this by hand is impossible. And the current Spotify catalog already has 16,000 lines.

Alternative: The catalog stores *series-level* identifiers (artist IDs, show IDs). Episode discovery happens at runtime via provider API calls. The catalog only needs:

```yaml
series:
  - id: tkkg
    title: TKKG
    keywords: [tkkg]
    episode_pattern: '(?:Folge|Episode)\s+(\d+)'
    providers:
      spotify:
        artist_ids: [xxx]
      apple_music:
        artist_id: yyy
      ard_audiothek:
        program_set_id: zzz
      tidal:
        artist_id: www
```

Episode matching happens per-provider using the existing keyword + artist ID + episode pattern system, adapted per provider's title format. No cross-provider episode mapping in the YAML.

Thoughts?

### 8. What about offline / downloaded content?

This hasn't come up but it's relevant for kids devices. ARD content can be downloaded (it's direct HTTP). Apple Music supports offline downloads via MusicKit. Spotify does too (in the official app, not via Web Playback SDK).

Should the architecture account for a future `local` provider that plays downloaded files? Or is this out of scope?

## What I want from this session

1. Respond to my pushbacks. Where am I wrong?
2. Settle on database schema direction (flat vs normalized)
3. Settle on catalog YAML structure
4. Define the actual interfaces we'd write in Dart -- not pseudocode, real signatures with types
5. Identify the minimum viable abstraction that supports ARD + Apple Music, without over-building for Tidal
