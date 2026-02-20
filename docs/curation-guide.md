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

## Full gap list from tiini/startemich.de (#96)

Source: [startemich.de](https://startemich.de/) — 166 Hörspiele + 38 Musik.
Our catalog matches 43 of 166 Hörspiele (26%). Zero music coverage.

### Hörspiele — kids series (3-10)

- [ ] PAW Patrol
- [ ] Jan & Henry
- [ ] Die Oktonauten
- [ ] Käpt'n Sharky
- [ ] Max
- [ ] Eule
- [ ] Die kleine Schnecke Monika Häuschen
- [ ] SimsalaGrimm
- [ ] Lieselotte Filmhörspiele
- [ ] Meine Freundin Conni
- [ ] Kikaninchen
- [ ] Willi wills wissen
- [ ] Der kleine Hui Buh
- [ ] Jan & Henry

### Hörspiele — kids/tween (6-12)

- [ ] Die drei !!!
- [ ] Gregs Tagebuch
- [ ] Teufelskicker
- [ ] LEGO Ninjago
- [ ] LEGO City
- [ ] SpongeBob Schwammkopf
- [ ] Miraculous
- [ ] Die Schlümpfe
- [ ] Mein Lotta-Leben
- [ ] Kira Kolumna
- [ ] Die Punkies
- [ ] Schlau wie Vier
- [ ] Petronella Apfelmus
- [ ] Woodwalkers
- [ ] Sternenfohlen
- [ ] Die Feriendetektive
- [ ] Kati & Azuro
- [ ] Die wilden Kerle
- [ ] H2O - Plötzlich Meerjungfrau!
- [ ] Mia and Me
- [ ] Miss Melody
- [ ] Michel
- [ ] Hedda Hex
- [ ] 5 Geschwister
- [ ] Die Originale
- [ ] Die Punkies
- [ ] Conni (Meine Freundin Conni — check overlap with existing Conni)

### Hörspiele — teen/YA (12+)

- [ ] John Sinclair
- [ ] Perry Rhodan
- [ ] Gruselkabinett
- [ ] Gruselserie
- [ ] Sherlock Holmes
- [ ] Sherlock Holmes Chronicles
- [ ] Sherlock Holmes & Co
- [ ] Sherlock Holmes - Die geheimen Fälle des Meisterdetektivs
- [ ] Holmes & Watson
- [ ] Karl May
- [ ] Edgar Wallace
- [ ] Jan Tenner
- [ ] TKKG Retro-Archiv
- [ ] Insel-Krimi
- [ ] Pater Brown
- [ ] Professor van Dusen
- [ ] Margaret Rutherford

### Hörspiele — movie/franchise tie-ins

- [ ] Die Eiskönigin
- [ ] Cars
- [ ] Coco
- [ ] Encanto
- [ ] Alles steht Kopf
- [ ] Bambi
- [ ] Peter Pan
- [ ] Pets
- [ ] Shrek
- [ ] Sing
- [ ] Spirit
- [ ] Madagascar
- [ ] Kung Fu Panda
- [ ] Boss Baby
- [ ] Der Gestiefelte Kater
- [ ] Angry Birds
- [ ] 100% Wolf
- [ ] Kim Possible
- [ ] Polly Pocket
- [ ] Trolljäger
- [ ] Dinotrux
- [ ] In einem Land vor unserer Zeit
- [ ] Star Wars
- [ ] Pirates of the Caribbean
- [ ] Jurassic World
- [ ] Jurassic World - Neue Abenteuer
- [ ] Dragons - Auf zu neuen Ufern
- [ ] Dragons - Die Reiter von Berk
- [ ] Dragons - Die Wächter von Berk
- [ ] Dragons - Die jungen Drachenretter
- [ ] Drachenzähmen leicht gemacht
- [ ] Fünf Freunde - Endlich erwachsen

### Hörspiele — author-based (may overlap with existing series)

- [ ] Jeff Kinney (→ Gregs Tagebuch)
- [ ] Cornelia Funke
- [ ] Ingo Siegner (→ Kleiner Drache Kokosnuss — rejected, revisit?)
- [ ] Sabine Städing (→ Petronella Apfelmus)
- [ ] Tanya Stewner (→ Liliane Susewind)
- [ ] Alice Pantermüller (→ Lotta-Leben)
- [ ] Julia Donaldson (→ Grüffelo)
- [ ] Erhard Dietl (→ Die Olchis ✓)
- [ ] Nele Moost (→ Rabe Socke ✓)
- [ ] Klaus Baumgart (→ Lauras Stern ✓)
- [ ] Markus Osterwalder (→ Bobo Siebenschläfer ✓)
- [ ] Otfried Preußler (→ Räuber Hotzenplotz ✓)
- [ ] Linda Chapman (→ Sternenschweif ✓)
- [ ] Astrid Lindgren Deutsch
- [ ] Sabine Bohlmann
- [ ] Robert Missler
- [ ] Martin Baltscheit
- [ ] Martina Sahler
- [ ] Heiko Wolz

### Hörspiele — adult audiobooks (tiini includes for parents)

- [ ] Dieter Nuhr
- [ ] Heinz Strunk
- [ ] Tommy Jaud
- [ ] Torsten Sträter
- [ ] Ken Follett
- [ ] Rebecca Gablé
- [ ] Kerstin Gier
- [ ] Bora Dagtekin
- [ ] Andreas Eschbach
- [ ] Markus Heitz
- [ ] Suzanne Collins
- [ ] Kai Meyer

### Hörspiele — narrator-based

- [ ] Rufus Beck
- [ ] Andreas Fröhlich
- [ ] Oliver Rohrbeck
- [ ] Charly Hübner
- [ ] Florian Lamp
- [ ] Julian Horeyseck
- [ ] Stefan Naas
- [ ] Stephen Janetzko
- [ ] Robin Brosch

### Musik (38 artists — all new, zero current coverage)

- [ ] Rolf Zuckowski
- [ ] Volker Rosin
- [ ] Detlev Jöcker
- [ ] Fredrik Vahle
- [ ] Deine Freunde
- [ ] Lichterkinder
- [ ] Heavysaurus
- [ ] Hurra Kinderlieder
- [ ] Simone Sommerland
- [ ] DIKKA
- [ ] Giraffenaffen
- [ ] Sing Kinderlieder
- [ ] Bummelkasten
- [ ] Kikaninchen
- [ ] Karsten Glück
- [ ] Die Kita-Frösche
- [ ] LiederTiger
- [ ] Kinderlieder-Superstar
- [ ] KinderliederTV
- [ ] Piano Papa
- [ ] Kinderlieder Gang
- [ ] Schnabi Schnabel
- [ ] Jonina
- [ ] 3Berlin
- [ ] Mama Sandy
- [ ] Kalle Klang
- [ ] Die Flohtöne
- [ ] TiRiLi Kinderlieder
- [ ] Der singende Bauernhof
- [ ] EMMALU
- [ ] Kati Breuer
- [ ] Liederkiste
- [ ] Familie Sonntag
- [ ] Aprilkind
- [ ] Libatiba
- [ ] Louis H.
- [ ] Manuel Straube
- [ ] Christian
