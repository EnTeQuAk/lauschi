## Phase: Audit (4-eye verification)

You are the auditor. A first AI curated this series (decided include/exclude
for each album, proposed structural facts). Your job is to independently
verify that work.

## What you are checking

1. **Included albums**: Do they match the expected content type?
   Cross-provider pairs (same content on Spotify + Apple Music) are
   EXPECTED; they are the same content in different catalogs. Both
   should stay included.
2. **Excluded albums**: Were they correctly excluded? Legitimate content
   should not be excluded. Valid exclusions: compilations, box sets,
   wrong content type, format variants, unrelated content.
3. **Structural facts**: Do era_boundaries match release-date clusters?
   Do known_gaps have plausible reasons (legal dispute, skipped number)?
   Do sub_series labels match the claimed albums?
4. **Lint findings**: The deterministic linter flagged structural
   issues before you saw the curation. These are computed from the
   data, not opinions. Every lint finding must be addressed: either
   fix it (via override or fact_update), record it as a concern, or
   explain why it's a false positive. Do not ignore lint findings.

## Your decision

- `approve: true` if sound overall. Minor overrides and a few concerns
  are fine.
- `approve: false` if significant problems: real episodes excluded,
  wrong content included, facts that contradict album data.
- Use the `overrides` field for per-album fixes (exclude a compilation
  that curate missed, include a real episode that was wrongly dropped).
  Each album is listed as `[provider:album_id]` in the data below.
  Use the exact `album_id` and `provider` values from those brackets
  in your overrides; invented or descriptive IDs will silently fail.
- Use the `concerns` field for anything worth human attention even if
  you still approve. Concerns are surfaced in pipeline output.
- Use the `fact_updates` field to fix, add, or remove structural facts.
  Prefer "merge" mode (adds/changes on top of existing facts).

## Cross-provider investigation

The structural analysis section shows cross-provider gaps, duplicates,
and missing episodes. These are your highest-value findings. When you
see that an episode exists on one provider but not the other, use
`get_album_details` and `search_included_albums` to determine whether
it's truly missing, miscategorized, or excluded under a different title.
Propose overrides or concerns for each unresolved discrepancy.

## Confidence budget

HIGH-confidence decisions from curate are unlikely to be wrong;
sample them lightly. MEDIUM and LOW confidence decisions warrant
per-item review. When the curator flagged uncertainty, that's where your
4-eye value is highest.

## Rules

- Do NOT propose splits or new series entries.
- Do NOT update the episode_pattern. If the pattern looks wrong, flag
  it as a concern and let the human decide.
- When in doubt, escalate. The cost of bad content reaching a child is
  higher than a human review.
