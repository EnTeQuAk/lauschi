# Music (music)

Kinderlieder, Kinderpop, and music albums. No episode numbers, no
`episode_pattern`. Artist career, not episodic series.

## Decision procedure

| Title shape | Track count | Likely type | Action |
|---|---|---|---|
| Album of songs by this artist | 8-20 | ALBUM | Include |
| EP of this artist's own songs (`album_type=ep`) | 4-8 | EP | Include |
| This artist's own collection: best-of, themed, seasonal | Variable | ALBUM | Include |
| Multi-artist compilation ("Kinderhits 2024") | Variable | COMPILATION | Exclude |
| Karaoke, instrumental, sped-up | Variable | FORMAT_VARIANT | Exclude |
| Hörspiel in music artist catalog | Variable | WRONG_TYPE | Exclude (`wrong_content_type`) |

## The artist's own collections

A collection of this artist's own songs is an album of theirs: a best-of
("Das Beste aus 20 Jahren"), a themed one ("Sommer mit ...",
"Einschlaflieder mit ...", "Bei uns in der Kita"), a numbered one ("Sing
mit mir Vol. 1"). **Include them.** A parent who looks for bedtime songs
or a summer album by this artist wants exactly these, and songs that are
also on another album harm nobody.

`album_type=compilation` on the artist's own page says how the store
files a release, not that it is unwanted. What is left out is what is
not this artist's album at all: other artists' compilations, singles,
format variants, content of another type, and albums that are not for
children.

Singles stay excluded (`music_single`): a single is one song, alone or
with versions of it, and the song is on the artist's albums. A release
of several different songs is a small album of the artist's, whatever
a store or an index calls it: include it. A release made only of
versions of one song (instrumental, karaoke, remix) is
`format_variant`. When you leave an album out, name its reason, never
`unspecified`.

## Failure taxonomy

### multi_artist_compilation
Albums featuring other artists ("Kinderparty Hits", "Nick Jr.'s …").
Exclude.

### format_variant
Karaoke, instrumental, sped-up, nightcore. Exclude.

### wrong_content_type
Hörspiel or Hörbuch in a music artist's catalog. Exclude, flag for series
split if substantial.

## Worked examples

Given artist "Rolf Zuckowski" (content_type: music):

**Regular album** (include):
```
Title: "Rolfs neue Vogelhochzeit"
Tracks: 14 songs, each 2-4 min
Artist: Rolf Zuckowski
Reasoning:
  1. Single artist, original songs, standard album length
  2. No failure-taxonomy pattern applies
  3. Track count (14) and durations (2-4 min each) match typical Kinderlieder album
→ include=true, confidence=high
```

**The artist's own best-of** (include):
```
Title: "Der Spielmann - Das Beste aus 20 Jahren"
Tracks: 32 songs, album_type=compilation
Artist: Rolf Zuckowski
Reasoning:
  1. A collection, and the store files it as one
  2. Every song is his own, sung by him, for children
  3. No failure-taxonomy pattern applies: a collection of the artist's
     own songs is an album of theirs
→ include=true, confidence=high
```

**The artist's own themed collection** (include):
```
Title: "Einschlaflieder mit Rolf Zuckowski"
Tracks: 18 songs, album_type=compilation
Reasoning:
  1. His own songs regrouped by a theme, bedtime
  2. A parent looking for bedtime songs by him wants this album
→ include=true, confidence=high
```

**Multi-artist compilation** (exclude):
```
Title: "Kinderhits 2024 - Die besten Kinderlieder"
Tracks: 22 songs by various artists
Reasoning:
  1. Title contains year-stamped collection pattern ("Kinderhits 2024")
  2. Multiple artists, not a single-artist release
  3. Named failure pattern: multi_artist_compilation
→ include=false, exclude_reason=multi_artist_compilation, confidence=high
```

**Karaoke / instrumental variant** (exclude):
```
Title: "Rolfs Vogelhochzeit (Karaoke Version)"
Tracks: 14 instrumental versions
Reasoning:
  1. "(Karaoke Version)" explicitly labels this as a format variant
  2. Same track listing as the original but without vocals
  3. Named failure pattern: format_variant
→ include=false, exclude_reason=format_variant, confidence=high
```

**Hörspiel in a music artist's catalog** (exclude):
```
Title: "Rolf Zuckowski erzählt: Der kleine Tag"
Tracks: 22 tracks, mixed spoken word and songs, 58 min total
Reasoning:
  1. "erzählt" (narrates) signals dramatic reading, not music album
  2. Mixed spoken word + songs with long total duration = Hörspiel structure
  3. Named failure pattern: wrong_content_type (Hörspiel in music catalog)
  4. If this artist has many Hörspiel releases, flag for series split
→ include=false, exclude_reason=wrong_content_type, confidence=high
  notes: "Hörspiel/narrative album in music artist catalog"
```

**Borderline, can't name a failure pattern** (default to include):
```
Title: "Rolf Zuckowski und seine Freunde: Live in Concert"
Tracks: 18 songs, 72 min
Reasoning:
  1. Live recording of existing songs, but still original artist performing
  2. Can I name a failure pattern? "Live" isn't in the taxonomy.
     It's not a compilation (single artist), not a format variant (still vocals),
     not wrong content type.
  3. Inclusion bias: can't name a failure pattern, so include.
→ include=true, confidence=medium
  notes: "Live concert recording; not in failure taxonomy, including per inclusion bias"
```

## Pattern and facts

- `episode_pattern=None` always (artist career, not episode series).
- No `era_boundaries` (artist careers are continuous; stylistic shifts aren't
  catalog eras).
- `sub_series` rarely used (e.g., "Liederalbum" vs "Hörspiel" if the artist
  genuinely does both, flag for split instead).

