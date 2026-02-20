# Catalog curation guide

Step-by-step instructions for curating new and existing series.

## Adding a new series

### 1. Curate

Pick a series from the gap list (#96) and run AI curation:

```bash
mise run catalog-curate -- "PAW Patrol"
```

This searches Spotify, finds the artist, discovers all albums, and classifies
them as include/exclude. Takes 1-3 minutes. Output goes to
`assets/catalog/curation/{series_id}.json`.

For large series (200+ albums), bump the timeout:

```bash
mise run catalog-curate -- "Die drei ???" --timeout 600
```

### 2. Review

Run AI review on the new curation:

```bash
mise run catalog-review-ai -- paw_patrol
```

This checks for duplicates, episode gaps, and sub-series that should be split.
Uses Wikipedia + Spotify album details for verification.

### 3. Apply splits

Check if the review proposed any splits:

```bash
mise run catalog-apply-splits
```

If splits look good:

```bash
mise run catalog-apply-splits -- --apply
```

### 4. Approve in TUI

```bash
mise run catalog-review -- paw_patrol
```

In the TUI:
- Review the albums, AI decisions, and overrides
- `t` — toggle an album if you disagree
- `n` — add notes
- `a` — **approve** → writes to `series.yaml`
- `r` — reject (skip)
- `Tab` — next unreviewed series

### 5. Commit

```bash
git add assets/catalog/
git commit -m "feat: add PAW Patrol to catalog"
```

## Batch workflow (multiple new series)

### 1. Curate all

Run curation for each series. One at a time since each takes 1-3 minutes:

```bash
mise run catalog-curate -- "PAW Patrol"
mise run catalog-curate -- "Die drei !!!"
mise run catalog-curate -- "Gregs Tagebuch"
mise run catalog-curate -- "Die kleine Schnecke Monika Häuschen"
# ... etc
```

### 2. Review all at once

```bash
mise run catalog-review-ai -- --all
```

This skips already-reviewed series automatically. Only new curations get reviewed.

### 3. Apply all splits

```bash
mise run catalog-apply-splits              # dry-run
mise run catalog-apply-splits -- --apply   # write files
```

### 4. Approve in TUI

```bash
mise run catalog-review
```

Use `Tab` to jump through unreviewed series. Press `a` to approve each one.

### 5. Commit everything

```bash
git add assets/catalog/
git commit -m "feat: add N new series to catalog"
```

## Re-reviewing an existing series

If Spotify adds new episodes or you want a fresh look:

```bash
mise run catalog-curate -- "Sternenschweif" --timeout 600   # re-curate from scratch
mise run catalog-review-ai -- sternenschweif --force         # re-review (feeds previous decisions)
mise run catalog-apply-splits -- --apply                     # apply any new splits
mise run catalog-review -- sternenschweif                    # approve changes
```

## Quick edits without AI

For small fixes (exclude one album, add a missing episode):

```bash
# Find the album ID
mise run catalog-edit -- search "Asterix Folge 35"

# Add a missing album
mise run catalog-edit -- add asterix ALBUM_ID

# Exclude an album
mise run catalog-edit -- exclude asterix ALBUM_ID "standalone special, not episodic"

# Toggle include/exclude
mise run catalog-edit -- toggle asterix ALBUM_ID

# Check the result
mise run catalog-edit -- show asterix
```

## Validation

After approving, validate the catalog:

```bash
mise run catalog-check              # fast, cached
mise run catalog-check-fresh        # live Spotify API
```

## Priority series from gap analysis (#96)

### High priority (popular DACH kids series)
- Die drei !!!
- PAW Patrol
- Gregs Tagebuch
- Die kleine Schnecke Monika Häuschen
- Meine Freundin Conni
- Teufelskicker
- Käpt'n Sharky
- SimsalaGrimm
- Jan & Henry
- Michel (Astrid Lindgren)

### Medium priority
- LEGO Ninjago, LEGO City
- SpongeBob Schwammkopf
- Miraculous
- Die Schlümpfe
- Kira Kolumna
- Mein Lotta-Leben
- Petronella Apfelmus
- Woodwalkers
- Die Oktonauten

### Movie Hörspiele (Disney/DreamWorks)
- Die Eiskönigin
- Cars, Coco, Encanto
- Dragons (multiple variants)
- Star Wars

### Teen/YA (12+)
- John Sinclair
- Perry Rhodan
- Sherlock Holmes
- Karl May
- TKKG Retro-Archiv

### Kids music (zero coverage currently)
- Rolf Zuckowski
- Volker Rosin
- Detlev Jöcker
- Deine Freunde
- Lichterkinder
