cd /home/chris/Projects/lauschi && pi --model kimi-k2.5 --thinking xhigh -p - < /tmp/kimi-architecture-session-1.md
[chris@desky lauschi]$ cd /home/chris/Projects/lauschi && pi --model kimi-k2.5 --thinking xhigh -p - < /tmp/kimi-architecture-session-1.md
Warning: No models match pattern "opencode/kimi-k2.5-free"
 Now I have a solid understanding of the current architecture. Let me give you the deep, critical analysis you asked for.

---

## 1. Catalog Architecture: Your Instinct is Right, But...

Your instinct about the catalog describing *series* (not provider-specific albums) is correct. But the implementation needs work.

**Current `series.yaml` problems:**

1. **Spotify IDs at the album level**: Each entry has `spotify:album:xxx` URIs. This won't scale to multi-provider.
2. **Per-provider matching**: `spotify_artist_ids` is baked into the series definition. What about Apple Music artist IDs? Tidal?
3. **Keyword matching is provider-specific**: The keywords work for Spotify album titles but may not match ARD/Apple Music naming conventions.

**Proposed catalog structure:**

```yaml
series:
  - id: yakari  # stable, canonical identifier
    title: Yakari
    type: finite_series  # vs infinite (Betthupferl), anthology
    episode_pattern: 'Folge\s+(\d+)'
    keywords: [yakari]
    covers:
      default: https://...
      dark: https://...  # optional theme variants
    
    # Per-provider identifiers (all optional)
    identifiers:
      spotify:
        artist_ids: [5BOhng5bYwJNOR8ckMWpUg]
      apple_music:
        artist_id: "123456789"
        store_id: "us"  # or 'de' for region
      tidal:
        artist_id: "12345"
      ard_audiothek:
        program_set_ids: [12345, 67890]  # ARD has multiple regional feeds
    
    # Curated episode mappings (provider-agnostic episode -> provider IDs)
    episodes:
      1:
        spotify: 25u9Clfj4qnEJD3jjxOwPR
        apple_music: 987654321
        tidal: abc123
        ard: 111222333
      2:
        # ...
```

**Key insight**: Episode numbers are the universal key. The catalog maps episode 1 → whatever provider ID(s) you have. This lets a kid resume episode 1 on Apple Music when they started it on ARD (if the parent has both configured).

**Should we keep a curated catalog?** Yes, but with a different purpose:
- **Discovery**: Help parents find "TKKG" without knowing provider-specific search terms
- **Cross-provider resume**: Episode number as the identity key
- **Completeness tracking**: Know when episode 147 exists on Spotify but not Apple Music

**Provider-native browse vs catalog:** Both. The catalog is a "known series index" for discovery, but browsing should hit the provider's native catalog (search "Bibi" → query all configured providers).

---

## 2. Provider Abstraction: Split It Up

Don't bundle auth/search/playback into one `ContentProvider` interface. They have different lifetimes and failure modes.

**Three separate abstractions:**

```dart
// 1. Authentication (long-lived, singletons)
abstract class AuthProvider {
  String get providerId;  // 'spotify', 'apple_music', 'tidal'
  Stream<AuthState> get stateStream;
  Future<void> signIn();
  Future<void> signOut();
  Future<String?> getValidToken();  // null if not authenticated
  bool get requiresAuth;  // false for ARD
}

// 2. Catalog Search (query-only, stateless)
abstract class CatalogProvider {
  String get providerId;
  
  // Search the provider's catalog
  Future<SearchResults> search(String query, {SearchOptions? options});
  
  // Get episodes for a series (if provider supports it)
  Future<List<Episode>> getSeriesEpisodes(String seriesId);
  
  // Resolve a provider URI to full metadata
  Future<PlayableContent?> resolve(String providerUri);
}

// 3. Playback Backend (per-session, created on demand)
abstract class PlaybackBackend {
  String get providerId;
  Stream<PlaybackState> get stateStream;
  int get currentPositionMs;
  
  Future<void> play(PlayableContent content, {int? resumePositionMs});
  Future<void> pause();
  Future<void> seek(int positionMs);
  Future<void> dispose();
}
```

**Why split them?**
- **Auth lifetime**: Spotify auth lives for hours (token refresh). ARD has no auth. Apple Music has MusicKit user token + developer token.
- **Search vs playback separation**: You can search Apple Music without being subscribed (preview clips), but playback requires subscription. Different error handling.
- **Testability**: Can mock search without implementing playback.

**The registry pattern:**

