## Phase: Finalize

You receive:
- Series title and active episode_pattern
- Existing series_facts from prior runs (incremental updates)
- Structural analysis: gaps, duplicates, cross-provider coverage, pattern
  coverage (pre-computed from the batch phase decisions)
- Era evidence: albums where the batch phase noted an era collision
- Included albums that lack episode numbers (titles didn't match the pattern)

Your job is to resolve what the batch phase left open. The structural
analysis tells you WHERE the gaps are. Your tools let you investigate WHY
and propose fixes.

## How to investigate

Start from the structural analysis. Each signal is a lead:

**Gaps** (missing episode numbers): check if the episode exists under a
different title. Use `search_included_albums` with the episode number or
keywords. If it's truly absent from the discography, propose it as a
`known_gap` with `reason='unknown'` (or a specific reason if you can
determine one, e.g., legal dispute, number skipped by publisher).

**Era evidence**: the batch phase flagged albums with the same episode
number but different titles or release dates 5+ years apart. Group them
by release-date cluster and title convention. Propose `era_boundary` facts
that label each production run (e.g., "Klassiker (1977-1990)",
"CGI-Reboot (2015-2025)").

**Cross-provider missing episodes**: an episode on one provider but absent
from the other. Use `get_album_details` or `search_included_albums` to
check if it was excluded under a different title or is genuinely missing
from that provider's catalog. Propose `known_gap` for confirmed absences.

**Unnumbered albums**: inspect track listings (track 1 often starts with
the episode identifier). Call `get_album_details` if tracks aren't in
context. Apply the current `episode_pattern` to track names. If a track
reveals the episode number, return it in `episode_updates`.

**Title clusters**: groups of albums with a shared prefix or pattern that
differs from the main series. These may be sub-series. Use
`search_included_albums` to find all matching albums by title keyword,
then propose a `sub_series` fact with their `album_id` values.

## Two output channels

Your work goes through two separate channels:

1. **Tools (side effects)**: `propose_series_facts` records era_boundaries,
   known_gaps, and sub_series directly. `propose_pattern_update` updates
   the episode pattern. These take effect immediately.

2. **Output struct**: `FinalizeResult` with `episode_updates` (album_id →
   episode_num mappings) and optional `proposed_pattern_update`.

Call `propose_series_facts` for structural facts. Return episode number
assignments in `FinalizeResult.episode_updates`.

## Pattern updates

If you discover a systematic new naming format across unnumbered albums
(e.g., all tracks start with "Folge NNN:" while album titles don't),
propose a `pattern_update`.

A pattern update EXTENDS the current pattern: add a regex to the list or
refine a single entry. Never replace a list of era patterns with one
merged regex. A broad unanchored regex (e.g. `(\d+)(?=/|:|\))`) passes
today's coverage check but grabs stray digits in future titles and
corrupts episode numbers. One anchored regex per naming convention.

## Verification

After proposing facts, episode numbers, and any pattern updates, call
`lint_current_curation`. The lint tool runs deterministic structural
checks against the updated state (including your pattern update, if any).
Call it AFTER `propose_pattern_update`, not before.

Address lint findings: fix via additional `episode_updates` or fact
proposals, or accept them as known limitations in your concerns. A lint
finding that you can explain (e.g., pattern coverage at 65% because the
remaining 35% are movie Hörspiele with no episode numbers) is fine to
document rather than fix.

## Web research (optional)

You have `web_search` (max 3 queries) and `fetch_page` (max 2 URLs).
Use them to cross-check episode counts, verify gap reasons, or confirm
sub-series boundaries against fan wikis or episode lists.

**Output:** `FinalizeResult` with episode_updates and optional pattern_update.
