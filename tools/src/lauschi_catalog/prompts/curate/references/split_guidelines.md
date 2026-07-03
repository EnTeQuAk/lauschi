# Sub-series split guidelines

When to propose a `sub_series` fact during finalize, and when to leave
content in the parent series.

## Context: how parents discover content

Parents browse the catalog by series name ("Pippi Langstrumpf", "TKKG",
"Lego Ninjago"), then pick albums within that series. Each series in the
catalog maps to one or more provider artist IDs. A sub_series proposal
creates a new top-level series that parents can find by name.

"Artist" on Spotify/Apple Music doesn't always mean a person. In the
DACH Hörspiel market, each series/character/brand is its own artist
entry. "Pippi Langstrumpf" is an artist, same as "Lego Ninjago" is.
Author umbrella entries ("Astrid Lindgren Deutsch", "Michael Ende")
are catch-alls for works that don't have their own dedicated provider
artist.

## When to propose a split

### 1. Distinct product lines targeting different age brackets

"Kids", "Junior", "Next Generation" variants target a fundamentally
different audience. A parent of a 6-year-old searching for "TKKG Junior"
does not want the main series (10+) mixed in. Always propose a split.

Examples: "Die drei ??? Kids", "TKKG Junior", "Fünf Freunde Junior",
"5 Geschwister Junior".

Evidence: title prefix/suffix that systematically differs from the main
episode pattern, marketed to a different age group.

### 2. Film adaptations with distinct branding

Hörspiele based on theatrical films ("Kinofilm", "Das Hörspiel zum Film")
disrupt numbered episode browsing when mixed into the parent. A parent
scrolling through "Folge 87, Folge 88, 90-min Kinofilm, Folge 89" is
confused.

Propose a split when the films:
- Have explicit sub-branding ("Kinofilm", distinct cover art series)
- Are structurally different (60-90 min vs 30-50 min episodes)
- Would break chronological/numbered browsing in the parent

Keep with parent when the "films" are just elongated TV episodes
without distinct branding (same cover art style, same duration range).

Examples to split: "Bibi und Tina Kinofilm" (4 theatrical releases),
"Die drei ??? Kinofilm", "Ostwind" film Hörspiele.

### 3. Music content in a Hörspiel series

Character brands (Bibi, Benjamin, Conni) often have music discographies
alongside their Hörspiel episodes. Music albums ("Die schönsten Lieder",
"Hexen-Hits") are a completely different listening experience. Kids
tapping a Hörspiel series expect stories, not songs.

Propose a split for music/vocal albums under a Hörspiel artist.
Use content_type "music" for the split.

### 4. Recognizable standalone works from author umbrellas

Author umbrella entries ("Astrid Lindgren Deutsch", "Michael Ende")
collect works that don't have their own provider artist. When a work
within the umbrella is recognizable enough that a parent would search
for it by name, propose a split.

The test: would a German parent type this title into a search box?

Split: "Ronja Räubertochter", "Mio, mein Mio", "Momo",
"Die unendliche Geschichte", "Krabat", "Das fliegende Klassenzimmer".
These are standalone literary properties with their own cover art
traditions and cultural presence.

Keep: obscure short stories, single picture-book adaptations, works
only known as part of a collection. If you have to debate whether it's
recognizable, it probably isn't.

There is no minimum album count for this category. A 2-album "Ronja
Räubertochter" is a clear split. Recognizability, not volume, is the
criterion.

### 5. Hörbuch vs Hörspiel of the same title

When both a dramatized Hörspiel (full cast, Europa-style) and a narrated
Hörbuch (single speaker, "gelesen von") exist under the same artist,
they are different listening experiences. Propose a split if there are
multiple Hörbuch titles. A single Hörbuch should be excluded with
`wrong_content_type` instead.

## When NOT to split

### Adventskalender

Annual Advent calendar releases ("Die drei ??? Adventskalender 2021",
"2022", "2023") are one format, not separate series. Either keep them
in the parent or propose ONE sub_series "adventskalender" that groups
all years. Never create per-year entries.

