# Test Coverage Gaps (compiled from test infra review, 2026-04)

These are gaps that the multi-agent test infrastructure review (9
commits, 2 rounds, 41 files reviewed) flagged as real but did NOT
fix because they would have expanded the scope of the review into
new test authoring. They're filed here so they don't get lost.

Each gap below cites the round 1 commit body where it was first
documented. Sort by impact, not order of discovery.

## High value

### `ContentImporter.importArdShow` + ARD pagination + duplicate URI handling

**File**: `lib/core/database/content_importer.dart`
**First flagged**: Group B round 1 (commit `6e2c5cf6`)

The Spotify batch path of `ContentImporter` is well covered by
`test/core/database/content_importer_test.dart`. The ARD path
(`importArdShow`) is not — it has its own pagination loop with a
100-page safety limit, a `_assignExistingToGroup` branch that
de-dupes already-imported episodes, and a different timing model
(items appear over multiple HTTP fetches). None of these are
exercised in unit tests.

The integration test at `integration_test/ard_browse_flow_test.dart`
covers ONE episode end-to-end but doesn't drive multi-page imports
or re-imports.

**Suggested fix** (own commit, ~80-150 lines):
- New `test/core/database/content_importer_ard_test.dart` that
  uses an HTTP fake for `ArdApi` to drive multi-page responses.
- Test cases:
  - Single page returns ≤ pageSize items, no pagination
  - 3-page response (each with `nextOffset`)
  - 100-page safety limit fires before infinite loop
  - Re-import of existing tile + episode dedupes via
    `_assignExistingToGroup`

### NFC tag cascade on tile delete

**File**: `lib/core/database/tile_repository.dart` (around line
365-369, where the cascade is currently a comment, not code)
**First flagged**: Group B round 1 (commit `6e2c5cf6`)

The `tile_repository.delete()` method should cascade-delete any
NFC tags pointing at the deleted tile. Currently this is done via
the foreign key constraint at the SQL level, but no test verifies
the cascade fires correctly. NFC pairing is a parent-mode feature
with limited usage so the risk is low, but the gap is real.

**Suggested fix** (~30-50 lines):
- Add a test case to `test/core/database/tile_repository_test.dart`:
  insert a tile, pair an NfcTag, delete the tile, assert the
  NfcTag row is gone.
- If the FK isn't actually configured, this test will fail-loud
  and we'll fix the production code.

### Path parameter parsing in app_router

**File**: `lib/core/router/app_router.dart`
**First flagged**: Group F round 1 (commit `cc5f1598`)

Routes like `/tile/:id`, `/parent/tiles/:id`,
`/parent/catalog/:seriesId`, `/parent/discover/:showId` all use
go_router's path parameter parsing via `state.pathParameters['id']`.
None of these are tested. We don't verify:
- The parameter is correctly extracted from the URL
- The parameter reaches the screen widget
- Invalid parameters (empty, wrong format) are handled

**Suggested fix** (~50 lines):
- Add 1-2 tests to `test/core/router/app_router_test.dart`:
  - Navigate to `/tile/abc123`, assert the screen receives
    `tileId: 'abc123'`
  - Navigate to `/tile/`, assert appropriate error or fallback

## Medium value

### Spotify webview bridge `_onMessage()` JSON decoding path

**File**: `lib/features/player/spotify_webview_bridge.dart`
**First flagged**: Group D round 1 (commit `a7190ebb`)

`spotify_webview_bridge_test.dart` covers the outbound Dart-to-JS
path (pause, resume, seek, etc.) but not the inbound
JS-to-Dart path through `_onMessage()`. Real bugs have hidden in
the channel name handling and JSON decoding (stale device IDs,
dropped state events).

**Suggested fix** (~50-80 lines):
- Add tests that directly call `_onMessage()` with malformed,
  oversized, and well-formed payloads
- Verify the bridge correctly:
  - Updates state for valid `state` events
  - Updates device ID for valid `device` events
  - Ignores malformed JSON without crashing
  - Doesn't leak state from previous messages

### Unknown route handling

**File**: `lib/core/router/app_router.dart`
**First flagged**: Group F round 1 (commit `cc5f1598`)

Navigating to `/garbage` or any other unmatched route — what does
go_router do? We don't verify and we don't have an explicit error
screen. Default behavior is "redirect to /" or show a 404 page,
but neither is documented or tested.

**Suggested fix** (~20 lines):
- One test in `test/core/router/app_router_test.dart` navigating
  to `/this-does-not-exist` and asserting either
  `_currentLocation == '/'` (redirect) or that an error screen
  shows.

### `tileProgressProvider` extracted filter testing

**File**: `lib/core/database/tile_item_repository.dart`
(near `tileProgressProvider`)
**First flagged**: Group B round 1 (commit `6e2c5cf6`)

The `tileProgressProvider` filters items via `isItemExpired` to
compute per-tile heard counts. The test at
`test/core/database/expiration_test.dart` duplicates the filtering
logic inline because the production provider is a
`StreamProvider.family` that's hard to unit test.

If the production filter ever grows a second exclusion rule (e.g.
also hide items past their `availableUntil`), the inline duplicate
in the test won't catch it.

**Suggested fix** (~30 lines):
- Extract the filter loop from `tileProgressProvider` into a pure
  function `computeTileProgress(List<TileItem>)` and test that
  function directly.
- Update the StreamProvider to call the pure function.
- Delete the inline duplicate in expiration_test.

## Low value (or already covered indirectly)

### Drag-and-drop gesture testing for `DraggableTileGrid`

**File**: `lib/features/parent/widgets/draggable_tile_grid.dart`
**First flagged**: Group E round 1 (commit `d455b69e`)

`draggable_tile_grid_test.dart` covers layout (the LAUSCHI-1M
shrinkWrap fix) but not actual drag gestures. Drag testing in
widget tests is finicky and the integration test
`tile_nesting_test.dart` covers drag-induced nesting end-to-end
on a real device. So the gap exists at the unit-test level but
the behavior IS covered at the integration level.

**Suggested fix**: leave it. The integration test is sufficient.

### LAUSCHI-1H notification crash on Android 9

**File**: `lib/features/player/media_session_handler.dart`
**First flagged**: Group H round 1 (commit `14211f84`)

The `single_episode_notification_test.dart` was renamed during
round 1 because modern Android ignores the out-of-bounds index
that triggered LAUSCHI-1H on Galaxy Note 8. The actual regression
can only be reproduced on Android ≤ 9.

**Suggested fix**: only relevant if we add an Android 9 device to
the test matrix. If we do, re-run the test (the assertions are
still valid for that platform) under the LAUSCHI-1H name.

## Process notes

The 4 verified false positives from round 1 are NOT listed here —
they were errors in reviewer scope, not real gaps:

1. **B**: kimi+sonnet flagged "missing nestInto/unnest unit tests"
   but `integration_test/tile_nesting_test.dart` has 9 patrolTests
   covering them.
2. **E**: kimi flagged `ValueKey('expired-1')` lookups as
   potentially fake-passing, but production uses `ValueKey(card.id)`
   so the test is correct.
3. **G**: All 3 round 1 reviewers (and round 2 reviewers without
   the explicit "do not re-flag" note) flagged "missing
   `expect(state.error, isNull)` after `waitForPlayback($)`", but
   `waitForPlayback` already checks `state.error` and `fail()`s
   fast internally (documented in its docstring as of round 1).
4. **H4**: kimi flagged `onboarding_test.dart` PIN gate test for
   missing `clearAppState`, but `pumpApp` resets SharedPreferences
   via `setMockInitialValues` on every invocation.
