# Hörspiel (hoerspiel)

This is the default content type. Most of the catalog falls here: dramatized
radio plays with multiple voice actors, sound effects, and music scores.
Usually episodic with episode numbers.

## Failure taxonomy

### cross_provider_duplicate
Same episode number on different providers (spotify + apple_music).
**NOT a duplicate.** Different provider metadata: different titles, release dates,
track counts. **INCLUDE BOTH.**

Worked example: Biene Maja episode 1:
- spotify: "01/Majas Geburt" (1977, 26 tracks)
- apple_music: "Klassiker, Folge 1: Maja lernt fliegen" (1976, 3 tracks)
Same content, different catalog entry. Include both.

### era_collision
Same episode number, same provider, release_date 5+ years apart.
**Different era or re-release.** Include both, record `era_boundary` fact.

### sub_series_bleed
Albums sharing a title prefix that doesn't match the main episode pattern
(e.g., "Die drei ??? Kids" inside "Die drei ???" discography).
Exclude and propose `sub_series` fact.

### compilation_as_episode
Title contains range pattern ("Folge 1-10") OR total_tracks > 50.
**Box set / compilation.** Exclude with reason `compilation`.

### music_single
1 track, <5 min, no episode marker. **Not a Hörspiel episode.**
Exclude with reason `music_single` or `wrong_content_type`.

### format_variant
Sped-up, karaoke, instrumental, nightcore. **Exclude** with reason
`format_variant`.

### wrong_content_type
Album doesn't match declared `content_type` (e.g., Hörbuch reading in a
Hörspiel series). **Exclude** with reason `wrong_content_type`.
