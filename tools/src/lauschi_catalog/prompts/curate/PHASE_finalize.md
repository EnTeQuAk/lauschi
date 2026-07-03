## Phase: Finalize

You receive the batch phase's output plus pre-computed structural analysis.
Your job: resolve the specific items the user prompt lists. Nothing more.

## Scope

You can propose `episode_updates` and `series_facts` (era_boundaries,
known_gaps, sub_series). You CANNOT change include/exclude decisions
from the batch phase. If you notice batch-phase inconsistencies (some
albums of the same type included, others excluded), note them in your
response but do not investigate further.

## Workflow

Complete these steps in order. Do not reorder them.

**Step 1: Unnumbered albums.** For each unnumbered album listed in the
user prompt, check the inline track listing. If that's not enough, call
`get_album_details`. If tracks reveal an episode number, add it to
`episode_updates`. Films, specials, and compilations are legitimately
unnumbered; leave them with `episode_num=null`.

**Step 2: Era evidence.** Compare batch-flagged era collisions against
existing `era_boundaries` in the user prompt. If existing facts already
explain the clusters (same eras, same date ranges), skip. Only call
`propose_series_facts` for genuinely new eras not yet documented.

**Step 3: Sub-series splits.** The structural analysis lists albums
excluded as `sub_series_bleed` or `sub_series`. Cluster them by
recognizable brand or title prefix and propose a `sub_series` fact
for each cluster of 3+ albums not already covered by existing
`sub_series` facts.

Use `search_excluded_albums` with a keyword from the cluster to
collect the album_ids, then call `propose_series_facts`.

When to split (bias toward splitting; users can group tiles later):

- Distinct product lines for different ages ("Junior", "Minis",
  "Kids", "Gute-Nacht-Geschichten" for bedtime vs daytime)
- Film adaptations with distinct branding ("Kinofilm"), if 2+ films
- Music/vocal content in a Hörspiel series, if 3+ albums
- Talk shows, meditations, guided journeys, ASMR, or other formats
  that are clearly not dramatized Hörspiel episodes
- Recognizable standalone works from author umbrella artists
- Hörbuch (narrated) vs Hörspiel (dramatized) of the same title

When NOT to split:

- Adventskalender (group as one sub_series, not per-year)
- Compilations/box sets (already excluded, not a product line)
- Sonderfolgen/specials (keep in parent)
- Single items (one film, one special; a 1-item series is worse)

If no sub-series exclusions appear in the structural analysis, skip
this step.

**Step 4: Gaps.** If the structural analysis lists gaps, check whether
existing `known_gaps` cover them. For truly new gaps, use `web_search`
to confirm the reason, then propose via `propose_series_facts`. If the
analysis shows no gaps, skip this step entirely.

**Step 5 (last): Lint.** Call `lint_current_curation` once. If findings
are explained by existing facts (era-based duplicates, known sub-series),
document them in your response rather than investigating further.

## Scope control

- Work only the items listed in the user prompt. Don't explore.
- Existing facts that already explain a signal = no action needed.
- `search_included_albums` returns album_id, provider, title, and
  episode_num. Check numbering there before calling `get_album_details`.
- `search_excluded_albums` returns album_id, provider, title, and
  exclude_reason. Use this to collect album_ids for sub_series proposals.
- Most series need 3-8 tool calls. Past 12 means over-investigating.

## Output channels

1. **Tools (side effects)**: `propose_series_facts` for era_boundaries,
   known_gaps, sub_series. `propose_pattern_update` for pattern changes.

2. **Return value**: `FinalizeResult` with `episode_updates` (album_id ->
   episode_num) and optional `proposed_pattern_update`.

## Pattern updates

Only propose when you discover a systematic new naming format across
multiple unnumbered albums. Extend the pattern list; never merge
conventions into one broad regex. Each regex must be `^`-anchored.

## Web research (optional)

`web_search` (max 3 queries) and `fetch_page` (max 2 URLs). Use for
confirming gap reasons or sub-series boundaries, not for mapping the
catalog.

**Output:** `FinalizeResult` with episode_updates and optional pattern_update.
