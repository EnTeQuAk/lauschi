# Audiobook (Hörbuch)

Printed books read aloud, usually by one narrator with little sound design.
In an audiobook series the Hörspiel of the same book is the other type
(`wrong_content_type`).

## Telling the reading from the play

Beyond the signals above, two settle it most often:

- **The source.** A Hörbuch reads a printed book more or less as written. A
  Hörspiel plays a script, also when the script was adapted from a book.
- **The credits.** "Sprecher: …" with one name is a reading. "Mit: …" and a
  list of names is a cast.

## Failure taxonomy

### ungekuerzt_reading
A full-book reading by one narrator, split into chapter tracks. Include if
it is a children's book.

### gekuerzt_reading
An abridged reading. Include it only if no `ungekuerzt` version of the same
title exists in the artist's catalog. Otherwise exclude it as
`format_variant`.

### inszenierte_lesung
A reading staged with a small cast (one to three voices, light music),
still anchored to the text of one book. Include, this is still a Hörbuch.

Worked example: "Jim Knopf und Lukas der Lokomotivführer, Hörspiel nach der
Romanvorlage" (Spotify, 8 tracks, ~75 min). The title says "Hörspiel", but
the credit lists "Sprecher: …" (one narrator) with occasional guest voices,
so this is an inszenierte Lesung, not a full Hörspiel cast. **Include** it
as a Hörbuch.

### hoerspiel_adaptation
A dramatized production with a cast and sound design, even if it is based
on the author's novel. **Exclude** (`wrong_content_type`), and flag it for a
separate `hoerspiel` entry.

### music_in_audiobook_catalog
A music album in an audiobook artist's catalog. Exclude
(`wrong_content_type`).

### non_kids_work
The author's works for adults. Exclude (`not_kids_content`), they are out of
scope for lauschi.

### compilation_set
A box of several books ("Sammelband: 5 Romane in einer Lesung"). Exclude
(`compilation`).

### excerpt_or_sample
A Leseprobe, a sample chapter, a promotional excerpt. Exclude
(`partial_release`).

## Reading the title and the tracks

The title is the first signal, and the tracks confirm it. For a bare title
by a known children's author, the tracks carry the decision: many chapter
tracks on Spotify, or several hours on Apple Music, is a reading (`high`).
A few tracks with the length of one story point to a Hörspiel: exclude it
when the title or the credits confirm it ("Hörspiel", a "Mit: …" cast),
and without that, include it at `medium` and say so in the notes.

Michael Ende's catalog as an example:

| Title fragment | Type | Action |
|---|---|---|
| "… - Die ungekürzte Lesung", "… - Die Lesung" | Hörbuch | **Include** |
| "…" with 100+ chapter tracks | Hörbuch | **Include** |
| "… - Das Hörspiel", "… - Das Hörspiel zum Film" | Hörspiel | **Exclude** (`wrong_content_type`) |
| "… - Kinderoper" | A musical stage adaptation | **Exclude** (`wrong_content_type`) |
| "Englisch lernen mit …" | Learning material, no story | **Exclude** (`wrong_content_type`) |
| "Let's Have Fun!", "Verdi: Messa da Requiem" | Not by Michael Ende | **Exclude** (`different_series`) |
| "… und weitere Geschichten" with 2+ book titles | Several books in one box | **Exclude** (`compilation`) |

When the same novel exists in both forms ("Momo" and "Momo - Das
Hörspiel"), the one without "Hörspiel", "Kinderoper" or "zum Film" is the
Hörbuch. When a prefix and a suffix disagree, the suffix wins: "Jim Knopf:
Jim Knopf und Lukas der Lokomotivführer - Die ungekürzte Lesung" is a
Hörbuch, and "Jim Knopf:" is only the series label the publisher puts in
front.

`high` needs positive evidence (many chapter tracks, hours of length, a
"Lesung" or "ungekürzt" suffix), not only the absence of a Hörspiel label.

## Pattern and facts

- Most books stand alone and have no `episode_pattern`. A book series that
  numbers its volumes ("Band 3", "Folge 12") has one in the catalog, and
  the run reads the numbers with it. Chapter or "Teil" numbers within one
  album are never episodes.
- `series_facts` are rare. Where a long career has distinct production
  phases (early readings against later staged readings, different
  narrators per decade), `sub_series` can group them. `era_boundaries`
  rarely apply, since eras mean numbered episodic content.
