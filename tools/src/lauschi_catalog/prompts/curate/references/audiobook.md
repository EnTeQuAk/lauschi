# Audiobook (Hörbuch)

Printed books turned into audio. Usually single narrator, minimal sound
design. One entry per book; no `episode_pattern`.

## Metadata phase note

There are no tools available in the metadata phase for audiobook curation.
Do NOT call `check_pattern_coverage` or any other tools — they are not
registered for audiobook metadata. Just set up the metadata directly.

## Hörbuch vs Hörspiel

This is the most error-prone classification for non-DACH models. Same novel
can have both productions:

| Signal | Hörbuch (this class) | Hörspiel (`wrong_content_type` here) |
|---|---|---|
| Production style | Read aloud from the book | Acted out with cast |
| Voices | One narrator (occasionally two for dialogue) | Multiple voice actors playing characters |
| Sound design | Minimal — maybe intro/outro music | Foley, effects, music score, ambient sound |
| Source | A printed book, read more or less as written | Original script, or script adapted from a book |
| Title hints | "ungekürzt", "Lesung", "gelesen von [name]", "vollständige Lesung" | "Folge N:", "Hörspiel zum Film", "Original-Hörspiel", "Hörspielfassung" |
| Track shape | Many tracks (one per chapter) on Spotify; few long tracks (one per CD/cassette) on Apple Music | Few tracks (one per episode) on both providers |
| Per-album duration | 3-12 hours (whole book) | 30-70 minutes (one episode) |
| Credits | "Sprecher: …" (one name) | "Mit: …" (multiple names) |

## Failure taxonomy

### ungekuerzt_reading
Full-book reading by single narrator, split into chapter tracks. Include if
kids' book.

### gekuerzt_reading
Abridged single-narrator reading. Include only if no `ungekuerzt` version of
the same title exists in the same artist's catalog.

### inszenierte_lesung
Small-cast dramatized reading of one source book (1-3 voices, light music,
still anchored to reading the text). Include — this is still a Hörbuch.

Worked example: "Jim Knopf und Lukas der Lokomotivführer — Hörspiel
nach der Romanvorlage" (Spotify, 8 tracks, ~75 min). Title says "Hörspiel"
but the track count is low and duration is short-ish. However, the credit
lists "Sprecher: …" (one narrator) with occasional guest voices — this is
an inszenierte Lesung, not a full Hörspiel cast. **Include** as Hörbuch.

### hoerspiel_adaptation
Multi-voice dramatized production with sound design, even if based on the
artist's novel. **Exclude** (`wrong_content_type`). Flag for splitting into a
separate `hoerspiel`-typed series.yaml entry.

### music_in_audiobook_catalog
Music album in an audiobook artist's catalog. Exclude (`wrong_content_type`).

### non_kids_work
Adult/non-kids works by the same author. Exclude (out of scope for Lauschi).

### compilation_set
Multi-book box (e.g., "Sammelband: 5 Romane in einer Lesung"). Exclude.

### excerpt_or_sample
Leseprobe, sample chapter, promotional excerpt. Exclude.

## Positive confidence signals (Hörbuch)

When the title is bare and the artist is a known children's author, use
track count and duration as the primary signal:

- Many tracks on Spotify (30–150, one per chapter) = Hörbuch, **HIGH confidence**
- 3–12 hours total duration on Apple Music (few long tracks per CD/cassette)
  = Hörbuch, **HIGH confidence**
- Few tracks (<10) and 30–70 min total = likely Hörspiel, **LOW confidence**
  for audiobook — prefer exclude with `wrong_content_type` unless the title
  explicitly says "ungekürzt" or "Lesung"

## Title decoder — worked examples (Michael Ende)

Use the title as your primary signal. Track count confirms.

| Title fragment | Type | Action |
|---|---|---|
| "… - Die ungekürzte Lesung" | Hörbuch (full reading) | **Include** |
| "… - Die Lesung" | Hörbuch (reading) | **Include** |
| "… (116 tracks)" / "… (106 tracks)" / "… (108 tracks)" | Hörbuch (chapter-per-chapter) | **Include** |
| "… - Das Hörspiel" | Hörspiel (dramatized) | **Exclude** (`wrong_content_type`) |
| "… - Kinderoper" | Hörspiel (musical adaptation) | **Exclude** (`wrong_content_type`) |
| "… - Das Hörspiel zum Film" / "… - Das Hörspiel zum Kinofilm" | Hörspiel (movie tie-in) | **Exclude** (`wrong_content_type`) |
| "Englisch lernen mit …" | Educational, not narrative | **Exclude** (`wrong_content_type` or `non_kids_work`) |
| "Let's Have Fun!" / "Verdi: Messa da Requiem" | Not by Michael Ende | **Exclude** (`non_kids_work` or `wrong_content_type`) |
| Multi-book box: "… und weitere Geschichten" with 2+ titles | Compilation | **Exclude** (`compilation_set`) |

When you see the same source novel in both forms (e.g. "Momo" as Hörbuch AND "Momo - Das Hörspiel"), the one WITHOUT "Hörspiel" / "Kinderoper" / "zum Film" is the Hörbuch — **include it**. The one WITH those suffixes is the Hörspiel — **exclude it**.

## Pattern and facts

- `episode_pattern=None` always. Books are standalone; chapter/Teil numbers
  within a single album aren't episodes.
- `series_facts` rarely populated. If a long author career has distinct
  production phases (early readings vs later inszenierte Lesungen, different
  narrators for different decades), `sub_series` can group them, but
  `era_boundaries` typically don't apply (eras imply numbered episodic content).
