# Episode numbers: one derivation, one source of truth

Episode numbers are the only thing that gives a kid a 1, 2, 3 ordering.
Neither provider has the concept: Spotify returns an artist's albums
newest-first by release date, and its album object carries no ordinal
(`album_type, artists, copyrights, external_ids, external_urls, genres,
href, id, images, is_playable, label, name, popularity, release_date,
release_date_precision, total_tracks, tracks, type, uri`). Apple Music is
the same (`artistName, artwork, copyright, genreNames, isCompilation,
isComplete, isMasteredForItunes, name, playParams, recordLabel,
releaseDate, trackCount, upc, url`). `track_number` counts chapters
*within* one album, not episodes.

So the number exists only inside the album title, where German
publishers put it ("Folge 27: …"), and we extract it with a regex.

## The hierarchy

```
provider artist   "LEGO Ninjago"
  └── album       "Folge 01: Der Aufstieg der Schlangen"   = one episode
        └── track "Kapitel 01: … (Folge 01)"               = a chapter of it
```

One album is one episode. Its tracks are chapters of that single story.
A few series bundle 2–3 episodes per album (Wickie's classic CDs); those
are excluded as `compilation_as_episode`.

Playback never needs the episode number — the player streams an album by
URI. The number drives **ordering** (`cardOrder`: sortOrder, then
episodeNumber, then createdAt) and therefore the "Weiter" badge, and it
is the **label the child taps**.

## Why there is exactly one implementation

Until 2026-07 there were two, and they disagreed on 260 of 9,972 albums
(2.6%).

The app had its own `_extractEpisode` written 2026-02-19, when Dart still
did keyword matching. `9b443e2e` (2026-05-13, "match search results by
album_id only") made the catalog index album-id based, which meant a
successful `match()` always had the curated album in hand — the
re-derivation became redundant, but the call stayed. Python meanwhile
gained `_fix_escapes` (2026-05-29) that never crossed over.

The two algorithms differed in four ways:

| | Python `extract_episode` | Dart `_extractEpisode` (deleted) |
|---|---|---|
| pattern lists | each in order, first match wins | joined into `(?:p1)\|(?:p2)` |
| capture groups | group 1 only | all groups, first non-null |
| case | sensitive | insensitive |
| double escapes | repaired (`\\d` → `\d`) | used raw |

The 260 disagreements fell into three classes: 148 albums in 14
pattern-less series whose numbers came from curation rather than a regex;
`lieselotte_filmhoerspiele`'s double-escaped pattern, which Python
silently repaired and Dart could never match; and AI-assigned numbers
whose titles the series pattern does not match (teufelskicker's
"EM-Wissen 01 – …" against `^Folge (\d+):`).

It was user-visible because two insert paths disagreed: the catalog
series detail screen stored the curated `episode`, while browse stored
the re-derived one. The same album got a different number depending on
which screen a parent added it from, and a null number sends an item to
the `sortLast` sentinel at the bottom of the tile.

**The rule now: episode numbers are derived once, in the Python curation
pipeline, where they are audited and drift-checked. The app consumes the
curated value and never re-derives it.** Alignment is structural, not a
matter of keeping two regex dialects in sync.

## Albums the catalog does not know

A parent can add a brand-new release that our snapshot predates. It has
no curated number, and per the rule above the app must not run
series-specific patterns. Instead it applies one conservative generic
pattern derived from the 74 distinct patterns in the catalog:

- an explicit keyword (`Folge`, `Teil`, `Band`, `Episode`, `Kapitel`)
  followed by a number, or
- a leading number followed by `/` or `:`
- never a bare number elsewhere in the title
- abstains on ranges (`Folge 1-5`, `Folge 3+4`) because those are
  compilations, not episodes

Measured against all 9,972 curated albums: **89.5% agree, 0.1% disagree,
10.4% abstain**. The nine disagreements are all in
`prinzessin_lillifee_gute_nacht_geschichten`, whose titles carry both a
disc number and an episode range (`002/… Folge 3+4 …`) — and that series
*is* in the catalog, so its curated value wins and the generic pattern
never applies to it.

Abstaining is the safe failure: a null number parks an item at the end of
the list, visibly. A wrong number silently misorders the sequence, which
is why the pattern is deliberately narrow rather than greedy.

## Fragility to know about

Because the number lives in a mutable title, a publisher can remove it.
Spotify did exactly that in 2026-07 to Lauras Stern: `'Laura, Folge 7:
Laura und die Lampioninsel'` became `'Laura und die Lampioninsel'`. The
stored `episode_num` 7 survives in the curation and is annotated, but it
can no longer be re-derived, and a `--force` re-curate would lose it.

`catalog-drift` reports this class. It is one of the reasons a
title-independent product identity (the `upc`, which both providers
return) is worth storing.

## Guardrail

`test/core/catalog/catalog_python_parity_test.dart` walks every curated
album and asserts the app derives exactly the number the curation
recorded. It passes by construction now, and fails if anyone
reintroduces derivation in the app or if curated episode data goes
missing.
