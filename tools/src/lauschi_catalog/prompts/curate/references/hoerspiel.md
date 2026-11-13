# Hörspiel (hoerspiel)

The default content type: stories played by a cast, with sound effects and
music, usually in numbered episodes.

## What a Hörspiel episode is

One produced story with a cast: several voice actors play the characters,
sound design and music carry the scenes. It can be a seven-minute TV story
or a feature-length film, so length alone decides nothing. Spotify usually
splits an episode into many scene tracks, Apple Music into a few long
ones, which is the same content packaged differently.

When you see an album in a Hörspiel discography, ask: "Is this one produced
story with a cast?" If yes, include it. The failure taxonomy below covers
the cases where the answer is no.

Publishers number their titles in a few ways: `Folge 1: als Wetterelefant`,
`013/Der verlorene Besen`, `04: Leben der Ritter`, `Teil 1: Malicias Rache`,
and many titles carry no number at all (TV tie-ins, standalone stories). A
series can change its format over the decades, and then its pattern lists
one regex per format. Pumuckl keeps two production eras apart by a suffix
(`(Das Original aus dem Fernsehen)` against `(Neue Geschichten vom
Pumuckl)`).

## Failure taxonomy

### sub_series_bleed

One artist page often hosts several products. Each is a valid Hörspiel,
and each belongs in its own catalog entry: albums that share the artist but
carry a title prefix, a theme or a numbering of their own.

| Main series | Sub-series (exclude) | Signal |
|---|---|---|
| Benjamin Blümchen | Gute-Nacht-Geschichten, Benjamin Minis | Distinct prefix, own numbering |
| Die drei ??? | Die drei ??? Kids, Mini-Fall | Different target age, own episodes |
| Die drei ??? Kids | Mini-Fall, Mini-Fälle | Short format, own numbering |
| Pumuckl | Meister Eder und sein Pumuckl (Hörspiel) | Different production, own catalog |
| Bibi Blocksberg | Bibi & Tina (if under same artist) | Different cast, own universe |

