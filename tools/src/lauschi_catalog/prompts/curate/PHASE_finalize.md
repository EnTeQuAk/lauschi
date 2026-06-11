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
  = known_gaps with reason='unknown'. The structural analysis (gaps, duplicates,
  cross-provider coverage) is provided in context. Every gap visible in the
  analysis should be proposed as a known_gap unless you can resolve it via
  episode_updates or get_album_details.
- Albums sharing a title prefix/theme but not matching main pattern
  (e.g., all movie Hörspiele start with "Das Hörspiel zum Kinofilm") = sub_series.
  A sub_series without `album_ids` is useless: downstream tools need to know
  which albums belong to it. After identifying a sub_series pattern, use
  `search_included_albums` to find the matching albums by title keyword,
  then include their `album_id` values in the proposal.

Propose what the data supports. Verify will flag anything wrong.

**Task 2: Episode numbers (episode_updates)**

For unnumbered included albums, inspect track listings (especially track 1,
which typically starts with the episode identifier). Call
`get_album_details` if track listings aren't in context.

Apply the current episode_pattern to each track name. If a track reveals the
episode number, return it in `episode_updates`. If you discover a SYSTEMATIC
new format (e.g., all tracks start with "Folge NNN:" while album titles
don't), propose a `pattern_update`.

A `pattern_update` must EXTEND the current pattern: add a regex to the
list or refine a single entry. Never replace a list of era patterns with
one merged regex. A broad unanchored regex (e.g. `(\d+)(?=/|:|\))`)
passes today's coverage check but grabs stray digits in future titles
and corrupts episode numbers. One anchored regex per naming convention
is the contract.

**Task 3: Lint check (use `lint_current_curation` tool)**

After proposing facts, episode numbers, and any pattern updates, call
`lint_current_curation` to run deterministic structural checks. The lint
tool sees the updated pattern (if you proposed one), so call it AFTER
`propose_pattern_update`, not before. Address any findings: fix via
additional episode_updates or fact proposals, or accept them as known
limitations documented in your concerns.

**Task 4: Cross-provider discrepancies**

If the analysis shows episodes present on one provider but missing on another
(cross_provider_coverage), investigate with `get_album_details` or
`search_included_albums`. An episode on apple_music but absent from spotify
(not even excluded) is either a catalog gap or a misclassified album. Propose
known_gaps for confirmed missing episodes.

**Web research (optional):**
You have `web_search` (max 3 queries) and `fetch_page` (max 2 URLs) available.
Use them to cross-check episode counts, verify gap reasons, or confirm
sub-series boundaries against external sources (fan wikis, episode lists).

**Output:** `FinalizeResult` with episode_updates and optional pattern_update.
