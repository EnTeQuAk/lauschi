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

Multi-provider catalog management via the `lauschi-catalog` CLI plus a FastAPI
web UI (both in `tools/`, a Python package, tests with pytest). Supports
Spotify and Apple Music. The AI commands (`curate`, `audit`) run pydantic-ai
agents through the opencode-zen relay (OpenAI-compatible). Keys, all in `.env`
(loaded by mise): `SPOTIFY_CLIENT_ID`/`SPOTIFY_CLIENT_SECRET` for the provider
APIs (Apple Music uses the shared MusicKit key `android/app/AuthKey_*.p8`),
`OPENCODE_API_KEY` for model calls, `BRAVE_API_KEY` for the agents' web search
tool.

Default models: `kimi-k2.6` curates, `minimax-m2.7` audits. The 4-eye
principle requires two different model families. Curate and audit pin
temperature 0 and seed 42 for reproducibility (finalize uses 0.1);
per-model and per-phase overrides live in `_opencode.py` (`get_model_settings`).

**Full pipeline** (runs autonomously, takes hours for the full catalog; a
failing stage does not stop the later ones, so check the log and
`catalog-review` afterwards):
```bash
mise run catalog-pipeline              # curate → reconcile → audit → lint → apply → validate → drift
mise run catalog-pipeline -- --force   # Re-curate + re-audit even where curations exist
mise run catalog-pipeline-one -- <id>  # Same stages for a single series
```

**Individual steps:**
```bash
mise run catalog-add          # Add a new series (seed entry in series.yaml)
mise run catalog-discover     # Find + write missing artist IDs (all providers)
mise run catalog-curate       # AI-curate a single series
mise run catalog-curate-all   # AI-curate all series (skips existing, --force to redo)
mise run catalog-audit        # 4-eye audit (all, or pass a series id)
mise run catalog-apply        # Write approved curations into series.yaml
mise run catalog-splits       # Manage AI-proposed series splits
mise run catalog-validate     # Validate series.yaml against provider APIs (L1 + L5)
mise run catalog-drift        # Check shipped albums against live provider records
mise run catalog-report       # Show curation statistics (included/excluded/gaps)
mise run catalog-review       # List series needing human attention (escalated, flagged)
mise run catalog-edit         # Manual include/exclude on curations
mise run catalog-log-summary  # Per-series re-run report from a pipeline log
mise run catalog-test         # Run the tools/ pytest suite
mise run catalog-web          # Catalog web UI (state browse, background jobs, review queue)
```

CLI subcommands without a mise task: `lint`, `reconcile`, `eval`, `delete`.
`eval` scores curator/auditor runs produced in a scratch repo root
(`LAUSCHI_REPO_ROOT=/tmp/...`) against ground-truth verdicts; run it before
changing prompts or models.

**Single-provider and single-series:**
```bash
mise run catalog-validate -- -p apple_music       # Apple Music only
mise run catalog-discover -- "TKKG" -p spotify    # Spotify only
mise run catalog-curate -- "TKKG"                 # Curate one series
mise run catalog-curate -- "Senta" --music        # Curate a music artist (not Hörspiel)
mise run catalog-curate -- "TKKG" --dry-run       # Print prompts without calling AI
```

#### Curation Pipeline

Each series flows through seven stages (`catalog-pipeline` runs them in order):

1. **Curate** (`curate`): pydantic-ai agents classify every album on the
   artist's provider pages as include/exclude, with an episode number for
   includes. Per series: provider discovery (artist IDs from series.yaml,
   search fallback), prefetch of album details, a metadata agent, batched
   album decisions (~30 per batch), a finalize agent (episode pattern, series
   facts). Re-curation is incremental: `--force` re-enters a series but
   carries prior decisions forward as a pre-seed the model may override, so
   a decided album is not re-asked. Albums the model does not decide stay
   absent from the curation; the run is then marked incomplete and apply
   skips it. A prior curation with invalid album records (e.g. an
   off-vocabulary exclude_reason) aborts the run; normalize first with
   `lauschi-catalog reconcile --all --normalize`.
   Split-off children (`split_from`) are refused; curate the parent.
   Output: `assets/catalog/curation/{series_id}.json` (committed to git).

