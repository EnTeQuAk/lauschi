# lauschi

A kids audio player for Spotify and Apple Music. Parents curate content as visual cards; kids tap a card and audio starts. No algorithm, no recommendations, no rabbit holes.

Built with Flutter. DACH-market focus initially, internationalizable.

## Status

Early development (MVP in progress). Not usable yet.

## Setup

Requires [mise](https://mise.jdx.dev/) for tool management.

```bash
mise install          # Flutter 3.41.1, gh, Java 17
flutter pub get
mise run setup        # download native SDKs + generate Drift/Riverpod code
flutter run           # requires a connected device or simulator
```

`mise run setup` is idempotent — safe to re-run. It downloads the Spotify App Remote
AAR (Android, ~270k, gitignored binary) and runs `build_runner`.

## Architecture

- **Flutter + Dart** — iOS and Android from one codebase
- **Riverpod** — state management
- **Drift** — local SQLite
- **Spotify App Remote SDK** — native IPC to the Spotify app (no DRM/WebView needed)
- **go_router** — navigation

See [docs/architecture.md](docs/architecture.md) for details (TODO).

## License

MIT
