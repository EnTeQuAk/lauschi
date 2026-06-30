## Phase: Finalize

You receive the batch phase's output plus pre-computed structural analysis.
Your job: resolve the specific items the user prompt lists. Nothing more.

**Input in the user prompt:**
- Work-item summary (what needs your attention)
- Existing series_facts (already-documented era_boundaries, known_gaps, sub_series)
- Era evidence (batch-flagged same-episode-number collisions, if any)
- Structural analysis (gaps, duplicates, cross-provider coverage, pattern coverage)
- Unnumbered albums (included but no episode_num from pattern match, if any)

## Workflow

Process the work items listed in the user prompt. For each category:

### Unnumbered albums

For each unnumbered album, check the inline track listing first. If that's
not enough, call `get_album_details`. If track names reveal the episode
number (e.g. track 1 is "Folge 42: Der Blutfleck, Teil 1"), return it in
`episode_updates`. Films, specials, and compilations are legitimately
unnumbered; leave them with episode_num=null.

### Era evidence

Compare the batch-flagged era collisions against existing `era_boundaries`
in the user prompt. If existing facts already explain the clusters (same
eras, same date ranges), skip. Only call `propose_series_facts` for
genuinely new eras not yet documented.

### Duplicate episode numbers

Same-provider duplicates are usually explained by era_boundaries or
sub_series already in existing facts. Check before investigating. If a
sub_series explains the collisions, call `search_included_albums` once
to gather album_ids, then `propose_series_facts`.

### Gaps

If the structural analysis lists gaps, check whether existing `known_gaps`
already cover them. For truly new gaps, use `web_search` to confirm the
reason (legal dispute, publisher skip), then propose via
`propose_series_facts`.

If the structural analysis shows no gaps, do not search for gaps.

### Verification

After all updates, call `lint_current_curation` once. Address actionable
findings. Expected findings (era-based duplicates, unnumbered films)
are fine to document rather than fix.

## Scope control

- Work only the items listed in the user prompt. Don't explore the catalog.
- Existing facts that already explain a structural signal = no action needed.
- `search_included_albums` returns album_id, provider, title, and
  episode_num. Use it to check numbering state before calling
  `get_album_details`.
- Most series need 3-6 tool calls total. Past 10 means over-investigating.

## Output channels

1. **Tools (side effects)**: `propose_series_facts` for era_boundaries,
   known_gaps, sub_series. `propose_pattern_update` for pattern changes.
   These take effect immediately.

2. **Return value**: `FinalizeResult` with `episode_updates` (album_id →
   episode_num) and optional `proposed_pattern_update`.

## Pattern updates

Only propose when you discover a systematic new naming format across
multiple unnumbered albums. Extend the pattern list; never merge
conventions into one broad regex. Each regex must be `^`-anchored.

## Web research (optional)

`web_search` (max 3 queries) and `fetch_page` (max 2 URLs). Use for
confirming gap reasons or sub-series boundaries, not for mapping the catalog.

**Output:** `FinalizeResult` with episode_updates and optional pattern_update.
