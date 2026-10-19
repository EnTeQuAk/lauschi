<p align="center">
  <img src="assets/images/branding/lauschi-logo.png" alt="lauschi" width="200">
  <p align="center">A calm audio player for kids. No algorithm, no rabbit holes.</p>
</p>

# What's lauschi?

lauschi wraps audio providers behind a curated, card-based interface
for children. Parents build visual content cards; kid taps a card,
audio starts. No recommendations, no autoplay, no screen time spiral.

Currently supports **ARD Sounds** (formerly ARD Audiothek, free, no
account needed), **Spotify** and **Apple Music**. Built with Flutter. DACH-market focus (Hörspiele, Kindermusik),
internationalizable. All data stays on-device.

## Status

MVP functional on Android and iOS. Grouping, catalog matching,
NFC tag support, parent/kid modes working. Catalog curation
pipeline covers ~120 DACH Hörspiel and music series.

## Setup

Requires [mise](https://mise.jdx.dev/) for tool management.

```bash
git clone git@github.com:EnTeQuAk/lauschi.git
cd lauschi
mise install                    # Flutter, Java 17, gh, uv
cp .env.example .env            # developer keys for scripts
cp .env.app.example .env.app    # app build config
mise run setup                  # flutter pub get + codegen
mise run dev                    # run on connected device
```

### Environment

Two env files (both gitignored):

- **`.env`** — Developer keys for tooling. Loaded by mise. Not passed to Flutter.
- **`.env.app`** — App build config. Passed to Flutter via `--dart-define-from-file`.

`.env.app`:
```
ENABLE_SPOTIFY=false            # feature flag
SPOTIFY_CLIENT_ID=...           # required when Spotify enabled
SENTRY_DSN=...                  # optional, error tracking
SENTRY_ENVIRONMENT=development
```

**ARD Sounds** works out of the box with no credentials, no account. Free
public broadcaster content. The app uses the ARD Sounds GraphQL API
(still at `api.ardaudiothek.de`, the service's name until March 2026) to browse and stream children's audio content directly.

**Spotify** requires a client ID (PKCE flow, no client secret). Create a
Spotify app at https://developer.spotify.com/dashboard, add
`lauschi://callback` as a redirect URI, and copy the client ID.

For catalog curation tools (optional, not needed to build/run the app):

```
OPENCODE_API_KEY=...            # for AI curation scripts
BRAVE_API_KEY=...               # for catalog review web search
```

## Architecture

- **Flutter + Dart**: iOS and Android from one codebase
- **Riverpod 3**: state management
- **Drift**: local SQLite with schema migrations
- **Spotify Web Playback SDK**: Spotify audio via hidden WebView (EME/DRM).
  The SDK's `player.html` is hosted externally (requires HTTPS origin for
  Widevine). See `lib/core/spotify/spotify_config.dart` for the URL.
- **ARD Sounds GraphQL API** + **just_audio**: free streaming of public
  broadcaster content (no account required)
- **go_router**: navigation with parent PIN gate
- **very_good_analysis**: strict linting
- **Sentry**: crash reporting + session replay (EU region)
- **AI-assisted catalog curation**: pydantic-ai agents in `tools/`, one
  model curates and a second model of another family audits. A person
  settles what they disagree on.

## Catalog curation

The catalog is a developer-side build product. AI models help sort through
thousands of store albums, no AI runs in the app itself, and no AI-generated
content is shown to kids. A second model audits every curation, and a person
settles what the two disagree on.

The app ships `assets/catalog/series.json`: every series with its titles,
episode pattern, artist ids and the curated albums per store (id, episode
number, title, release date, barcode). It is written by the `lauschi-catalog`
CLI and its web UI from the per-series curation state in
`assets/catalog/curation/*.json`, so you change it through those tools rather
than by hand.

```bash
mise run catalog-add -- "PAW Patrol"          # seed a new series
mise run catalog-pipeline-one -- paw_patrol   # curate, audit, apply, validate
mise run catalog-review                       # what needs a person
mise run catalog-web                          # the web UI
```

AGENTS.md ("Catalog Tools") describes every stage, the commands and how to
evaluate a change to the curator.

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
flutter test test/core/catalog/catalog_service_test.dart --dart-define-from-file=.env.app

# Run with coverage
flutter test --coverage --dart-define-from-file=.env.app
```

Tests don't require a device and run on the Dart VM. Integration tests
(Patrol) require a connected device or emulator.

### iOS

iOS builds require macOS with Xcode. The project uses Codemagic for CI/CD on
iOS. Local iOS development works with `flutter run` on a Mac with Xcode
installed and an iOS 14.0+ device/simulator.

## Contributing

1. Fork the repo and create a branch from `main`
2. `mise install && mise run setup`
3. Make your changes, run `mise run check` to verify
4. Open a PR. CI runs format, analyze, test, and debug build.

Keep commits focused and messages in imperative mood ("Fix bug" not "Fixed
bug"). See the project's `analysis_options.yaml` for lint rules.

## License

Copyright © 2025-2026 Christopher Grebs. Licensed under [GPL-3.0](LICENSE).
