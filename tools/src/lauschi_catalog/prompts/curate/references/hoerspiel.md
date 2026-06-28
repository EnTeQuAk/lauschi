# Hörspiel (hoerspiel)

The default content type. Dramatized radio plays with multiple voice actors,
sound effects, and music scores. Usually episodic with numbered episodes.

## What makes something a Hörspiel episode

A Hörspiel episode is a single self-contained story produced for audio. The
production signals that distinguish it from other content in the same catalog:

- **Multiple voice actors** playing characters (not one narrator reading)
- **Sound design**: foley, ambient sound, music score woven through the story
- **Episode-length duration**: typically 30-70 minutes for one story
- **Track structure**: on Spotify, 20-40 tracks (scenes/chapters within one
  episode). On Apple Music, 1-5 tracks (often one per CD side or a single file).
  Both are the same content, different packaging.

When you see an album in a Hörspiel discography, ask: "Is this one produced
story with a cast?" If yes, include it. The failure taxonomy below covers the
cases where the answer is no.

## Title naming conventions

DACH Hörspiel publishers use a few dominant title formats. Recognizing these
helps you assign episode numbers and spot content that doesn't belong:

| Format | Example | Prevalence |
|---|---|---|
| `Folge NNN: Title` | `Folge 1: als Wetterelefant` | ~48% of catalog |
| `NNN/Title` | `013/Der verlorene Besen` | ~7% (older physical releases) |
| `NNN: Title` (no Folge prefix) | `04: Leben der Ritter` | ~6% |
| `Teil NNN` | `Teil 1: Malicias Rache` | ~1% |
| Named, no number | `Aladin und die Wunderlampe` | ~33% (TV tie-ins, standalone) |

Long-running series (Benjamin Blümchen 1977-2026, Die drei ??? 1979-2026)
typically keep the same format across decades. Pumuckl is the notable
exception: two production eras on one artist page, distinguished by
parenthetical suffix (`(Das Original aus dem Fernsehen)` vs
`(Neue Geschichten vom Pumuckl)`), both using `NNN:` format.

When a series uses multiple formats, the metadata phase sets up a list of
patterns. Each pattern captures one naming convention. "Multiple formats"
is normal, not an error.

## Failure taxonomy

### sub_series_bleed

The most structurally complex failure. A single artist account hosts
multiple distinct products. Each is a valid Hörspiel, but they belong in
separate series.yaml entries.

How to recognize: albums share the artist but have a distinct title prefix,
theme, or numbering that runs independently from the main series.

| Main series | Sub-series (exclude) | Signal |
|---|---|---|
| Benjamin Blümchen | Gute-Nacht-Geschichten, Benjamin Minis | Distinct prefix, own numbering |
| Die drei ??? | Die drei ??? Kids, Mini-Fall | Different target age, own episodes |
| Die drei ??? Kids | Mini-Fall, Mini-Fälle | Short format, own numbering |
| Pumuckl | Meister Eder und sein Pumuckl (Hörspiel) | Different production, own catalog |
| Bibi Blocksberg | Bibi & Tina (if under same artist) | Different cast, own universe |