```dart
@Riverpod(keepAlive: true)
ProviderRegistry providerRegistry(Ref ref) {
  return ProviderRegistry([
    // ARD needs no auth
    ArdProvider(auth: const NoAuthProvider()),
    
    // Spotify (personal/testing only)
    SpotifyProvider(
      auth: ref.watch(spotifyAuthProvider),
      api: ref.watch(spotifyApiProvider),
    ),
    
    // Apple Music (future)
    AppleMusicProvider(
      auth: ref.watch(appleMusicAuthProvider),
    ),
    
    // Tidal (future)
    TidalProvider(
      auth: ref.watch(tidalAuthProvider),
    ),
  ]);
}
```

**ARD is special** (no auth, direct URLs). Model it explicitly:

```dart
class ArdProvider implements CatalogProvider, PlaybackBackend {
  // CatalogProvider: search, browse kids shows
  // PlaybackBackend: via DirectPlayer (just_audio)
  // AuthProvider: NoAuthProvider.alwaysAuthenticated
}
```

---

## 3. Database Schema: Normalize Provider-Specific Fields

Current `TileItem` has a flat structure with nullable fields for every provider. This is a mess.

**Current:**
```dart
class Cards extends Table {
  TextColumn get provider => text()();  // 'spotify', 'ard_audiothek'
  TextColumn get providerUri => text()();  // 'spotify:album:xxx'
  TextColumn get spotifyArtistIds => text().nullable()();  // Spotify-only
  TextColumn get audioUrl => text().nullable()();  // ARD-only
  IntColumn get totalTracks => integer().nullable()();  // Spotify-only
  DateTimeColumn get availableUntil => dateTime().nullable()();  // ARD mostly
  // ... more mixed fields
}
```

**Proposed:**

```dart
// Core table: only universal fields
class TileItems extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get provider => text()();  // 'spotify', 'ard', 'apple_music', 'tidal'
  TextColumn get providerUri => text()();  // canonical URI for this provider
  
  // Content identity (for cross-provider matching)
  TextColumn get seriesId => text().nullable()();  // 'yakari', 'bibi_blocksberg'
  IntColumn get episodeNumber => integer().nullable()();
  
  // Playback resume (universal)
  IntColumn get lastPositionMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();
  BoolColumn get isHeard => boolean().withDefault(const Constant(false))();
  
  // Provider-specific data in separate table (JSONB style or normalized)
  TextColumn get providerDataJson => text().nullable()();  // provider-specific blobs
}

// Provider-specific tables (optional, if you need querying)
class SpotifyItemDetails extends Table {
  TextColumn get itemId => text().references(TileItems, #id)();
  TextColumn get artistIds => text()();  // comma-separated
  IntColumn get totalTracks => integer()();
  TextColumn get lastTrackUri => text().nullable()();
}

class ArdItemDetails extends Table {
  TextColumn get itemId => text().references(TileItems, #id)();
  TextColumn get audioUrl => text()();
  DateTimeColumn get availableUntil => dateTime().nullable()();
  IntColumn get durationMs => integer()();
}
```

**Resume state handling:**
- `lastPositionMs` + `lastPlayedAt` are universal
- Multi-track albums (Spotify/Apple Music): also store `lastTrackUri` in provider-specific table
- Single-file episodes (ARD): `lastTrackUri` is null, position is file offset

**Provider URI format:**
- `spotify:album:xxx`
- `spotify:track:xxx`  # for single-track resume
- `ard:item:12345`
- `apple_music:album:xxx`
- `tidal:album:xxx`

The URI is the foreign key to provider-specific data.

---

## 4. UI/UX for Multiple Providers

**Current state:** Two separate screens (Browse Catalog = Spotify, Discover = ARD). Parents learn which content is where.

**Unified approach:**

```
Parent Dashboard
├── "Hinzufügen" → Unified Add Flow
│   ├── Search bar (queries all configured providers)
│   ├── Results grouped by provider (with badges)
│   └── Series matching: "TKKG → found on Spotify + Apple Music"
│
├── Provider tabs (browse per-provider)
│   ├── ARD Audiothek (free, rich kids content)
│   ├── Apple Music (if configured)
│   └── Spotify (if configured, personal/testing)
│
└── Kid's tiles (provider invisible)
```

**Key decisions:**

1. **Per-provider browse tabs**: Keep them. Each provider has different content organization (ARD has "Kids Shows", Apple Music has genres/curated lists). Don't force a unified taxonomy.

2. **Unified search**: Yes. Search "Bibi Blocksberg" → show results from all providers with badges. Parent picks which one to add (or add all if they have multiple subscriptions).

