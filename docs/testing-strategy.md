# Testing Strategy

## When to Write What

| Situation | Test Type | Why |
|---|---|---|
| Pure logic without Flutter/IO dependencies | **Unit test** | Fast, no setup. Catalog matching, title cleaning, episode number extraction. |
| Widget behavior with many UI states | **Widget test** (with `ProviderContainer` + real Drift) | Fast, no device. Router redirects, button visibility, state transitions. |
| Database operations + provider interactions | **Widget test** (with in-memory Drift) | Tests real SQL, real providers, real state — just no platform channels. |
| Audio playback, full-screen flows, platform features | **Patrol integration test** | Real device, real audio, real navigation. The gold standard. |
| Error states hard to trigger with real audio | **Widget test** with fake backend | Network errors, expired content, disconnected states. |

### Decision Flow

1. **Default: Patrol integration test.** If it touches audio, navigation, or persistence across screens, test it on-device.
2. **Extract widget test** when:
   - The integration test is flaky due to timing
   - You need to test error states that are hard to trigger with real audio
   - UI has many permutations (button states, layout variants)
3. **Extract unit test** only for:
   - Shared logic across providers (catalog matching, title normalization)
   - Complex data transformations
   - Algorithmic code (sorting, progress calculation)

### Anti-Patterns

- Don't write widget tests that mock just_audio — real playback catches issues mocks can't.
- Don't write mega-tests that take 5+ minutes. Split into focused tests with shared setup.
- Don't mock the database when you can use in-memory Drift.

## Integration Test Plan (ARD Audiothek)

ARD content is free, no auth required, uses `DirectPlayer` (just_audio). This lets us test ~60% of the app without Spotify credentials.

### Test Infrastructure

#### `integration_test/ard_helpers.dart`

Shared helpers for ARD integration tests:

- **`discoverArdEpisode()`** — Finds a suitable episode at runtime via `ArdApi.getKidsShows()` + `getItems()`. Picks an episode with `bestAudioUrl != null` and `duration >= 30s`. Caches result across tests in the same group. Falls back across multiple shows if the first is unavailable.
- **`insertTestTileWithEpisode()`** — Uses `TileRepository.insert()` + `TileItemRepository.insertArdEpisode()` to create a tile + episode directly in the database. Bypasses the parent UI flow (15-30s → 1s).
- **`waitForPlayback()`** — Polls `playerProvider` every 200ms until `isPlaying && !isLoading` or `error != null` or timeout (15s). Fails fast on errors.
- **`waitForPause()`** — Same pattern, waits for `!isPlaying`.
- **`getContainer()`** — Extracts `ProviderContainer` from the widget tree for direct provider access.

#### Provider Overrides for Tests

- Override `_minPlayTimeMs` (30s → 2s) to avoid waiting 30s for position saves
- Override `_completionThresholdMs` (5s → 500ms) for faster auto-advance tests
- Use `PlayerConfig` provider to make these configurable without modifying production code

### Test Files

#### `integration_test/ard_playback_test.dart`
Core playback flow:
- `plays ARD episode via DirectPlayer` — Insert tile, tap it, verify audio plays (isPlaying: true), verify player screen opens
- `pauses and resumes playback` — Play → pause button → verify paused → play button → verify resumed
- `seeks forward via progress bar` — Play → drag slider → verify position jumped
- `NowPlayingBar shows track info` — Play → navigate back → verify bar shows title + artist

#### `integration_test/ard_position_test.dart`
Position persistence:
- `saves position after play threshold` — Play for >threshold → pause → verify DB has position
- `resumes from saved position` — Save position → navigate away → tap tile again → verify resumes near saved position
- `does not save position for brief taps` — Play for <threshold → pause → verify no position saved

#### `integration_test/ard_completion_test.dart`
Episode completion + auto-advance:
- `marks episode as heard on completion` — Seek to near-end → wait for completion → verify `isHeard: true` in DB
- `auto-advances to next episode in series` — Add 2 episodes to same tile → play first → let complete → verify second starts playing
- `does not auto-advance for standalone tiles` — Episode without group → completes → stays paused

#### `integration_test/ard_browse_flow_test.dart`
Full parent UI flow (one test, validates the UI path works):
- `browse ARD → add show → appears in kid grid` — Open parent dashboard → browse ARD → select show → add episode → go to kid mode → verify tile appears

#### `integration_test/tile_management_test.dart`
Tile CRUD (no audio needed, but uses on-device DB):
- `creates tile with custom name` — Parent flow: create tile → verify name appears
- `renames tile` — Edit tile → change name → verify updated
- `deletes tile` — Delete tile → verify gone from grid
- `reorders tiles` — Drag tile A below tile B → verify new order persists

### Stable ARD Fixtures

Rather than hardcoding show IDs (which break when content changes), tests discover content at runtime:

1. Call `ArdApi.getKidsShows()` to get current kids shows
2. Pick first show with `numberOfElements > 5` (has enough episodes)
3. Fetch episodes, pick one with `bestAudioUrl != null` and `duration >= 30`
4. Cache result in `setUpAll` — all tests in the group share it
5. If discovery fails, `skip()` the test with a message (don't fail CI)

### Execution

```bash
# All integration tests
mise run test-integration

# Single file
patrol test -t integration_test/ard_playback_test.dart

# With verbose output
patrol test -t integration_test/ard_playback_test.dart --verbose
```

### Future: Spotify Tests

Once Spotify credentials are available for CI:
- Same patterns, but using `SpotifyBackend` instead of `DirectPlayer`
- Multi-track albums (next/prev track)
- Resume across WebView reconnects
- Token refresh during playback
