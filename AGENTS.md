# AGENTS.md

Project context for AI coding agents (Pi, Claude Code, etc.).

## Project Overview

**lauschi** is a kids audio player. Parents curate content as visual cards; kids tap a card to play. No algorithm, no recommendations, no rabbit holes.

Flutter app targeting iOS and Android (DACH market focus). MVP in progress.

**Quality bar:** This is a Herzensprojekt. Polish is not optional. Every review finding gets addressed, not triaged into "nice to have" tickets. Error messages are specific, edge cases are handled, UX feedback is clear. Kids and parents deserve software that doesn't cut corners.

## Development Commands

All commands use [mise](https://mise.jdx.dev/) for tool management. Run `mise install` first.

```bash
mise run setup          # Install deps, codegen, verify analysis
mise run codegen        # Riverpod + Drift code generation
mise run watch          # Code generation in watch mode
mise run dev            # Run on connected device
mise run test           # All tests with env vars
mise run check          # Full CI: format + analyze + test
mise run build          # Build APK (runs codegen first)
```

Run a single test file:
```bash
flutter test test/core/catalog/catalog_service_test.dart --dart-define-from-file=.env.app
```

### Catalog Tools

Multi-provider catalog management via the `lauschi-catalog` CLI (`tools/` package).
Supports Spotify and Apple Music.

```bash
mise run catalog-add          # Add a new series (seed entry in series.yaml)
mise run catalog-discover     # Find missing artist IDs (all providers)
mise run catalog-validate     # Validate patterns against provider APIs
mise run catalog-curate       # AI-curate a series (both providers)
mise run catalog-review       # Review AI curation in TUI (legacy script)
```

Single-provider commands:
```bash
mise run catalog-validate -- -p apple_music    # Apple Music only
mise run catalog-discover -- "TKKG" -p spotify # Spotify only
```

## Architecture

### Core Stack
- **Flutter + Dart** (SDK ^3.7.0)
- **Riverpod** — state management (v3 with codegen via `@riverpod` annotations)
- **Drift** — local SQLite (tables in `lib/core/database/tables.dart`)
- **go_router** — navigation with redirect guards
- **Multi-provider audio**: ARD Audiothek (free, just_audio), Spotify (WebView SDK), Apple Music (MusicKit JS WebView)

### Key Architectural Decisions

**Multi-Provider Architecture**: Three audio providers share a common interface:
- **ARD Audiothek**: Free, no auth. Direct HTTP streams via `StreamPlayer` (just_audio).
- **Spotify**: OAuth PKCE, WebView SDK bridge. `SpotifyPlayer` wraps `SpotifyWebViewBridge`.
- **Apple Music**: MusicKit JS in WebView (same pattern as Spotify). Auth via native MusicKit SDK, tokens injected into JS. Forked `music_kit` plugin (packages/music_kit) used for auth + catalog API only. JWT generated on-device from .p8 key. User needs Apple Music subscription.

Provider-agnostic catalog browse: `CatalogSource` interface implemented by
`SpotifyCatalogSource` and `AppleMusicCatalogSource`. One `BrowseCatalogScreen`
serves all providers.

**Two-Phase Catalog Matching**: `CatalogService.match()` uses:
1. Keyword match — album title contains series keyword
2. Artist ID fallback (Spotify + Apple Music) — catches albums whose titles omit series name (e.g. TKKG "140/Draculas Erben")

**PIN-Gated Parent Mode**: Parent routes (`/parent/*`) are protected by PIN. The router's `_globalRedirect` checks `parentAuthProvider` state.

### Code Organization

```
lib/
├── app.dart                 # Root widget, WebView host, deep links
├── main.dart                # Entry point, media session init, Sentry
├── core/
│   ├── apple_music/         # MusicKit auth, API client
│   ├── ard/                 # ARD Audiothek API, models, helpers
│   ├── auth/                # PIN service
│   ├── catalog/             # Series YAML matching, CatalogSource interface
│   ├── connectivity/        # Network state
│   ├── database/            # Drift tables, repositories, content importer
│   ├── nfc/                 # NFC tag pairing
│   ├── providers/           # ProviderType enum, ProviderAuth, registry
│   ├── router/              # go_router config + redirects
│   ├── settings/            # Debug/diagnostic settings
│   ├── spotify/             # Auth (PKCE), API client, CatalogSource
│   └── theme/               # App theme
└── features/
    ├── onboarding/          # First-run flow
    ├── parent/              # Dashboard, card/group management, settings
    │   ├── screens/         # Complex screens: name/screen.dart + widgets/
    │   └── widgets/         # Shared parent widgets (draggable grid, etc.)
    ├── player/              # SpotifyPlayer, StreamPlayer, AppleMusicPlayer
    └── tiles/               # Kid home screen, tile detail, card widgets

tools/                       # lauschi-catalog CLI (Python package)
├── pyproject.toml
└── src/lauschi_catalog/
    ├── cli.py               # Click entry point
    ├── providers/           # Spotify + Apple Music API clients
    ├── catalog/             # Models, YAML loader, matcher
    └── commands/            # discover, validate, curate, token
```

### Generated Files

Files matching `**/*.g.dart` are generated by build_runner:
- Riverpod providers (`*_provider.g.dart`)
- Drift database (`app_database.g.dart`)
- Router codegen (`app_router.g.dart`)

Run `mise run codegen` after changing annotated classes.

### Catalog Data

`assets/catalog/series.yaml` — DACH Hörspiel series definitions with:
- `id` — stable snake_case identifier
- `keywords` — terms to match in album names (provider-agnostic)
- `episode_pattern` — regex to extract episode numbers (works across providers)
- `providers.spotify.artist_ids` — Spotify artist IDs for phase-2 matching
- `providers.spotify.albums` — pre-validated Spotify album list with episode mappings
- `providers.apple_music.artist_ids` — Apple Music artist IDs (129/162 series)

Validated by `lauschi-catalog validate` (tools/ package). 162 series, 5327
curated Spotify albums, 129 Apple Music artist IDs.

## Environment Variables

Two env files, both gitignored:

- **`.env`** — Developer keys for tooling. Loaded by mise (`_.file = ".env"`). Not passed to Flutter.
- **`.env.app`** — App build config only. Passed to Flutter via `--dart-define-from-file`.

Copy `.env.example` to `.env` and `.env.app.example` to `.env.app`, then configure.

`.env.app` keys:
- `ENABLE_SPOTIFY` — feature flag (default: `false`)
- `SPOTIFY_CLIENT_ID` — required when Spotify enabled
- `ENABLE_APPLE_MUSIC` — feature flag (default: `false`). Key material in `android/app/AuthKey_*.p8`; JWT generated on-device by the forked music_kit plugin
- `SENTRY_DSN` — optional error tracking
- `SENTRY_ENVIRONMENT` — defaults to "development"

All Flutter commands use `--dart-define-from-file=.env.app`.

`mise run dev` overrides flags to enable all providers + Sentry for local testing.

## Release Flow

Two-stage promotion: tag for testers, GitHub Release for stores.

### 1. Tester build (tag push)

```bash
mise run tag-release    # bumps calver, commits, tags, pushes
```

Triggers:
- **GitHub Actions** `android-release.yml` → APK → Firebase App Distribution
- **Codemagic** `ios-release` → IPA → TestFlight

Both build with `ENABLE_SPOTIFY=true`, `ENABLE_SENTRY=true`.

### 2. Store build (GitHub Release)

```bash
gh release create v2026.3.2    # from a tested tag
```

Triggers:
- **GitHub Actions** `android-store.yml` → AAB → Google Play (open testing)
- **GitHub Actions** `ios-store.yml` → triggers Codemagic `ios-store` → IPA → App Store

Both build with `ENABLE_SPOTIFY=false`, `ENABLE_SENTRY=false`. Zero data collection.

### Required secrets

| Secret | Where | Purpose |
|--------|-------|---------|
| `ANDROID_KEYSTORE_BASE64` | GitHub | Signing key |
| `ANDROID_KEYSTORE_PASSWORD` | GitHub | Keystore password |
| `ANDROID_KEY_PASSWORD` | GitHub | Key password |
| `ANDROID_KEY_ALIAS` | GitHub | Key alias |
| `FIREBASE_ANDROID_APP_ID` | GitHub | Firebase distribution |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | GitHub | Firebase auth |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | GitHub | Play Store upload |
| `SPOTIFY_CLIENT_ID` | GitHub + Codemagic | Spotify feature |
| `SENTRY_DSN` | GitHub + Codemagic | Error tracking |
| `CODEMAGIC_API_TOKEN` | GitHub | Trigger iOS store builds |
| `CODEMAGIC_APP_ID` | GitHub | Codemagic app identifier |

## Testing

**Every change must include tests.** Bug fixes need regression tests, new features need behavioral tests, refactors need tests verifying preserved behavior. No exceptions.

Tests live in `test/` mirroring `lib/` structure. Integration tests in `integration_test/`. Use `mocktail` for mocks, Patrol for on-device tests. See `docs/testing-strategy.md` for the full e2e test plan and ARD test file inventory.

### When to Write What

| Situation | Test type | Example |
|---|---|---|
| Pure logic, no Flutter/IO deps | **Unit test** | Catalog matching, title cleaning, episode number regex |
| Widget behavior, provider interactions, navigation | **Widget test** with `ProviderContainer` + real Drift | Router redirects, button visibility, player state transitions |
| Audio playback, multi-screen flows, persistence across restarts | **Patrol integration test** | Play → pause → resume, position saving, auto-advance |
| Error states hard to trigger with real audio | **Widget test** with fake backend | Network errors, expired content, disconnected states |

**Preference: integration-first.** Start with Patrol for any feature touching audio, navigation, or DB persistence. Extract widget tests only when:
- The integration test is flaky due to timing
- You need error states hard to trigger with real audio
- UI has many state permutations

Extract unit tests only for shared pure logic (catalog matching, data transforms, sorting).

**Regression-proof tests:** Every bug fix test must be verified against the broken code. Briefly revert the fix (comment out the key line, rename the constant, remove the field from copyWith), run the test, confirm it fails, then restore. If the test passes with the fix reverted, it's testing a copy of the logic, not the production code. Extract testable functions from private methods rather than duplicating logic in test files.

**Anti-patterns:**
- Don't mock just_audio — real playback catches issues mocks miss
- Don't mock the database — use in-memory Drift
- Don't duplicate production logic in tests — import and test the real function
- Don't write mega-tests (>5 minutes) — split into focused tests with shared `setUpAll`

### Widget Test Patterns

Follow `test/core/router/app_router_test.dart` and `test/features/tiles/kid_home_screen_test.dart`:

- **Provider overrides**: `ProviderContainer(overrides: [...])` + `UncontrolledProviderScope`. Override providers that need platform channels (Spotify bridge, media session, SharedPreferences).
- **Fake notifiers over mocks**: Extend the real notifier, override `build()` and the methods you need. Don't `Mock` Riverpod notifiers.
- **`pump()` not `pumpAndSettle()`**: Screens with infinite animations (progress bar ticker, connectivity polling) never "settle". Use explicit `pump()` with duration.
- **Parent auth bypass**: `parentAuthProvider.overrideWith(_AlwaysAuth.new)` where `_AlwaysAuth extends ParentAuth` with `build() => true`.
- **Onboarding bypass**: `onboardingCompleteProvider.overrideWith(...)` returning `true`.

### Integration Test Patterns (Patrol)

Follow `integration_test/helpers.dart` and `integration_test/ard_helpers.dart`:

- **App bootstrap**: `pumpApp($)` handles services init, SharedPreferences, ProviderScope, and frame pumping. Pass `prefs: {'onboarding_complete': true}` to skip onboarding.
- **Frame pumping**: `pumpFrames($, count: 10)` instead of `pumpAndSettle`. Same reason as widget tests — the app never fully settles.
- **Provider access in tests**: `ProviderScope.containerOf($.tester.element(find.byType(MaterialApp)))` to read/watch providers directly.
- **Audio state assertions**: Use `waitForPlaybackStarted($)` / `waitForPlaybackPaused($)` from `ard_helpers.dart`. These poll `playerProvider` every 200ms with 15s timeout. Fail fast on `error != null`.
- **DB setup**: Use `TileRepository.insert()` + `TileItemRepository.insertArdEpisode()` directly — don't navigate through parent UI for test setup. One integration test (`ard_browse_flow_test.dart`) covers the full add-via-UI path.
- **ARD fixture discovery**: `getStableTestEpisode(container)` discovers a playable ARD episode at runtime via `ArdApi`. No hardcoded episode IDs that break when content rotates. If ARD API is down, test skips (not fails).

### Running Tests

```bash
mise run test                                               # All unit + widget tests
mise run check                                              # Format + analyze + test
mise run test-integration                                   # Patrol on-device tests
patrol test -t integration_test/ard_playback_basic_test.dart  # Single integration test
```

### On-Device Touch Automation (adb)

Don't estimate tap coordinates from screenshots. Flutter widget positions rarely match visual estimation, especially on high-density screens with SafeArea/Spacer layouts.

Use `uiautomator dump` to get real accessibility bounds from Flutter's semantic tree:

```bash
adb shell uiautomator dump /sdcard/ui.xml
adb shell cat /sdcard/ui.xml | python3 -c "
import sys, re
xml = sys.stdin.read()
for m in re.finditer(r'content-desc=\"([^\"]+)\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml):
    desc, x1, y1, x2, y2 = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5))
    cx, cy = (x1+x2)//2, (y1+y2)//2
    print(f'{desc:20s} center=({cx},{cy})  bounds=[{x1},{y1}][{x2},{y2}]')
"
# Then tap using the reported center coordinates:
adb shell input tap 309 1099
```

This works because Flutter exposes `Semantics` labels as Android accessibility `content-desc`. Buttons without explicit `Semantics` labels may show their text content instead. The bounds are in physical pixels.

## Linting

Uses `very_good_analysis` with relaxed rules (see `analysis_options.yaml`):
- No public_member_api_docs (app, not library)
- No 80-char line limit
- `TODO(#issue)` format instead of `TODO(username)`

Generated files (`*.g.dart`) are excluded from analysis.

## Code Review

[CodeRabbit](https://coderabbit.ai/) is set up for AI-assisted code review via CLI.
Run it after commits to get a second opinion:

```bash
timeout 300 coderabbit review --plain --base-commit HEAD~1 -c AGENTS.md
```

- `--plain` outputs text (no TUI), suitable for agent consumption
- `--base-commit HEAD~N` reviews the last N commits
- `-c AGENTS.md` feeds project conventions to the reviewer
- `timeout 300` gives it up to 5 minutes (initial reviews can be slow)

Not a gate. Use it as a sanity check, especially after larger changes.
Fix what makes sense, ignore nitpicks that don't add value.

## AI Agent Config

The repo includes config for [Pi](https://buildwithpi.com) and [Claude Code](https://docs.anthropic.com/en/docs/claude-code):

- **`AGENTS.md`** — this file. Project context for all AI coding agents.
- **`.pi/skills/`** — Pi-specific skills (e.g. `code-simplifier` for Dart/Flutter refinement).
- **`.agents/skills/`** — Shared skills from [dotagents](https://github.com/nichochar/dotagents) (Sentry integration). Managed by `agents.toml` + `agents.lock`. The `.claude/skills` symlink makes these visible to Claude Code too.
- **`.claude/settings.local.json`** — Per-user Claude Code permissions (gitignored).
