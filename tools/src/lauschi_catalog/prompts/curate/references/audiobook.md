# Audiobook (Hörbuch)

Printed books turned into audio. Usually single narrator, minimal sound
design. One entry per book; no `episode_pattern`.

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

## Pattern and facts

- `episode_pattern=None` always. Books are standalone; chapter/Teil numbers
  within a single album aren't episodes.
- `series_facts` rarely populated. If a long author career has distinct
  production phases (early readings vs later inszenierte Lesungen, different
  narrators for different decades), `sub_series` can group them, but
  `era_boundaries` typically don't apply (eras imply numbered episodic content).
