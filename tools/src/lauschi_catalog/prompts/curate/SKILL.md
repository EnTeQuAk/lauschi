# Lauschi Catalog Curation Skill

You are curating a DACH (Germany/Austria/Switzerland) children's audio catalog
for "lauschi", a privacy-first kids audio player. The catalog covers three
content types (hoerspiel, music, audiobook). You curate one series at a time,
and each series has exactly one content type.

## Domain model

A **series** is a multi-provider audio catalog entry identified by canonical
artist IDs on Spotify and Apple Music. Depending on content type, a series may
be an episodic production (Hörspiel), a music artist's discography, or an
author's audiobook catalog. Some series have gaps (legal disputes, publisher
changes), era shifts (naming convention changes across decades), or sub-series
(spin-offs that belong in separate catalog entries).

The type-specific reference doc loaded alongside this skill has the full
failure taxonomy and worked examples for the active content type.

## Content type purity (critical principle)

A series has **exactly one** `content_type`. Albums that don't fit are excluded
with `wrong_content_type`, not bent to fit.

| content_type | German term | Production style | Episode numbers |
|---|---|---|---|
| `hoerspiel` | Hörspiel (radioplay) | Dramatized: multiple actors, foley, music score | Usually yes |
| `audiobook` | Hörbuch | Read aloud: one narrator, minimal sound design | Usually no |
| `music` | Kinderlieder / Kinderpop | Songs: singer + band | No |

**Hörbuch vs Hörspiel** is the most error-prone classification. The
discriminator is *production style*, not source material. The same novel can
have both a Hörbuch (single narrator reading) and a Hörspiel (full cast
dramatization). These are different productions, separate `series.yaml` entries.

| Signal | Hörbuch (audiobook) | Hörspiel (hoerspiel) |
|---|---|---|
| Voices | One narrator | Multiple voice actors |
| Sound design | Minimal or none | Foley, effects, music score |
| Title hints | "Lesung", "ungekürzt", "gelesen von …" | "Folge N:", "Original-Hörspiel" |
| Track shape | Many tracks (chapters) on Spotify; few long on Apple Music | Few tracks per episode on both |
| Duration | 3-12 h (whole book) | 30-70 min (one episode) |

Example: Michael Ende's "Die unendliche Geschichte" read by Rufus Beck
(116 tracks, one narrator) is a Hörbuch. "Die drei ??? Folge 1: Der
Super-Papagei" (multiple actors, sound effects) is a Hörspiel.

When a single discography legitimately spans multiple types (e.g. Pumuckl:
Hörspiel + film soundtrack + Kinderlieder), flag mixed-type albums for
splitting into separate series.yaml entries by content_type. Do NOT include
mixed-type content under one series.

## Phases

1. **Metadata** — Extract series identity: id, title, episode_pattern,
   content_type, provider artist IDs
2. **Batch** — For each album: include or exclude, with episode_num
3. **Finalize** — Resolve unnumbered albums, propose structural facts
   (era boundaries, gaps, sub-series)

Phase-specific instructions and output schemas are loaded separately.

## Decision procedure: include / exclude

| Title shape | Track count | Duration | Action |
|---|---|---|---|
| Matches `episode_pattern` | Episode shape (1-5 Apple, 20-40 Spotify) | 20-60 min | Include |
| Range pattern ("Folge 1-10", "Jubiläumsbox") | >50 | Variable | Exclude (`compilation`) |
| Single track, <5 min | 1 | <5 min | Exclude (`music_single` or `wrong_content_type`) |
| "ungekürzt", "Lesung", "gelesen von" | Many tracks | 3-12 h | Exclude (`wrong_content_type`) in non-audiobook series |
| "Best of", "Greatest Hits", "Kinderparty" | Variable | Variable | Exclude (`compilation` or `multi_artist_compilation`) |
| Instrumental, karaoke, sped-up, nightcore | Variable | Variable | Exclude (`format_variant`) |

## Cross-provider consistency (critical rule)

The same title on Spotify and Apple Music is the same content with different
packaging (track counts, release dates, metadata). Your include/exclude
decision for a title MUST be the same on both providers. Different track counts
between providers are expected and never a reason to exclude.

### Same-episode-number cases

When you see the same episode number in the discography:

| Condition | Action |
|---|---|
| Different providers, same episode number | **Include both.** Not a duplicate. Each provider has its own catalog entry. |
| Same provider, similar title, release dates within ~2 years | **Duplicate.** Keep the most recent or unabridged. |
| Same provider, different title OR release gap ≥ 5 years | **Different era.** Include both, record `era_boundary` fact. |

"Similar title" means ≥80% token overlap after stripping episode numbers,
prefixes, suffixes, punctuation, and case-folding.

## Episode pattern

An `episode_pattern` answers "*how do I order included albums?*", not
"*what numbers appear anywhere in the discography?*".

- Always anchor with `^`. Unanchored `Folge (\d+):` matches inside
  `Folge 1-10: Sammelbox` and silently mis-orders compilations.
- Track-level numbers ("Teil 01", "Teil 02") are chapter markers within
  ONE episode, not episode numbers. The discriminator: if you removed the
  matching prefix, would the remainder be a distinct episode title?
- If episodes use named titles without numbering, set `episode_pattern=None`.

## Inclusion bias (critical principle)

This is a kids' audio app. The cost of a missed real episode (a child can't
listen to it) is higher than the cost of including a borderline album.
**When in doubt, include.**

Before excluding any album, you MUST name the failure-taxonomy pattern it
matches. If you cannot name the class, include with `episode_num=None`
(the album sorts by `release_date` downstream).

## False positive watchlist

These patterns are correct behavior, not curation errors:

- Different provider + same episode number → not a duplicate
- Episode-pattern coverage below 80% → classify every unmatched title as
  (a) legitimate non-episode, (b) missed episode needing a new pattern, or
  (c) excludable. Only keep the pattern when every unmatched title is
  accounted for. Never round coverage up to a threshold.
- Missing episode N documented in `known_gaps` → not a curation error
- Cross-provider asymmetry on 1-3 episodes → content rotation
- Type-mismatch albums excluded with `wrong_content_type` → correct

## Confidence

Confidence reflects how many independent signals converge on your decision.
Think of each piece of evidence as a vote:

**Signals for inclusion:** title matches episode_pattern, track count fits
the content type's shape (Hörspiel: 20-40 Spotify / 1-5 Apple Music),
duration is episode-length (30-70 min), album_type is "album", the same
episode exists on the other provider.

**Signals for exclusion:** title matches a named failure pattern (compilation,
music_single, format_variant, etc.), album_type is "single", duration or
track count contradicts the content type, title contains exclusion markers
("Best of", "Karaoke", "- Single").

| Confidence | When to use | Example |
|---|---|---|
| **HIGH** | Multiple signals agree, no contradictions | Title matches pattern + track count fits + album_type=album |
| **MEDIUM** | One signal, or signals conflict | Title matches pattern but track count is unusual; OR no pattern match but the album looks like valid content |
| **LOW** | No strong signal in either direction | Can't tell if this is an episode or not from available data |

Rules:
- **Exclude requires HIGH + a named failure pattern.** If you can't name
  the pattern, include instead.
- **MEDIUM and LOW require `notes`** explaining which signals conflict or
  are missing. The schema enforces this.
- Use MEDIUM sparingly. If more than ~10% of your batch decisions are
  MEDIUM or LOW, that's a signal something structural is off (wrong pattern,
  mixed sub-series, unfamiliar catalog shape). Investigate rather than hedge.
- When in doubt, move one level down (HIGH→MEDIUM, MEDIUM→LOW) and include.
