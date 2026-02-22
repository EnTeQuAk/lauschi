<p align="center">
  <img src="assets/images/branding/lauschi-logo.png" alt="lauschi" width="200">
  <p align="center">A calm audio player for kids. No algorithm, no rabbit holes.</p>
</p>

# What's lauschi?

lauschi wraps Spotify (Apple Music planned) behind a curated,
card-based interface for children. Parents build visual content
cards — kid taps a card, audio starts. No recommendations, no
autoplay, no screen time spiral.

Built with Flutter. DACH-market focus (Hörspiele, Kindermusik),
internationalizable. All data stays on-device.

## Status

MVP functional on Android and iOS. Grouping, catalog matching,
NFC tag support, parent/kid modes working. Catalog curation
pipeline covers 125 DACH Hörspiel and music series.

## Setup

Requires [mise](https://mise.jdx.dev/) for tool management.

```bash
git clone git@github.com:EnTeQuAk/lauschi.git
cd lauschi
mise install                    # Flutter, Java 17, gh, uv
cp .env.example .env            # add Spotify credentials
mise run setup                  # flutter pub get + codegen
mise run dev                    # run on connected device
```

### Environment

Configuration lives in `.env` (gitignored), loaded by mise tasks via
`--dart-define-from-file=.env`:

```
SPOTIFY_CLIENT_ID=...           # required — Spotify Developer Dashboard
SENTRY_DSN=...                  # optional — error tracking
SENTRY_ENVIRONMENT=development
```

The Spotify client ID is public (PKCE flow, no client secret). Create a
Spotify app at https://developer.spotify.com/dashboard, add `lauschi://callback`
as a redirect URI, and copy the client ID.

For catalog curation tools (optional, not needed to build/run the app):

```
OPENCODE_API_KEY=...            # for AI curation scripts
BRAVE_API_KEY=...               # for catalog review web search
```

## Architecture

- **Flutter + Dart** — iOS and Android from one codebase
- **Riverpod 3** — state management
- **Drift** — local SQLite with schema migrations
- **Spotify Web Playback SDK** — audio via hidden WebView (EME/DRM).
  The SDK's `player.html` is hosted externally (requires HTTPS origin for
  Widevine). See `lib/core/spotify/spotify_config.dart` for the URL.
- **go_router** — navigation with parent PIN gate
- **very_good_analysis** — strict linting
- **Sentry** — crash reporting + session replay (EU region)

## Catalog curation

The catalog is lauschi's core product. It ships as curated YAML in `assets/catalog/series.yaml`, backed by per-series curation data in `assets/catalog/curation/*.json`.

### Pipeline overview

```
series.yaml          ← defines series (keywords, patterns, artist IDs)
        │
        ▼
catalog-curate       ← AI discovers + classifies albums from Spotify
        │
        ▼
curation/*.json      ← per-series: albums, include/exclude decisions, age notes
        │
        ▼
catalog-review-ai    ← AI reviews: excludes junk, proposes splits, fills gaps
        │
        ▼
catalog-apply-splits ← executes split proposals into new curation JSONs
        │
        ▼
catalog-review (TUI) ← human approves/rejects → writes back to series.yaml
```

### Adding new series

1. Add the series entry to `assets/catalog/series.yaml`:
   ```yaml
   - id: paw_patrol
     title: PAW Patrol
     keywords: ["PAW Patrol"]
     spotify_artist_ids: ["..."]
     episode_pattern: "Folge (\\d+)"
   ```

2. Run AI curation to discover albums:
   ```bash
   mise run catalog-curate -- --series "PAW Patrol"
   ```
   This creates `assets/catalog/curation/paw_patrol.json` with all albums classified as include/exclude.

3. Run AI review:
   ```bash
   mise run catalog-review-ai -- paw_patrol
   ```
   Reviews the curation: excludes duplicates/compilations, proposes splits for sub-series, fills episode gaps. Uses Wikipedia + Spotify album details for verification.

4. Apply any splits:
   ```bash
   mise run catalog-apply-splits              # dry-run
   mise run catalog-apply-splits -- --apply   # create new JSONs
   ```

5. Human review in TUI:
   ```bash
   mise run catalog-review                    # all series
   mise run catalog-review -- paw_patrol      # specific series
   ```
   - Browse series, see AI decisions with overrides applied
   - `t` — toggle an album's include/exclude
   - `n` — add reviewer notes
   - `a` — approve → writes to `series.yaml`
   - `r` — reject
   - `Tab` — next unreviewed series