2. **Reconcile** (`reconcile`): Deterministic cross-provider consistency.
   A title included on one provider but excluded on the other under a
   whitelisted content reason (compilation, wrong_content_type, ...)
   auto-flips to include. Structural reasons like `sub_series_bleed` are
   left for human review. No AI.

3. **Audit** (`audit`): The second model reviews one curation: sub-series
   bleed, episode gaps, duplicates, pattern problems, split proposals.
   One-shot for small series, token-budgeted chunks for large ones. Writes
   the `review` block into the curation JSON: status `approved` or
   `escalated`, plus album overrides and fact updates. Escalates instead of
   approving when it declines approval, has more than 5 concerns, or a
   regression flag fired; escalated overrides are recorded, not applied.

4. **Lint** (`lint`): Deterministic findings over curations: episode gaps,
   duplicates, regressions against the previous curation, unaudited facts.
   Advisory; findings are reported, not enforced.

5. **Apply** (`apply`): Writes approved curations into `series.yaml`: album
   IDs with episode numbers, patterns, artist IDs, and audited series facts
   only. Refuses curations that are incomplete, escalated, stale (curated
   after the last audit), or whose album loss crosses a guard threshold.
   `--force` overrides.

6. **Validate** (`validate`): Checks series.yaml against live provider APIs.
   L1 offline (structure, regex compiles, unique IDs) and L5 (artist
   discography match rate).

7. **Drift** (`drift`): Re-checks every shipped album against its live
   provider record and reports gone or changed albums.

Escalations and lint findings are resolved by hand: `catalog-review` lists
what needs attention, `catalog-edit` and `catalog-splits` make the changes,
`mise run catalog-audit --force` re-checks afterwards.

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

**Catalog Matching by Album ID**: The app bundles `series.yaml` and builds an
album-ID index at load: O(1) provider+album_id lookup to the owning series and
the curated episode number. Episode numbers ship in the catalog; nothing is
re-derived at runtime. Series discovery (e.g. when a parent searches for a
series to add) uses local title/alias search (`CatalogService.search`).

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

