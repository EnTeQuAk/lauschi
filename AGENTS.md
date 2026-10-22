# AGENTS.md

Project context for AI coding agents (Pi, Claude Code, etc.).

## Project Overview

**lauschi** is a kids audio player. Parents curate content as visual cards; kids tap a card to play. No algorithm, no recommendations, no rabbit holes.

Flutter app targeting iOS and Android (DACH market focus). MVP in progress.

**Quality bar:** This is a Herzensprojekt. Polish is not optional. Every review finding gets addressed, not triaged into "nice to have" tickets. Error messages are specific, edge cases are handled, UX feedback is clear. Kids and parents deserve software that doesn't cut corners.

## Development Commands

All commands use [mise](https://mise.jdx.dev/) for tool management. Run `mise install` first.
CI, the release workflows and Codemagic install the same tools through mise
and run the same tasks. `mise.lock` pins each tool's exact download and
checksum for Linux and macOS arm64, and CI installs with `--locked`, so after
you change a version in `mise.toml` run
`mise lock --platform linux-x64,macos-arm64` and commit both files.

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
agents on an OpenAI-compatible host: Ollama Cloud by default, opencode-zen
with `LAUSCHI_MODEL_HOST=opencode`. Keys, all in `.env`
(loaded by mise): `SPOTIFY_CLIENT_ID`/`SPOTIFY_CLIENT_SECRET` for the provider
APIs (Apple Music uses the shared MusicKit key `android/app/AuthKey_*.p8`),
`OLLAMA_API_KEY` (or `OPENCODE_API_KEY`) for model calls, `BRAVE_API_KEY` for the agents' web search
tool, `REFERENCE_INDEX_SOURCE` (optional, the path of a file outside the repo
that reads the public reference index, see `lauschi_catalog.reference`) for the index behind the
agents' `lookup_reference_lines` tool and `lauschi-catalog reference <title>`
(a brand's lines and their numbered episodes; lags on new releases, so
absence there proves nothing).

Default models: `deepseek-v4-pro:0813` curates, `gemma4:31b` audits. The
4-eye principle requires two different model families. The phases default
to temperature 0 and seed 42, and each model's measured settings (DeepSeek
at low thinking effort, Gemma with thinking on and its vendor's sampling)
live in `_opencode.py` (`get_model_settings`). Two runs of a series can
still differ, since neither model repeats itself at those settings.

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
mise run catalog-add          # Add a new series (seed entry in series.json)
mise run catalog-discover     # Find + write missing artist IDs (all providers)
mise run catalog-curate       # AI-curate a single series
mise run catalog-curate-all   # AI-curate all series (skips existing, --force to redo)
mise run catalog-audit        # 4-eye audit (all, or pass a series id)
mise run catalog-apply        # Write approved curations into series.json
mise run catalog-splits       # Manage AI-proposed series splits
mise run catalog-validate     # Validate series.json against provider APIs (L1 + L5)
mise run catalog-drift        # Check shipped albums against live provider records
mise run catalog-qa           # Compare entries with the reference index (see "Reference index QA")
mise run catalog-report       # Show curation statistics (included/excluded/gaps)
mise run catalog-review       # List series needing human attention (escalated, flagged)
mise run catalog-edit         # Manual include/exclude on curations
mise run catalog-test         # Run the tools/ pytest suite
mise run catalog-evals        # Eval cases against the live model (see "Evaluating a change")
mise run catalog-web          # Catalog web UI (state browse, background jobs, review queue)
```

CLI subcommands without a mise task: `lint`, `reconcile`, `eval`, `delete`.

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
   artist's provider pages as include/exclude. The batch agent answers with
   its decision per album (include, a reason, its confidence, a note), and
   code adds title, release date and episode number from the provider
   record. Per series: provider discovery (artist IDs from series.json,
   search fallback), prefetch of album details, a metadata agent, batched
   album decisions (~30 per batch), a finalize agent (episode pattern, series
   facts). The metadata agent samples the whole artist page, so its prompt
   states what the catalog holds for the series: its id, the series it was
   split from, the other entries on the page, the titles it ships and its
   pattern. The entry's `episode_pattern` in series.json is the run's pattern;
   the agents propose one only where there is none and may extend a catalog
   pattern, not narrow it. Episode numbers come from the title pattern, the
   track names, or the same album on the other provider; nothing else. The
   steps that compare titles (duplicates, the same title on the other
   provider) strip the series' name from them first: the entry's title and
   its aliases in series.json, never the aliases a run proposes. Id, title
   and aliases of an entry are the catalog's: a run takes them from
   series.json, and the metadata agent's proposal counts only for a series
   the catalog does not hold.
   Re-curation is incremental: `--force` re-enters a series but
   carries prior decisions forward as a pre-seed the model may override, so
   a decided album is not re-asked. Albums the model does not decide stay
   absent from the curation; the run is then marked incomplete and apply
   skips it. A prior curation with invalid album records (e.g. an
   off-vocabulary exclude_reason) aborts the run; normalize first with
   `lauschi-catalog reconcile --all --normalize`.
   Split-off children (`split_from`) curate their own line and inherit
   nothing from the family. A child sees the whole shared page and decides
   each album on one question, is it this line. Only its own applied
   albums arrive included. An album that matches exactly one family
   member's `episode_pattern` is settled by that fact before the model
   runs. A claim needs the model's full confidence: an include below
   `high` goes to the root, and a title the child claims on one provider
   is claimed on the other too. The root then takes its children's claims
   from their current curations, so `curate --all` finishes every child
   before a root starts. What no child claims is the family root's: only
   the root's finalize proposes splits for it. The root's batch marks each
   album with the children that saw it and left it (`<left_by>`), so the
   root does not hand an album back to a child that passed on it. Children of a dissolved root
   (listed in `deleted.json`, e.g. `astrid_lindgren_deutsch`) stay one
   family, and their page's leftovers were settled at dissolution.
   On a page that several entries share, the batch instructions carry what
   the reference index holds for the brand: its lines with their titles and
   running times, and its products that sit in no line. Which line a title
   belongs to is then a fact in front of the model, not a lookup it may
   skip. It never supplies an episode number.
   A line without an entry is still left to that line, and finalize
   proposes the entry. What a main series ships of such a line stays
   included all the same, marked `decided_by: awaits_split`, until a
   person accepts the split: `catalog-splits` then moves it into the new
   entry as that entry's own. What the series does not ship yet waits for
   the split.
   Output: `assets/catalog/curation/{series_id}.json` (committed to git).

2. **Reconcile** (`reconcile`): Deterministic cross-provider consistency.
   A title included on one provider but excluded on the other under a
   whitelisted content reason (compilation, wrong_content_type, ...)
   auto-flips to include. Other reasons like `sub_series_bleed` stay as
   they are, and lint reports the pair. An exclusion a person made with
   `catalog-edit` stays as well. No AI.

3. **Audit** (`audit`): The second model reviews one curation: sub-series
   bleed, episode gaps, duplicates, pattern problems, split proposals.
   One-shot for small series, token-budgeted chunks for large ones. On a
   shared artist page it reviews only what the series owns: rows another
   family member owns are counted per owner, not listed, and an override
   on one is ignored. Writes the `review` block into the curation JSON:
   status `approved` or `escalated`, plus album overrides and fact
   updates. Escalates instead of approving when it declines approval, a
   regression flag fired, or its overrides flip more than 5% of the
   reviewed albums. Naming the reason of an album that is already
   excluded is not a flip. An album that awaits its split is not excluded
   as `sub_series_bleed`: the auditor is told why it is there, and such an
   override becomes a concern.
   Overrides are recorded, not applied: each one that would flip an album
   is a flag, and the series counts as flagged in `catalog-review` until a
   person decides those albums with `catalog-edit` (an approved series is
   still applied with the curator's decisions). Facts work the same way:
   a fact the audit restates as the curator wrote it is confirmed, and one
   it would add, change or remove is a `[fact_flag]` concern.
   `audit --apply-overrides` lets an approving audit flip the albums and
   write the facts itself.

4. **Lint** (`lint`): Deterministic findings over curations: episode gaps,
   duplicates, regressions against the previous curation, unaudited facts.
   Advisory; findings are reported, not enforced. It ends with the albums
   that every entry leaves to another line: no curation includes them, and
   every curation that lists them excludes them as `sub_series_bleed`. No
   single curation looks wrong there, so a person places each one (include,
   `catalog-edit move`, a new entry, or an exclusion for what it is).

5. **Apply** (`apply`): Writes approved curations into `series.json`: album
   IDs with episode numbers and barcodes, patterns, artist IDs, and audited
   series facts only. Title and aliases stay as they are, you edit them in
   the web UI. A pattern or content type edited there is saved in the
   curation as well, so apply does not write the older one back. An edit
   to series.json by hand needs the same change in the curation.
   Refuses curations that are incomplete, escalated, stale (curated
   after the last audit), or whose album loss crosses a guard threshold.
   `--force` overrides.

6. **Validate** (`validate`): Checks series.json against live provider APIs.
   L1 offline (structure, regex compiles, unique IDs, no pattern line that
   numbers another family member's titles and none of the entry's own) and
   L5 (artist discography match rate).

7. **Drift** (`drift`): Re-checks every shipped album against its live
   provider record and reports gone or changed albums. An id whose live
   barcode differs from the recorded one holds another release, and a gone
   id is looked up by its barcode, which names the id the store moved the
   release to. `--record-barcodes` writes the live barcode into curation
   records that have none, and apply then ships it.

Escalations, flags and lint findings are resolved by hand: `catalog-review` lists
what needs attention, `catalog-edit` and `catalog-splits` make the changes,
`mise run catalog-audit --force` re-checks afterwards. An album that sits in
the wrong entry of a family moves with
`catalog-edit move <from> <to> <provider>:<album_id>...`: the entry that
gives it up records the new owner, the entry that takes it numbers it by its
own pattern, and `apply` for both (the giving one first) writes series.json.

#### Reference index QA

`mise run catalog-qa` (all mapped entries, or `-- <id>...`) checks the
catalog against the reference index, one entry at a time, and changes
nothing: it writes `logs/catalog/qa-<time>.json` and prints a table.
`catalog/reference_map.py` gives each entry its index series (the one
named like its main series, also without punctuation or as the start of
its name, so "Dragons - Die Reiter von Berk" is the index's Dragons) and
lines (each to the entry that ships most of it, and a line nobody ships to
the main series), and pairs its shipped albums with those lines' episodes
by barcode, number, title and track names. The barcode pairs a release
whatever its titles say, and settles every story on it. What pairs with
nothing on either side goes to a model (`glm-5.3-flash` by default, `-m`
to change), in a run of its own per entry, which names every open item
`same_story`, `should_ship`, `rightly_absent`, `out_of_place` or
`unlisted`. Albums the index cannot know yet (numbered past its lines, out
in the last eight weeks) and albums a person placed with `catalog-edit`
are set aside before the model sees them.

Where the names differ, a member owns a line its titles do not show, or
the index has nothing for an entry, the override file says so (format in
the module's docstring). It names the index's own series ids, so it lives
outside the repo next to the source, and `REFERENCE_INDEX_MAP` in `.env`
holds its path.

#### Evaluating a change

Run the evals before and after you change a prompt, a model or the agent
code. There are two levels.

**Eval cases** (`mise run catalog-evals`, 30 to 60 minutes) answer "is this
change better?". A case is one batch of albums from a real artist page with
the decision every album must come out with. It runs through the production
batch agent, its prompt, its tools and the deterministic steps after a
batch, so it is scored on what would ship. The report counts three things
per case: the share decided right, wrong content (ships and should not) and
missing content (should ship and does not), plus the episode numbers a case
names. The model and its tools are called for real, and two runs of one
case can differ, so every case runs three times.

```bash
mise run catalog-evals -- --smoke                    # three quick cases once
mise run catalog-evals -- --cases rolf_zuckowski_own_albums --repeat 1 -v
mise run catalog-evals                               # all cases, compared with the baseline
mise run catalog-evals -- --save                     # keep this run as the baseline
```

To try another model, set `EVAL_MODEL`. Its run is still printed against
the baseline, which is the curator model's, and `--save` keeps it under
`tools/tests/evals/results/<model>.json` instead of over the baseline.
`--save-as NAME` keeps any run under a name, and `--compare` puts saved
runs side by side:

```bash
EVAL_MODEL=gemma4:31b mise run catalog-evals -- --save
mise run catalog-evals -- --save-as "round 2"
mise run catalog-evals -- --compare tests/evals/baseline.json tests/evals/results/kimi-k2.6.json
```

A saved run also holds what the model answered per album: the decision,
its reason, the confidence and the note. Search the saved runs for an album
id to see how each model and round read it, which is where a prompt change
starts. The model's thinking is only in the trace.

The cases are files in `tools/tests/evals/fixtures/`. Every expectation
names its source: the reference index where it lists the title, a hand decision
with its reason where it does not. To add one, run
`python -m tests.evals.build_case <series_id> --list` from `tools/` (with
`mise exec -- uv run --extra ai`), pick the albums, and replace each `todo`
the builder leaves with a decision you checked. A case states only what you
can back: leave an album out when neither the index nor another source
settles it. A hand decision the model has no fact for is not an
expectation either. A real run carries such an album as decided and never
asks about it, so the case keeps it among the decided rows.

**Whole-series eval** (`lauschi-catalog eval`) scores complete curate and
audit runs, produced in a scratch repo root (`LAUSCHI_REPO_ROOT=/tmp/...`),
against the committed curations and ground-truth verdicts. It takes hours
and measures against our own earlier output, so use it before a larger
change such as a new model, after the cases look good.

#### Tracing agent runs

With a Logfire credential in `.logfire/` (written by `logfire init`,
gitignored), the catalog commands send every agent run, model request and
tool call to that project as a span, labelled with the agent that made it
(`curate_metadata`, `curate_batch`, `curate_finalize`, `audit`). A span
carries the prompt, the response, token usage and the host's cache hits.
That content is catalog metadata from the provider pages, never user data.
Without a credential nothing is sent and nobody is asked to log in.

`lauschi_catalog.observability.configure_observability()` turns it on, and
the `lauschi-catalog` console script and the eval runner call it once. The credential is read
from the checkout, so a run against a scratch `LAUSCHI_REPO_ROOT` is traced
like any other. To keep prompts and responses out, pass
`include_content=False` to `logfire.instrument_pydantic_ai()` there. The
app itself reports to Sentry and sends nothing to Logfire.

## Architecture

### Core Stack
- **Flutter + Dart** (SDK ^3.7.0)
- **Riverpod** — state management (v3 with codegen via `@riverpod` annotations)
- **Drift** — local SQLite (tables in `lib/core/database/tables.dart`)
- **go_router** — navigation with redirect guards
- **Multi-provider audio**: ARD Sounds (free, just_audio), Spotify (WebView SDK), Apple Music (MusicKit JS WebView)

### Key Architectural Decisions

**Multi-Provider Architecture**: Three audio providers share a common interface:
- **ARD Sounds** (called ARD Audiothek until March 2026, still `ardAudiothek` in code and `ard_audiothek` in the database): Free, no auth. Direct HTTP streams via `StreamPlayer` (just_audio).
- **Spotify**: OAuth PKCE, WebView SDK bridge. `SpotifyPlayer` wraps `SpotifyWebViewBridge`.
- **Apple Music**: MusicKit JS in WebView (same pattern as Spotify). Auth via native MusicKit SDK, tokens injected into JS. Forked `music_kit` plugin (packages/music_kit) used for auth + catalog API only. JWT generated on-device from .p8 key. User needs Apple Music subscription.

Provider-agnostic catalog browse: `CatalogSource` interface implemented by
`SpotifyCatalogSource` and `AppleMusicCatalogSource`. One `BrowseCatalogScreen`
serves all providers.

**Catalog Matching by Album ID**: The app bundles `series.json` and builds an
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
│   ├── ard/                 # ARD Sounds API, models, helpers
│   ├── auth/                # PIN service
│   ├── catalog/             # series.json matching, CatalogSource interface
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
├── pyproject.toml           # click, pydantic-ai-slim, logfire, diskcache; extras: ai, web
├── src/lauschi_catalog/
│   ├── cli.py               # Click entry point
│   ├── catalog/             # Domain ops (curate_ops, audit_ops, apply_ops, lint_ops, ...),
│   │                        # models, catalog loader, matcher, staleness checks (lifecycle)
│   ├── commands/            # One thin Click command per file over the catalog/ ops
│   ├── providers/           # Spotify + Apple Music API clients (7-day diskcache)
│   ├── prompts/curate/      # SKILL.md + PHASE_*.md + references/, composed per phase/type
│   ├── eval/                # Curator/auditor eval harness (ground-truth scoring)
│   ├── web/                 # FastAPI review UI (routes, Jinja templates, background jobs)
│   ├── _opencode.py         # Model construction and per-model/per-phase settings
│   ├── observability.py     # Logfire tracing of agent runs, on when .logfire/ has a credential
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

`assets/catalog/series.json` is the DACH Hörspiel series catalog (~2.8 MB,
bundled into the app). The tools and the web UI write it through
`catalog.io.write_catalog`: two-space indent, and every dict or list of plain
values (an album, a list of aliases) on one line, so a changed album is a
one-line diff. Each entry has:
- `id`: stable snake_case identifier
- `title` + `aliases`: runtime series search and matching
- `episode_pattern`: regex (one capture group) extracting episode numbers
- `content_type`: `hoerspiel` (default), `music`, or `audiobook`
- `series_facts`: audited era boundaries, known episode gaps, sub-series
- `split_from`: marks a series split off from a parent entry
- `providers.spotify.albums` / `providers.apple_music.albums`: pre-validated
  album lists (provider IDs + episode numbers), written by the pipeline. An
  album's `barcode` (its UPC or EAN, from the provider record) names the
  release on both stores and in the reference index. The app ignores it.
- `providers.*.artist_ids`: artist IDs for discovery and fallback matching
- `providers.*.no_artist_page`: why a store has no artist page for the
  series, so discover does not search one

Alongside it: `assets/catalog/curation/{id}.json` (290 committed curation
files, the pipeline's per-series state), `deleted.json` (ids that must not be
re-added), `ard_featured_shows.json` (the ARD Sounds shows the app
features), `.cache/{provider}/` (7-day provider API cache, gitignored),
`logs/catalog/` (pipeline run logs, gitignored).

Validated by `lauschi-catalog validate` (tools/ package). Today: 290 series
(129 of them split-off children), 7,569 curated Spotify and 7,216 Apple Music
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
They also run `tool/strip_sentry.sh` first, so the Sentry SDK isn't in the
binary at all and a tracker scan such as Exodus finds nothing, and
`tool/check_no_sentry.sh` fails the build if it is. The script removes the
Sentry packages and switches `lib/core/telemetry/` to the backend that
collects nothing. Report errors and logs through `telemetry` (or `Log`),
never through Sentry directly: a test keeps every Sentry import inside
`sentry_telemetry.dart`, and CI analyzes the stripped app on every push.

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

## Commits (strict, no exceptions)

- **A red suite never gets committed.** Run the full suite for the area
  you touched before every commit: `mise run check` for the app,
  `mise run tools-check` for `tools/`. Zero failures means zero.
  "N passed, 1 environmental failure" is a red suite: fix the test or
  mark it `xfail(reason=...)` in the same commit. Never describe a red
  suite as green, in a commit message or anywhere else.
- **Commit messages are short.** Subject: imperative, under 72 chars.
  Body: only when the diff cannot speak for itself, and then a few
  lines on the why, nothing else. Never include test output, pass
  counts, tool logs, file lists, or internal ticket/plan codenames.
- **One concern per commit.** Reformatting is its own commit. Catalog
  data changes (`assets/catalog/`) are their own commit.
- **Never lose test output to a filter.** Don't pipe test runs through
  `grep`/`tail`/`head`; write the full output to a temp file and
  inspect that. Run targeted tests while developing, the full suite
  before committing.

## Python rules (tools/)

- Imports at the top of the module, after the docstring. A local
  import is allowed only to break a circular import or defer a heavy
  dependency, with a comment saying which.
- Type hints on every function. Test helpers and fixtures use real
  types (`Path`, not `object`).

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
mise run check                                              # Format + analyze + test + debug APK
mise run test-integration                                   # Patrol on-device tests
mise run test-integration integration_test/ard_playback_basic_test.dart  # Single integration test
```

CI installs Flutter and Java through mise and runs the same tasks
(`codegen`, `lint`, `test`), so a green `mise run check` should mean a
green CI. `mise run test` bundles the test files into one with
[Very Good CLI](https://cli.vgv.dev/), so the app compiles once instead of
once per file. All files share one isolate there, so a test that leaves a
timer or global state behind can break another file's tests.
`flutter test <file>` still runs a single file on its own. The task
activates very_good_cli globally on first use, since as a dev dependency
it would conflict with sentry_flutter's.

patrol_cli is a dev dependency, so `pubspec.lock` pins it next to the
patrol package it has to match (patrol 4.10 needs patrol_cli 4.7 or newer,
see Patrol's
[compatibility table](https://patrol.leancode.co/documentation/compatibility-table)).
The task runs it with `dart run patrol_cli:main`, so you don't need a
globally activated `patrol`, and it exits non-zero when a test fails.

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

Skills are declared in `agents.toml` and installed via dotagents. Since
dotagents 3 the default scope is global (`~/.agents/`), so pass `--project`
or the command edits your user config instead of this repo:

```bash
# Install all skills after cloning
npx @sentry/dotagents --project install

# List installed skills
npx @sentry/dotagents --project list

# Add a skill by name, since a whole repo pulls in skills that clash with ours
npx @sentry/dotagents --project add dart-lang/skills --name dart-use-pattern-matching
```

Remote skills (getsentry/*, dart-lang/skills, pbakaus/impeccable,
pydantic/skills) are gitignored and fetched on install, and so is
`agents.lock`, which dotagents now treats as generated. Local skills in
`.agents/skills/` (update-changelog, release, code-simplifier) are committed
to the repo. From the Dart and
Flutter skill sets only the ones that don't contradict our conventions are
declared: the widget-test, architecture, integration-test and mocks skills
teach `pumpAndSettle`, ChangeNotifier MVVM, Flutter Driver and mockito.

The catalog tooling's pydantic skills (`building-pydantic-ai-agents`,
`pydantic`, `logfire-evals`) come from `pydantic/skills`. That repo is a
plugin marketplace, so `add` would install whole plugins. `agents.toml`
names each skill with its `path` instead, and `install` follows upstream.
Read the skill before changing agent code: pydantic-ai moves quickly, and a
copy pinned elsewhere on your machine teaches the API of the release it was
installed for.

Sentry's skills and its hosted MCP server come as a plugin
(`[[plugins]]` in `agents.toml`, from `getsentry/agent-plugin`).
dotagents installs it under `.agents/plugins/` and writes the project
marketplace to `.claude-plugin/marketplace.json`. Claude Code doesn't
pick that up on its own, so register it once per machine:

```
/plugin marketplace add ./
/plugin install sentry@dotagents
```

The MCP server then logs you in to Sentry with OAuth on first use, so no
Sentry token lives in the repo.