### Doppelfolgen and Sammelbände

Compilation re-packagings ("Folge 1+2", "3er Box") are not distinct
works. They should be excluded with `compilation`, not split off.
Do not count them when assessing whether enough content exists for
a split.

### Sonderfolgen and specials

Individual special episodes ("Sonderfolge: Das Geheimnis der
Geisterinsel") belong in the parent. They are one-off releases,
not a product line. Include them with `episode_num=null`.

### Reissues and new recordings

A new cast recording of the same series ("Pippi Langstrumpf, Die neue
Hörspielserie") stays with the parent unless it has completely separate
branding and its own distinct provider artist. Era boundaries, not
splits, handle recording generations.

## The golden rule

Never split in a way that turns the parent into a graveyard. The
numbered episodic run is the brand. Films, music, Adventskalender,
and specials are satellite content. After a split, the parent must
still contain the core content that defines the series.

## Worked examples

**Clear split** (age-bracket product line):
```
Series: "Die drei ???"
Albums found: 200+ main episodes, 15 albums titled "Die drei ??? Kids ..."
Reasoning:
  1. "Kids" is a distinct product line for ages 6-8 (main series is 10+)
  2. Titles systematically differ: "Die drei ??? Kids" prefix
  3. Parents explicitly search for the "Kids" line
  4. 15 albums is substantial
→ Propose sub_series: label="kids", album_ids=[...all Kids albums],
  reason="Separate age-bracket product line (6-8 vs 10+)"
```

**Clear split** (film adaptations):
```
Series: "Bibi und Tina"
Albums found: 100+ numbered episodes, 4 albums with "Kinofilm" in title
Reasoning:
  1. 4 theatrical film Hörspiele with "Kinofilm" branding
  2. Films are 60-90 min vs 40 min episodes
  3. Mixing them into Folge sequence disrupts browsing
  4. Distinct cover art and marketing ("Die Hörspiele zum Kinofilm")
→ Propose sub_series: label="kinofilm", album_ids=[...film albums],
  reason="Theatrical film Hörspiele with distinct branding, disrupt episode sequence"
```

**Clear split** (standalone work from author umbrella):
```
Series: "Astrid Lindgren Deutsch"
Albums found: 40 albums spanning Ronja, Michel, Karlsson, misc stories
Reasoning:
  1. "Ronja Räubertochter" (3 albums) is a standalone literary property
  2. German parents search for "Ronja" by name, not "Astrid Lindgren"
  3. Recognizable: school curriculum, film adaptation, cultural landmark
→ Propose sub_series: label="ronja_raeubertochter",
  album_ids=[...Ronja albums],
  reason="Standalone literary work, parents search by title"
```

**Do NOT split** (no distinct branding):
```
Series: "Benjamin Blümchen"
Albums found: 140 numbered episodes, 1 album "Benjamin Blümchen: Der Kinofilm"
Reasoning:
  1. No "Kinofilm" sub-branding, just the series name
  2. 50 min duration, same range as regular episodes
  3. Keep in parent. Include with episode_num=null
→ No sub_series proposal
```

**Do NOT split** (Adventskalender):
```
Series: "Die drei ???"
Albums found: 3 Adventskalender albums (2021, 2022, 2023)
Reasoning:
  1. Annual releases of the same format, not separate product lines
  2. Parents think "the Advent calendar", not "the 2022 Advent calendar"
  3. Either keep all three in the parent, or group as ONE sub_series
     "adventskalender" (not three separate series)
→ If splitting: label="adventskalender", album_ids=[all 3],
  reason="Annual format, grouped as one sub-series"
  If keeping: no proposal, include with episode_num=null
```

**Do NOT split** (compilation repackaging):
```
Series: "TKKG"
Albums found: 5 "TKKG 3er Box" compilation albums
Reasoning:
  1. These are re-packagings of existing episodes, not new content
  2. Exclude with reason=compilation, not a split candidate
→ No sub_series proposal. Exclude the compilations.
```