**Pattern-match trap:** some sub-series titles start with "Folge N:" and
match the main series' pattern. A pattern match does not outweigh a
sub-series brand. Look at what follows the number: a product name
("Mini-Fall", "Sonderband", "Kurzkrimis") makes the album that line's,
whatever the pattern says. The brand in the track names ("Mini-Fall: Die
Räuberjagd, Teil 1") or a number that collides with a main episode
confirms it.

The batch prompt lists the sibling entries the catalog has on this page,
and an album of one of them is theirs. A line that has no entry yet counts
too. Note which line the album belongs to: finalize turns those notes into
a split proposal.

### compilation_as_episode

A repackaging re-sells episodes that already exist as their own releases:
TKKG "3er Box", "Folge 1-10: Jubiläumsbox", "Best of", "Die schönsten
Weihnachtsfolgen". The listener gains nothing new, and a box between Folge
12 and Folge 13 breaks the sequence a child scrolls through.

An album whose title names a run of episodes carries
`<episode_range first="…" last="…" also_released_alone="…"/>`, worked out
from the whole store page, which no single batch shows you. It answers the
question:

- Every episode of the run is listed in `also_released_alone`: the album
  re-sells them, exclude it as `compilation`.
- `also_released_alone="none"`: the album is the only release of those
  episodes on this store. Feuerwehrmann Sam 1 to 132 exist only as "Folgen
  1-5", "Folgen 6-10" and so on. That is the episode release: include it,
  numbered with its first episode, the way "Folge 1+2" double episodes are.
- Only some are listed: the album overlaps releases that exist, and
  including it would put two albums under one number. Exclude it as
  `compilation` and name the episodes only it carries in the notes, so a
  human can decide.

Without `<episode_range>`, a range, a plus or an "und" in the number
position ("Folge 1-10", "Folgen 3 & 4", "1+2") is the usual tell, and so
are "Box", "Sammelbox", "Kollektion", "Jubiläum", "Best of" and seasonal
bundles ("Weihnachtsfolgen", "Osterbundle"). A very high track count proves
nothing on its own, since some publishers chapter a single episode into
dozens of tracks.

**Two stories in one release is not a repackaging.** Many series ship one
release with two or three short stories or topics under one number, a slash
between the titles: Was Ist Was ("Roboter & Androiden / Supercomputer"),
Miraculous, Mia and Me, Conni ("Folge 5: Schatzjagd im Museum / Magische
Meisterschaft"), and the TV tie-ins where one Folge holds three
seven-minute stories. That is the series' standard format: one release, one
episode number, include it. One story told across two releases ("Folge 100:
Ottos neue Freundin - Teil 1" / "Teil 2") is the same: two releases, one
story, both included.

**One episode released in parts, and then complete.** A publisher sometimes
puts one episode out piece by piece ("Folge 100: Der magische Ring -
Episode 1" to "Episode 9", a week apart, twenty minutes each) and then as
one album with the whole story ("Folge 100: Der magische Ring", 168
minutes). The complete album is the episode: include it. It is not a box,
because its parts are not episodes of their own: they share its number,
and none of them is a whole story. The parts are `partial_release`. Where
the store has no complete album, the parts are the only way to hear the
story and stay in, like "Teil 1" and "Teil 2" above.

The question to ask: does this release re-sell episodes that exist on their
own? Then it is a `compilation`. Does it hold stories that only exist
together, under one number? Then it is an episode.

### music_single

A song uploaded as its own release in a Hörspiel artist's catalog: a theme
song, a character song, a promotional track. `album_type=single`, a title
ending in " - Single", one or two tracks of a few minutes, no episode
marker. Exclude (`music_single`).

### wrong_content_type

Content of another type entirely:

- **A Hörbuch in a Hörspiel catalog.** The title often says so ("Lesung",
  "ungekürzt", "gelesen von"), but not always. Without a title marker, a
  long row of tracks named only "Teil NN" or "Kapitel NN", one continuous
  story over hours, points to a reading. Hörspiel tracks carry scene names.

  Track structure is a hint, never proof. Publishers (JUMBO, Atmende
  Bücher) chapter genuine Hörspiele as "Kapitel N" and slice them into
  tracks of equal length, and retailers put "gelesen von" on full-cast
  productions. Both have caused wrong exclusions of real Hörspiele (Wickie,
  the Drachenreiter film, Vulkan-Mission, the Wilden Hühner films). A
  Filmhörspiel that weaves the film's voices with narrator passages IS a
  Hörspiel, even with one narrator credited. Before you exclude anything
  titled "Hörspiel" as `wrong_content_type`, check the production on the
  publisher's or a review page (web search), not in track names or store
  credits. Where an album's notes record an operator's check, that is
  settled unless you find stronger new evidence.
- **Soundtrack or score**: "Original Motion Picture Soundtrack", film music.
- **ASMR or ambient**: "Klangreise", "ASMR". Soundscapes, not stories.
- **Learning material without a story**: "Englisch lernen mit...",
  language courses.

Exclude (`wrong_content_type`).

### format_variant

The same production released again in another rendition or mix. The
listener gets a story they already have.

Signals: "Karaoke", "Instrumental", "Sped-Up", "Nightcore" in title. Also
"Playback" or version markers that indicate a non-standard rendition. A new
recording with a new cast is not a variant but another production (see
"Era collision").

Exclude (`format_variant`).

### kinderlieder_compilation

Song albums under a Hörspiel character's brand. They look like the series
(same artist, the character in the title) but hold songs, not stories:
"tanzt!", "Kinderparty", "Die schönsten Lieder", "Liederalbum", tracks of
song length, no episode number. Exclude (`kinderlieder_compilation`).

## Cross-provider pairs

The same episode on both stores often has different titles, track counts
and release dates. Both are correct entries: include both, a cross_provider_pair.

Biene Maja episode 1:
- Spotify: "01/Majas Geburt" (1977, 26 tracks)
- Apple Music: "Klassiker, Folge 1: Maja lernt fliegen" (1976, 3 tracks)

Same content, two stores, two title formats. Include both.

## Era collision

Same episode number on the same store, from two productions: an old
recording and a re-recording or reboot with a new cast. Include both, and
write "era collision" in `notes` so finalize can propose an `era_boundary`
fact that groups the two production runs.

## Using album_type

Both stores provide `album_type` (album, single, ep, compilation): Spotify
from its API, Apple Music from its flags and its " - EP" title suffix.
Measured against the reviewed catalog (2,556 albums, 2026-09): of the 46
albums Spotify flags `compilation`, 44 are excluded by us.
It is a strong signal.

- `album_type=single` with one or two short tracks: a strong
  `music_single` signal.
- `album_type=compilation`: almost always a publisher repackaging or a
  "Best of", exclude as `compilation`. The exception is a music
  artist's own song collection (Rolf Zuckowski's "Das große Abenteuer
  Musik" is the only such case in the catalog), a regular album of theirs.
- `album_type=album`: the default for regular episodes, necessary but not
  sufficient.
- `album_type=ep`: a short release, and no signal on its own: Apple Music
  labels many regular episodes " - EP". Judge it by title and tracks.

## Pattern and facts

- `episode_pattern` matches album titles, not track names. The metadata
  phase sets it up, and code applies it.
- `era_boundaries` group episodes into production eras (classic against
  revival), from release-date clusters and changes in title convention.
- `known_gaps` record missing episode numbers with their reasons (a legal
  dispute, a publisher change, a skipped number). Propose one only when the
  episode is truly missing from the discography, not just excluded.
- `sub_series` tag albums that belong to a spin-off. Always include
  `album_ids` so downstream tools know which albums to split.