**Pattern-match trap:** some sub-series titles start with "Folge N:" which
matches the main series' episode_pattern. A pattern match does NOT override
a sub-series brand. Look at what follows the episode number: if it contains
a distinct product name ("Mini-Fall", "Sonderband", "Kurzkrimis"), the
album belongs to that sub-series regardless of the pattern match. Confirming
signals: the brand also appears in track names ("Mini-Fall: Die Räuberjagd,
Teil 1"), and/or the extracted episode number collides with an existing
main-series episode.

When you exclude for sub_series_bleed, note which sub-series it belongs to.
The finalize phase uses your notes to propose `sub_series` facts with
`album_ids`, so downstream tools can split them into their own entries.

### compilation_as_episode

Albums that bundle multiple episodes into one release. They look like
episodes (same artist, same title style) but contain 2+ stories.

Title signals for compilations:
- Range in title: "Folge 1-10", "Folgen 1-3"
- Multiple story titles joined by `/` or `&`: "Der sechste Sinn / Vertrauen"
- Explicit markers: "Bundle", "Box", "Sammelbox", "Kollektion", "Jubiläumsbox"
- Anniversary/milestone: "30 Jahre", "Jubiläum", "Best of"
- Seasonal grouping: "Weihnachtsfolgen", "Sommerfolgen", "Osterbundle"
- Very high track count (>50 tracks suggests multiple episodes bundled)

Exclude with reason `compilation`.

### music_single

The most common exclusion (37% of all excludes). Music tracks uploaded as
albums in a Hörspiel artist's catalog.

Signals: `album_type=single`, title ends with ` - Single`, 1-2 tracks,
duration under 5 minutes, no episode marker in title. Often theme songs,
character songs, or promotional tracks.

Exclude with reason `music_single`.

### wrong_content_type

Content that belongs to a different content type entirely:

- **Hörbuch in Hörspiel catalog**: sometimes labeled in the title ("Lesung",
  "ungekürzt", "gelesen von"), but often not. When the title doesn't help,
  use track structure: 20+ sequentially numbered "Teil" or "Kapitel" tracks
  at 2-5 min each, forming one continuous story over 90+ minutes total.
  Hörspiel tracks have descriptive scene names ("Spuk in der Werkstatt,
  Teil 1"); audiobook chapters are just numbered ("Teil 01", "Teil 02", ...
  "Teil 40"). If every track is named "Teil NN" with no scene or episode
  title, it's a reading, not a production. Exclude as `wrong_content_type`.
- **Soundtrack/score**: "Original Motion Picture Soundtrack", instrumental
- **ASMR/ambient**: "Klangreise", "ASMR" in title. Soundscapes, not stories.
- **Educational non-narrative**: "Englisch lernen mit...", language courses

Exclude with reason `wrong_content_type`.

### format_variant

Same content re-released in a different format. Not additional value for
the listener.

Signals: "Karaoke", "Instrumental", "Sped-Up", "Nightcore" in title.
Also "Playback" or version markers that indicate a non-standard rendition.

Exclude with reason `format_variant`.

### kinderlieder_compilation

Music albums branded under a Hörspiel character. They look like they
belong to the series (same artist, character name in title) but contain
songs, not stories.

Signals: title suggests songs ("tanzt!", "Kinderparty", "Die schönsten
Lieder", "Liederalbum"), track durations are 2-4 minutes each (song-length,
not scene-length), no episode number.

Exclude with reason `kinderlieder_compilation` or `wrong_content_type`.

## Cross-provider pairs

The same episode on Spotify and Apple Music is the same content with
different catalog metadata:

| Field | Typical Spotify | Typical Apple Music |
|---|---|---|
| Title | `Folge 1: als Wetterelefant` | `Klassiker, Folge 1: Maja lernt fliegen` |
| Tracks | 20-40 (scene-per-track) | 1-5 (one per CD side) |
| Release date | Re-release date (often recent) | May reflect original release |

Both are correct entries. Include both. Different track counts between
providers is the norm, not a reason to question the decision.

Worked example (Biene Maja episode 1):
- Spotify: "01/Majas Geburt" (1977, 26 tracks)
- Apple Music: "Klassiker, Folge 1: Maja lernt fliegen" (1976, 3 tracks)
Same content, different catalog entry, different title format. Include both.

## Era collision

Same episode number, same provider, release dates 5+ years apart. This
happens when a series was re-released, re-recorded, or rebooted.

Include both versions. Write "era collision" in your `notes` field so the
finalize phase can propose an `era_boundary` fact grouping the old and new
production runs.

## Using album_type

Spotify provides `album_type` (album, single, compilation). This is a
provider-assigned label, not always accurate, but a useful signal:

- `album_type=single` + 1-2 tracks + short duration → strong `music_single` signal
- `album_type=compilation` → check the title. Publisher-repackaged
  compilations are excludable. But some artist-own collections carry this
  label incorrectly.
- `album_type=album` → the default for regular episodes. Necessary but
  not sufficient for inclusion.

Apple Music doesn't provide album_type. Use title and track structure.

## Pattern and facts

- `episode_pattern` matches album titles, not track names. The metadata
  phase sets this up and the batch phase applies it.
- `era_boundaries` group episodes into production eras (e.g., classic
  vs revival). Based on release-date clusters and title convention changes.
- `known_gaps` record missing episode numbers with reasons (legal dispute,
  publisher change, number skipped). Propose as a known_gap only when the
  episode is truly missing from the discography, not just excluded.
- `sub_series` tag albums that belong to a spin-off. Always include
  `album_ids` so downstream tools know which albums to split.
