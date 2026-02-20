# lauschi

A kids audio player for Spotify (Apple Music planned). Parents curate content as visual cards; kids tap a card and audio starts. No algorithm, no recommendations, no rabbit holes.

Built with Flutter. DACH-market focus initially (Hörspiele, Kindermusik), internationalizable.

**Privacy-first**: all data local, no cloud, no analytics beyond opt-in Sentry crash reporting.

## Status

MVP functional on Android. Grouping, catalog matching, parent/kid modes working. Catalog curation pipeline covers 50+ DACH Hörspiel series with 2400+ curated albums.

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

Secrets live in `.env` (gitignored), loaded by mise:

```
SPOTIFY_CLIENT_ID=...
SPOTIFY_CLIENT_SECRET=...
SENTRY_DSN=...                  # optional
OPENCODE_API_KEY=...            # for AI curation tools
BRAVE_API_KEY=...               # for catalog review web search
```

## Architecture

- **Flutter + Dart** — iOS and Android from one codebase
- **Riverpod 3** — state management
- **Drift** — local SQLite with schema migrations
- **Spotify Web Playback SDK** — audio via hidden WebView (EME/DRM)
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
```

## License

MIT