tools/                       # lauschi-catalog CLI + web UI (Python package)
├── pyproject.toml           # click, ruamel.yaml, pydantic-ai-slim, diskcache; extras: ai, web
├── src/lauschi_catalog/
│   ├── cli.py               # Click entry point
│   ├── catalog/             # Domain ops (curate_ops, audit_ops, apply_ops, lint_ops, ...),
│   │                        # models, YAML loader, matcher, staleness checks (lifecycle)
│   ├── commands/            # One thin Click command per file over the catalog/ ops
│   ├── providers/           # Spotify + Apple Music API clients (7-day diskcache)
│   ├── prompts/curate/      # SKILL.md + PHASE_*.md + references/, composed per phase/type
│   ├── eval/                # Curator/auditor eval harness (ground-truth scoring)
│   ├── web/                 # FastAPI review UI (routes, Jinja templates, background jobs)
│   ├── _opencode.py         # Model construction and per-model/per-phase settings
│   └── search.py            # Brave Search + page fetcher for the agents' web tools
└── tests/                   # pytest suite, offline (no provider keys, no model calls)
```

### Generated Files

Files matching `**/*.g.dart` are generated by build_runner:
- Riverpod providers (`*_provider.g.dart`)
- Drift database (`app_database.g.dart`)
- Router codegen (`app_router.g.dart`)

Run `mise run codegen` after changing annotated classes.

### Catalog Data

`assets/catalog/series.yaml` is the DACH Hörspiel series catalog (~1.6 MB,
bundled into the app) with:
- `id`: stable snake_case identifier
- `title` + `aliases`: runtime series search and matching
- `episode_pattern`: regex (one capture group) extracting episode numbers
- `content_type`: `hoerspiel` (default), `music`, or `audiobook`
- `series_facts`: audited era boundaries, known episode gaps, sub-series
- `split_from`: marks a series split off from a parent entry
- `providers.spotify.albums` / `providers.apple_music.albums`: pre-validated
  album lists (provider IDs + episode numbers), written by the pipeline
- `providers.*.artist_ids`: artist IDs for discovery and fallback matching

Alongside it: `assets/catalog/curation/{id}.json` (280 committed curation
files, the pipeline's per-series state), `deleted.yaml` (ids that must not be
re-added), `.cache/{provider}/` (7-day provider API cache, gitignored),
`logs/catalog/` (pipeline run logs, gitignored).

Validated by `lauschi-catalog validate` (tools/ package). Today: 280 series
(113 of them split-off children), 7,170 curated Spotify and 6,750 Apple Music
albums.

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

## Changelog & Release Process

### Changelog Format

`CHANGELOG.md` is **user-facing only** (German). Technical details only if they translate to tangible user benefits (faster, more stable, better privacy, security fixes).

**Structure per release:**
```markdown
## vYYYY.MM.INC (Monat YYYY)

🎯 **Kurzer Titel**
Beschreibung in 1-2 Sätzen. Was ändert sich für Eltern/Kinder?

✨ **Weitere Verbesserungen**
- Punkt 1: Konkrete Verbesserung
- Punkt 2: Konkrete Verbesserung

🐛 **Behoben**
- Was war kaputt, jetzt funktioniert es wieder
```

**Emoji conventions:**
- `⏳` — Content/availability changes
- `🗄️` — Data/storage changes  
- `🧹` — Cleanup, dead code removal
- `🔧` — Bug fixes
- `🚫` — Feature removal (with explanation why)
- `✨` — New features
- `🎵` — Music/audio related
- `🍏` — Apple Music
- `📂` — Organization/folders
- `🗑️` — Deletion features
- `🔍` — Search improvements
- `🛠️` — Minor fixes
- `🧪` — Testing improvements
- `🎯` — Main feature of release
- `🐛` — Bug fix section

### Release Checklist

Before `mise run tag-release`:

1. **Update CHANGELOG.md**
   - Add new section at top (newest first), keep previous entries
   - Use calver version pattern: `v2026.4.3` 
   - German language, parent-facing descriptions
   - Group by impact (major features first, fixes last)
   - Bold headings are labels, not sentences (no trailing period)

2. **Update `distribution/whatsnew/de-DE`**
   - Google Play "What's New" text, max 500 characters
   - Summarize the most important user-facing changes
   - Same tone as CHANGELOG.md but shorter
   - Verify size: `wc -c distribution/whatsnew/de-DE`

3. **Verify tests pass**
   ```bash
   mise run check
   ```

4. **Commit changelog + whatsnew**
   ```bash
   git add CHANGELOG.md distribution/whatsnew/de-DE
   git commit -m "docs: changelog for vX.Y.Z"
   ```

5. **Tag and release**
   ```bash
   mise run tag-release    # bumps version, commits, tags, pushes
   ```

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
- **`.pi/skills/`** — Pi-specific skills.
- **`.agents/skills/`** — Shared skills managed by [dotagents](https://github.com/getsentry/dotagents). The `.claude/skills` symlink makes these visible to Claude Code.
- **`.claude/settings.local.json`** — Per-user Claude Code permissions (gitignored).

### Dotagents Setup

Skills are declared in `agents.toml` and installed via dotagents:

```bash
# Install all skills after cloning
npx @sentry/dotagents install

# List installed skills
npx @sentry/dotagents list

# Add a skill from getsentry/skills
npx @sentry/dotagents add getsentry/skills find-bugs
```

Remote skills (from getsentry/skills and getsentry/sentry-for-ai) are gitignored and fetched on install. Local skills in `.agents/skills/` (update-changelog, code-simplifier) are committed to the repo.
