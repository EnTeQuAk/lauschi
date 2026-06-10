# Music (music)

Kinderlieder, Kinderpop, and music albums. No episode numbers, no
`episode_pattern`. Artist career, not episodic series.

## Decision procedure

| Title shape | Track count | Likely type | Action |
|---|---|---|---|
| Album of songs by this artist | 8-20 | ALBUM | Include |
| "Best of", "Greatest Hits" | Variable | COMPILATION | Exclude |
| Multi-artist compilation ("Kinderhits 2024") | Variable | COMPILATION | Exclude |
| Karaoke, instrumental, sped-up | Variable | FORMAT_VARIANT | Exclude |
| Hörspiel in music artist catalog | Variable | WRONG_TYPE | Exclude (`wrong_content_type`) |

## Singles-first artists

Some Kinderlieder artists release almost everything as singles and only
package them into their own collection albums ("Sing mit mir Vol. 1",
"Die schönsten Kinderlieder Vol. 2", "Kinderklassiker Vol. 1"). For
these artists the collection albums ARE the catalog — **include them**.
The compilation exclusions below exist to avoid redundancy with regular
albums; when an artist has no regular albums, that rationale doesn't
apply.

How to recognize the case: the discography is dominated by 1-2 track
singles, and the only multi-track releases are the artist's own themed
collections. The `album_type` field helps: the artist's own primary
releases carry `album_type=album` even when their titles sound like
compilations (e.g. Simone Sommerland's "Die 30 besten …" series — those
are her primary studio albums, include them).

Singles stay excluded either way (`music_single`): one-track albums make
poor listening units, and their songs are on the collection albums.

## Failure taxonomy

### kinderlieder_compilation
"Best of", "Greatest Hits", numbered albums where each is a compilation.
Exclude — UNLESS the artist is singles-first and these collections are
their only multi-track releases (see "Singles-first artists" above), or
`album_type=album` marks them as the artist's primary releases.

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
→ include=true, episode_num=null, confidence=high
```

**Best-of compilation** (exclude):
```
Title: "Rolf Zuckowski - Die schönsten Lieder"
Tracks: 28 songs, mixed durations
Reasoning:
  1. "Die schönsten Lieder" (the best songs) signals greatest hits compilation
  2. High track count (28) further confirms compilation
  3. Named failure pattern: kinderlieder_compilation
→ include=false, exclude_reason=kinderlieder_compilation, confidence=high
```

**Singles-first artist's own collection** (include):
```
Title: "Sing mit mir Vol. 1"
Tracks: 22 songs, each 1-3 min
Artist catalog: 71 singles, 6 "Sing mit mir" collections, no regular albums
Reasoning:
  1. Title sounds like a compilation, but the artist has no regular albums
  2. These collections are the artist's only multi-track releases —
     excluding them leaves the series empty
  3. Singles-first rule: the collection albums ARE the catalog
→ include=true, episode_num=null, confidence=high
  notes: "Artist-own collection; singles-first artist, no regular albums"
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
→ include=true, episode_num=null, confidence=medium
  notes: "Live concert recording; not in failure taxonomy, including per inclusion bias"
```

## Pattern and facts

- `episode_pattern=None` always (artist career, not episode series).
- No `era_boundaries` (artist careers are continuous; stylistic shifts aren't
  catalog eras).
- `sub_series` rarely used (e.g., "Liederalbum" vs "Hörspiel" if the artist
  genuinely does both — flag for split instead).

## Metadata phase note

For music artists, there are no tools available in the metadata phase.
Do NOT call `check_pattern_coverage` or any other tools — they are not
registered for music metadata. Just set up the metadata directly.
