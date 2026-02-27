cd /home/chris/Projects/lauschi && pi --model kimi-k2.5 --thinking xhigh -p - < /tmp/kimi-architecture-session-3.md
[chris@desky lauschi]$ cd /home/chris/Projects/lauschi && pi --model kimi-k2.5 --thinking xhigh -p - < /tmp/kimi-architecture-session-3.md
Warning: No models match pattern "opencode/kimi-k2.5-free"
 Now I have a clear picture of the current state. Let me write the comprehensive architecture decisions document.

---

# Architecture Planning Session 3: Decisions & Migration Plan

## Hard Problem 1: The Catalog's Real Purpose

**Recommendation: Catalog is optional per provider, not in provider abstraction**

The catalog's purpose is matching unstructured content to known series. This distinction belongs in the *content source* layer, not the provider abstraction:

```
Content Sources:
├── Structured: ARD, SRF, ORF (have native show/episode hierarchy)
└── Unstructured: Spotify, Apple Music, Tidal (need catalog matching)
```

**Decision:**
- **Provider interface** knows nothing about the catalog
- **Catalog-aware sources** (music streaming) wrap their API client with a `CatalogMatchingDecorator` or just use `CatalogService.match()` at the UI layer (as `BrowseCatalogScreen` does today)
- **Structured sources** (ARD family) don't use the catalog at all

**Deferred work:** Don't extract this into a formal decorator pattern now. Keep the current approach where `BrowseCatalogScreen` uses `CatalogService.match()` for Spotify results. When we add Apple Music, we'll use the same pattern.

---

## Hard Problem 2: The Browse/Add Flow

**Recommendation: Option C (Hybrid) with provider-specific browse as default**

```
Parent Dashboard
└── "Inhalte hinzufügen" → ProviderTabsScreen (default: first connected provider)
    ├── ARD Audiothek → DiscoverScreen (hierarchical browse: featured → shows → episodes)
    ├── Apple Music → BrowseCatalogScreen with music_kit search
    └── Spotify → BrowseCatalogScreen with spotify_api search
```

**Search:** Cross-provider unified search is a **nice-to-have for later**. The value proposition is weak for MVP:
- Parent searching "Bibi Blocksberg" wants *episodes*, not "which provider has it"
- Each provider's episode structure differs (ARD: individual episodes, Spotify: albums)
- Cross-provider results would need complex merging/normalization

**Decision:**
- Default view: **provider tabs**, each with their native browse UI
- Search: **provider-scoped** initially (search within the selected provider)
- Post-MVP: Consider unified search when we have 3+ providers and user feedback asks for it

---

## Hard Problem 3: Migration Path (File-by-File)

**Phase 1: Foundation (Week 1) — Safe, low risk**

1. **`lib/core/providers/provider_type.dart`** — New file
   ```dart
   enum ProviderType { spotify, ardAudiothek, appleMusic }
   extension on String? { ProviderType? toProviderType() => ... }
   ```

2. **`lib/core/providers/provider_auth_interface.dart`** — New file
   ```dart
   abstract class ProviderAuth {
     bool get isAuthenticated;  // Always true for ARD
     Future<void> authenticate();  // No-op for ARD
     Future<void> logout();  // No-op for ARD
   }
   ```

3. **`lib/core/spotify/spotify_auth_provider.dart`** — Add implements
   ```dart
   class SpotifyAuth extends _$SpotifyAuth implements ProviderAuth { ... }
   ```

4. **`lib/core/ard/ard_auth.dart`** — New file (trivial no-op implementation)

5. **`lib/core/database/tables.dart`** — String → enum migration
   - Add `ProviderType` enum support
   - Keep DB as TEXT, convert in code
   - Migration: none needed (values already match)

**Phase 2: Catalog Awareness (Week 2) — Medium risk**

6. **`assets/catalog/series.yaml`** — Add provider identifiers
   ```yaml
   series:
   - id: yakari
     title: Yakari
     identifiers:
       spotify:
         artist_ids: [...]
       apple_music:
         artist_ids: [...]  # When we have them
   ```

7. **`lib/core/catalog/catalog_service.dart`** — Add `providers:` map parsing
   - Keep existing fields for backwards compat
   - New `identifiers` field parsed as `Map<ProviderType, ProviderSeriesId>`
   - `CatalogService.match()` takes optional `ProviderType` parameter

8. **`lib/core/catalog/catalog_provider_interface.dart`** — New file
   ```dart
   abstract class CatalogSearchProvider {
     String get providerId;
     Future<List<SearchResult>> search(String query);
   }
   ```

9. **`lib/core/ard/ard_catalog_provider.dart`** — New file (wraps `ArdApi` for show search)