3. **Provider badges**: Show on the add screen, not on kid tiles. Kids don't care. Parents need to know during curation.

4. **Mixed-provider tiles**: Consider allowing. A "Bibi Blocksberg" tile could have:
   - Episode 1-50 from Apple Music
   - Episode 51+ from ARD (newer content)
   
   This requires episode-number-based identity and matching.

5. **Subscription check**: During onboarding or settings, check which providers the user has active. Don't show Apple Music tab if they don't have a subscription.

**Badge treatment example:**
```dart
// During add flow
ListTile(
  leading: CoverImage(result.coverUrl),
  title: Text(result.title),
  subtitle: Text('Folge ${result.episodeNumber}'),
  trailing: ProviderBadge(result.provider),  // "Apple Music", "ARD"
)
```

---

## 5. Playback Backend: Platform Channels vs WebView

**Apple Music: Use `music_kit` plugin**
- Pros: Native SDK, proper audio focus, background playback, lock screen integration
- Cons: iOS 15.4+ required, Android support via JitPack (may be flaky)
- **Decision**: Build native bridge. Don't WebView this.

**Tidal: Three options ranked:**

| Approach | Effort | Quality | Recommendation |
|----------|--------|---------|----------------|
| a) Platform channels wrapping SDKs | High | High | **Best long-term** |
| b) WebView like Spotify | Medium | Medium | **Short-term viable** |
| c) Wait for community plugin | None | N/A | Not happening soon |

**My recommendation for Tidal:**
- **Phase 1**: WebView approach (Tidal Web SDK) to validate user interest
- **Phase 2**: If adoption justifies it, build platform channels

The WebView approach is defensible for Tidal because:
- It's an "add-on" provider (not core like ARD)
- The SDK exists and is stable
- You already solved the hard problems with Spotify (JS bridge, auth flow, state sync)

**Implementation sketch for Tidal Web SDK:**
```dart
class TidalBackend extends PlayerBackend {
  final WebViewController _webView;
  final TidalAuth _auth;
  
  // Similar to Spotify: JS bridge for SDK events
  // Web API for catalog search (or use dart `tidal` package)
}
```

---

## Prioritization: Build Order

**Phase 1: Foundation (next 2-4 weeks)**
1. **Database migration**: Normalize provider-specific fields out of `TileItem`
2. **Provider registry**: Empty `lib/core/providers/` → implement registry + ARD migration
3. **Catalog redesign**: New YAML schema with per-provider identifiers (keep old as fallback)

**Phase 2: Apple Music (2-3 months)**
1. Apple Developer Program enrollment + MusicKit key
2. `music_kit` plugin integration (focus on iOS first, Android later)
3. Auth flow (MusicKit user token)
4. Catalog search via MusicKit API
5. Playback backend via `music_kit`

**Phase 3: Tidal (deferred until user demand)**
1. WebView proof-of-concept
2. OAuth + Web SDK playback
3. Migrate to platform channels if justified

**Phase 4: Additional free providers (SRF, ORF)**
1. Follow ARD pattern (no auth, direct URLs)
2. Extend `CatalogProvider` interface
3. Add to provider registry

---

## Pushback on Your Approach

**Where you're wrong or under-thinking:**

1. **"Kids don't care about providers"**: True for playback, but false for content expiration. ARD content expires. Apple Music content doesn't (while subscribed). The parent needs visibility into this during curation, and the app needs graceful handling when content disappears.

2. **"Spotify is dead-end personal/testing"**: Don't underestimate the value of a "well-known broken" provider for testing your abstraction. Keep it working for your family — it's your integration test for multi-provider logic.

3. **Episode pattern regex in YAML**: This is fragile. Different providers format titles differently ("Folge 12", "12. Die Abenteuer", "Episode 12"). Consider provider-specific episode extraction or store episode numbers at import time.

4. **"The catalog should be provider-agnostic"**: Yes, but episode numbering isn't universal. TKKG episode 140 is "Draculas Erben" — but what if one provider has it as episode 140 and another as episode 1 (new release format)? You need canonical episode identity, not just numbers.

---

## Concrete Next Steps

Want me to start implementing this? I'd suggest:

1. **Create the provider abstractions** in `lib/core/providers/` (interfaces + registry)
2. **Migrate ARD** to the new structure (proves the abstraction works)
3. **Database migration** for normalized schema
4. **YAML schema update** for multi-provider series definitions

Which part do you want to tackle first? I can draft the interfaces, or start with the database migration plan.
[chris@desky lauschi]$ 