### Reviewing existing series

AI review is incremental — it skips already-reviewed series:

```bash
mise run catalog-review-ai -- --all           # only reviews new/unreviewed
mise run catalog-review-ai -- --all --force   # re-review everything
mise run catalog-review-ai -- asterix --force # re-review one series
```

On `--force`, previous review decisions are fed to the AI so it builds on prior work.

### How splits work

When the AI review finds albums that belong in a separate series (different era, sub-series, spinoff), it proposes a split:

- **Sub-series**: Wieso? Weshalb? Warum? → JUNIOR, PROFIWISSEN, ERSTLESER, Vorlesegeschichten
- **Production eras**: Löwenzahn → CLASSICS (Peter Lustig) vs modern (Fritz Fuchs)
- **Spinoffs**: Die wilden Hühner → Die Wilden Küken
- **Format variants**: Sternenschweif Hörspiel → Sternenschweif Klassik (audiobook)

Splits are proposals in the JSON until `apply-splits` executes them. Each split creates a new curation JSON with the albums moved over, and adds exclude overrides to the parent.

### Non-destructive edits

All manual and AI review edits go to `review.overrides` in the curation JSON — the original AI curation in `series.albums` is never mutated. This means:

- Re-running curation produces a fresh base; overrides are preserved
- Every decision has an audit trail
- The JSON is git-diffable

CLI for quick edits:
```bash
mise run catalog-edit -- show asterix
mise run catalog-edit -- exclude asterix ALBUM_ID "standalone special"
mise run catalog-edit -- toggle asterix ALBUM_ID
mise run catalog-edit -- add asterix ALBUM_ID
mise run catalog-edit -- search "Asterix Folge 35"
```

### Validation

```bash
mise run catalog-check          # cached validation against series.yaml
mise run catalog-check-fresh    # live Spotify API validation
mise run catalog-audit          # full L5 discography audit
```

### Available mise tasks

| Task | Description |
|------|-------------|
| `catalog-curate` | AI-curate a series (pydantic-ai + kimi-k2.5) |
| `catalog-review-ai` | AI review with three-way decisions |
| `catalog-apply-splits` | Execute split proposals |
| `catalog-review` | Human review TUI |
| `catalog-edit` | CLI for quick edits |
| `catalog-report` | Report gaps/dupes across all series |
| `catalog-check` | Validate series.yaml (cached) |
| `catalog-check-fresh` | Validate series.yaml (live API) |
| `catalog-audit` | Full discography audit |
| `catalog-discover` | Search for new artist candidates |
| `catalog-titles` | Discover new series titles |

## Development

```bash
mise run dev                    # flutter run with .env
mise run test                   # flutter test
mise run analyze                # flutter analyze
mise run setup                  # pub get + codegen
mise run check                  # format + analyze + test (CI equivalent)
```

### Building for Android

Prerequisites:
- Android SDK (install via `mise install` or Android Studio)
- Java 17 (installed by mise)
- A connected Android device or emulator with API 24+

```bash
# Debug APK
mise run build                  # builds APK with codegen + .env

# Install on connected device
flutter install --debug

# Or run directly
mise run dev
```

The debug APK lands in `build/app/outputs/flutter-apk/app-debug.apk`.

For release builds, you'll need a signing key configured in
`android/app/build.gradle`. See the
[Flutter Android deployment docs](https://docs.flutter.dev/deployment/android).

### Testing on Android

```bash
# Run all tests
mise run test

# Run a single test file
flutter test test/core/catalog/catalog_service_test.dart --dart-define-from-file=.env

# Run with coverage
flutter test --coverage --dart-define-from-file=.env
```

Tests don't require a device — they run on the Dart VM. Integration tests
(Patrol) require a connected device or emulator.

### iOS

iOS builds require macOS with Xcode. The project uses Codemagic for CI/CD on
iOS. Local iOS development works with `flutter run` on a Mac with Xcode
installed and an iOS 14.0+ device/simulator.

## Contributing

1. Fork the repo and create a branch from `main`
2. `mise install && mise run setup`
3. Make your changes, run `mise run check` to verify
4. Open a PR — CI runs format, analyze, test, and debug build

Keep commits focused and messages in imperative mood ("Fix bug" not "Fixed
bug"). See the project's `analysis_options.yaml` for lint rules.

## License

Copyright © 2025-2026 Christopher Grebs. Licensed under [GPL-3.0](LICENSE).
