# lauschi

A kids audio player for Spotify and Apple Music. Parents curate content as visual cards; kids tap a card and audio starts. No algorithm, no recommendations, no rabbit holes.

Built with Flutter. DACH-market focus initially, internationalizable.

## Status

Early development (MVP in progress). Not usable yet.

## Setup

Requires [mise](https://mise.jdx.dev/) for tool management.

```bash
mise install        # installs Flutter 3.41.1, gh, Java 17
flutter pub get
flutter run         # requires a connected device or simulator
```

## Architecture

- **Flutter + Dart** — iOS and Android from one codebase
- **Riverpod** — state management
- **Drift** — local SQLite
- **Spotify Web Playback SDK** — audio via hidden WebView (no Spotify app required)
- **go_router** — navigation

See [docs/architecture.md](docs/architecture.md) for details (TODO).

## License

MIT
