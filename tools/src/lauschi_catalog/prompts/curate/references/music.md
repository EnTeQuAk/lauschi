# Music (music)

Kinderlieder and Kinderpop: an artist's albums, not an episodic series, so
there are no episode numbers and no `episode_pattern`.

## What belongs to the artist

Include every album of the artist's own songs for children: the studio
albums, the EPs, live recordings, the musicals and sung stories, and the
artist's own collections. Leave out what is not this artist's album: other
artists' compilations, singles, releases made only of other renditions of
songs that exist, content of another type, and albums not meant for
children.

## The artist's own collections

A collection of this artist's own songs is an album of theirs: a best-of
("Das Beste aus 20 Jahren"), a themed one ("Sommer mit ...",
"Einschlaflieder mit ...", "Bei uns in der Kita"), a numbered one ("Sing
mit mir Vol. 1"). **Include them.** A parent who looks for bedtime songs or
a summer album by this artist wants exactly these, and songs that are also
on another album harm nobody.

`album_type=compilation` on the artist's own page says how the store files
a release, not that it is unwanted.

Singles stay excluded (`music_single`): a single is one song, alone or with
versions of it, and the song is on the artist's albums. A release
of several different songs is a small album of the artist's, whatever
a store or an index calls it: include it. A release made only of versions of one
song (instrumental, karaoke, remix) is `format_variant`. When you leave an
album out, name its reason, never `unspecified`.

## Failure taxonomy

### multi_artist_compilation
Albums of several artists ("Kinderparty Hits", "Nick Jr.'s …"). Exclude
(`multi_artist_compilation`).

### format_variant
A release made only of other renditions of songs the artist has released:
karaoke, instrumental, playback, sped-up, nightcore, remixes. Exclude
(`format_variant`). An album whose songs come with their playback versions
added is still the album, include it.

### wrong_content_type
Hörspiel or Hörbuch in a music artist's catalog. Exclude
(`wrong_content_type`), and flag it for a
series split if there are many. A musical or a sung story of the artist's
is not one: the songs carry it, and a narrator who links them does not make
it a Hörspiel. It is the artist's music, include it.

### not_kids_content
Some children's artists also make records for grown-ups: singer-songwriter
albums, a retrospective of their adult work. Those are not for this
catalog. Song titles about adult life hint at it, and the artist's or the
label's own description settles it. When the songs read like they are for
adults, look that description up before you decide. Exclude what it calls
an album for adults (`not_kids_content`).

## Worked examples

Given artist "Rolf Zuckowski" (content_type: music):

**Regular album** (include):
```
Title: "Rolfs neue Vogelhochzeit"
Tracks: 14 songs, each 2-4 min
Reasoning:
  1. The artist's own songs for children
  2. No exclusion reason applies
→ include=true, confidence=high
```

**The artist's own best-of** (include):
```
Title: "Der Spielmann - Das Beste aus 20 Jahren"
Tracks: 32 songs, album_type=compilation
Reasoning:
  1. A collection, and the store files it as one
  2. Every song is his own, sung by him, for children
  3. A collection of the artist's own songs is an album of theirs
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
  1. Songs of several artists, a year-stamped collection
→ include=false, exclude_reason=multi_artist_compilation, confidence=high
```

**Karaoke / instrumental variant** (exclude):
```
Title: "Rolfs Vogelhochzeit (Karaoke Version)"
Tracks: 14 instrumental versions
Reasoning:
  1. The same songs without vocals, labelled as such
→ include=false, exclude_reason=format_variant, confidence=high
```

**A musical or sung story of the artist's** (include):
```
Title: "Der Schneemann im Sommer - Ein Liederspiel"
Tracks: 24 tracks, 14 songs with short narrator passages between them, 45 min
Reasoning:
  1. The artist's own songs carry the story, a narrator links them
  2. A parent who looks for this artist's music expects the musicals too
→ include=true, confidence=high
```

**Hörspiel in a music artist's catalog** (exclude):
```
Title: "Kalle und die Mühle - Das Hörspiel"
Tracks: 18 scenes played by a cast, two songs, 55 min
Reasoning:
  1. Actors play the story in scenes, the songs are interludes
  2. The title calls it a Hörspiel
→ include=false, exclude_reason=wrong_content_type, confidence=high
  notes: "Hörspiel in music artist catalog"
```

**An album for adults** (exclude):
```
Title: "Zwischen den Jahren"
Tracks: 12 songs about work, love and growing older
Reasoning:
  1. The song titles read like songs for grown-ups
  2. A web search finds the label's page, which files it under its albums
     for adults
→ include=false, exclude_reason=not_kids_content, confidence=high
  notes: "Label describes it as an album for adults"
```

## Pattern and facts

- `episode_pattern=None` always: an artist's career, not an episodic series.
- No `era_boundaries`: an artist's career is continuous, and a change of
  style is not a catalog era.
- `sub_series` is rare. Where the artist really makes songs and Hörspiele,
  flag the Hörspiele for a split instead.
