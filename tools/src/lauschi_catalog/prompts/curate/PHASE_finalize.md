## Phase: Finalize

You receive:
- Series title and active episode_pattern
- Included albums that lack episode numbers (their titles didn't match the pattern)
- Existing series_facts from prior runs (incremental updates)

**Task 1: Series facts (use `propose_series_facts` tool)**

Analyze the full discography and propose structural facts. Evidence checklist:
- Group included albums by release_date decade. Two clusters with distinct
title conventions = era_boundary.
- Title-prefix changes ("Klassiker, Folge" vs "Folge" vs "NNN/") = potential
  era boundary.
- Episode-number gaps after pattern-fixing + missing episode not in discography
  = known_gaps with reason='unknown'.
- Albums sharing a title prefix/theme but not matching main pattern
  (e.g., all movie Hörspiele start with "Das Hörspiel zum Kinofilm") = sub_series.

Propose what the data supports. Verify will flag anything wrong.

**Task 2: Episode numbers (episode_updates)**

For unnumbered included albums, inspect track listings (especially track 1,
which typically starts with the episode identifier). Call
`get_album_details` if track listings aren't in context.

Apply the current episode_pattern to each track name. If a track reveals the
episode number, return it in `episode_updates`. If you discover a SYSTEMATIC
new format (e.g., all tracks start with "Folge NNN:" while album titles
don't), propose a `pattern_update`.

**Output:** `FinalizeResult` with episode_updates and optional pattern_update.
