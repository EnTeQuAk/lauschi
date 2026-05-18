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

## Failure taxonomy

### kinderlieder_compilation
"Best of", "Greatest Hits", numbered albums where each is a compilation.
Exclude.

### multi_artist_compilation
Albums featuring other artists ("Kinderparty Hits", "Nick Jr.'s …").
Exclude.

### format_variant
Karaoke, instrumental, sped-up, nightcore. Exclude.

### wrong_content_type
Hörspiel or Hörbuch in a music artist's catalog. Exclude, flag for series
split if substantial.

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