**Phase 3: Player Provider Abstraction (Week 3) — Higher risk, careful testing**

10. **`lib/core/providers/player_provider_interface.dart`** — New file
    ```dart
    abstract class PlayerProvider {
      String get providerId;
      Future<void> play(String contentUri, {ResumeState? resume});
      Future<void> pause();
      Future<void> resume();
      Future<void> seek(Duration position);
      Stream<PlaybackState> get stateStream;
    }
    ```

11. **`lib/features/player/player_provider.dart`** — Refactor
    - `PlayerNotifier` keeps branching logic but uses `PlayerProvider` instances
    - Extract `SpotifyPlayerProvider` and `DirectPlayerProvider` classes
    - Register providers in a `PlayerProviderRegistry`

**Phase 4: Integration (Week 4)**

12. **UI screens** — Update to use new abstractions
    - `BrowseCatalogScreen` → accepts `CatalogSearchProvider` via constructor
    - `DiscoverScreen` → stays mostly the same (ARD is already "catalog-native")
    - `SettingsScreen` → iterate over registered providers dynamically

**Risk mitigation:**
- Each phase ends with `mise run check` passing
- Phase 3 has integration tests running on every commit
- Feature flags: `appleMusicEnabled = false` until Phase 4

---

## Hard Problem 4: Show Subscriptions Across Providers

**Recommendation: Keep `ShowSubscriptions` provider-generic, defer non-ARD sync**

**Decision:**
- **ARD**: Full auto-sync (poll `programSet`, insert new `TileItem`s, respect `maxEpisodes`)
- **Apple Music**: **Deferred**. When added, periodic sync by artist ID is possible but rate limits make this expensive. Evaluate post-MVP.
- **Spotify**: **Not practical**. No push mechanism, strict rate limits, albums are static. Parents manually add new releases.

**Rationale:**
- ARD content rotates (news episodes weekly, Betthupferl daily)
- Music streaming content is static (albums don't change)
- Premature abstraction for Apple Music sync is YAGNI — we don't have the SDK keys yet

---

## Hard Problem 5: Provider Settings UX

**Recommendation: Simple list with connection toggle per provider**

```
Settings → Anbieter (Providers)
├── ARD Audiothek [Immer aktiv ℹ️]  (no action, just info)
├── Spotify [Verbunden ✅] [Trennen]
├── Apple Music [Verbinden]  (disabled until we have SDK keys)
└── Tidal [Demnächst verfügbar]  (disabled placeholder)
```

**Questions answered:**
- **Show unavailable providers?** Yes, as disabled items with "Demnächst" label. Sets expectations.
- **Can parent disable connected provider?** **Not for MVP.** A connected provider is "active". Parent can disconnect (logout) which disables it.
- **What happens to TileItems on disconnect?** **Keep them, grayed out.** Kid sees "Inhalt nicht verfügbar" error on tap (same as expired ARD content). Parent can reconnect to re-enable.

---

## Hard Problem 6: Subscription Lapse Handling

**Recommendation: Single error type with provider-specific messaging**

```dart
// Keep existing error type
PlayerError.contentUnavailable  // covers both expired and subscription-lapsed

// Provider provides human-readable reason via error metadata
PlaybackState.error = PlayerError.contentUnavailable;
PlaybackState.errorDetails = {
  'reason': 'subscription_lapsed',  // or 'content_expired', 'region_blocked'
  'provider': 'apple_music',
  'action': 'reconnect',  // 'reconnect' | 'none' | 'upgrade'
};
```

**UI handling:**
- Kid sees: "Inhalt nicht verfügbar" (generic, simple)
- Parent sees detail in error toast: "Apple Music-Abo abgelaufen. Tippe für Einstellungen."

**Deferred:** No separate error types. The complexity of differentiating isn't worth the code surface area for MVP.

---

## Summary: What to Solve NOW vs Defer

| Problem | Decision | Priority |
|---------|----------|----------|
| 1. Catalog purpose | Optional per content source, not in provider interface | NOW |
| 2. Browse/add flow | Provider tabs as default, search per-provider | NOW |
| 3. Migration path | 4-phase file-by-file plan (see above) | NOW (Phase 1) |
| 4. Show subscriptions | Keep generic, only ARD implements sync | NOW (schema only) |
| 5. Provider settings UX | Simple list, disconnect=disable, gray old items | NOW |
| 6. Subscription lapse | Single error type, provider in metadata | NOW |

### Deferred Post-MVP
- Cross-provider unified search
- Apple Music auto-sync
- Provider "disable without disconnect" toggle
- Granular error types for each failure mode

---

Ready to implement Phase 1 of the migration? I can start with the `ProviderType` enum and `ProviderAuth` interface.
[chris@desky lauschi]$ 
