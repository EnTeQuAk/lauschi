# Pipeline Analysis: 2026-07-01

Log: `logs/catalog/pipeline-20260701-100905.log` (10,606 lines, 479KB)

## Summary

Pipeline ran with `--force` on all 254 series. Curate completed 50 series
(#1-#50), then crashed at #51 (Die Biene Maja) with the same
`release_date_range` validation error as last run. Series 52-254 were never
reached. The apply step in this run corrected the bad era_boundary values in
series.yaml, so the next run should pass Die Biene Maja.

The 39 re-curated series that had prior audit results all got skipped by audit
("curate is newer"), which then caused apply to refuse 15 of them ("stale
audit"). This is a circular dependency: audit won't run because curate is
newer, and apply won't run because audit is stale.

## Stage Results

### Curate (Step 1/6)

- **50 done**, 0 failed, 0 skipped, crashed at #51
- Total curate time: **5h 7m** (average 6m 8s per series)
- Crash: `load_existing_facts()` reads series.yaml, which still had `'2023'`
  (not `'2023-'`) for Die Biene Maja. The apply step later wrote the corrected
  value, so the next run will pass.

**Timing outlier:** LEGO City took **73m 39s** (201 included, 41 excluded).
Next slowest was Pettersson und Findus at 21m. LEGO City used 201
`search_included_albums` calls, 129 web searches, and 60 page fetches.

**Metadata prompt improvement confirmed:** 44/50 series (88%) do pattern check
before web research, up from 54% in the previous run (task #47 fix).

Top 5 by time:

| Series | Inc | Exc | Time |
|--------|-----|-----|------|
| LEGO City | 201 | 41 | 73m 39s |
| Pettersson und Findus | 53 | 38 | 20m 57s |
| Michael Ende | 38 | 24 | 20m 22s |
| Hexe Lilli | 81 | 0 | 13m 46s |
| Der Kleine Rabe Socke | 37 | 45 | 13m 34s |

### Reconcile (Step 2/6)

- **7 flips** (auto-fixed): Michael Ende (3), Otfried Preußler (4)
- **24 flags** (need review): Kira Kolumna (12), LEGO City (9),
  Feuerwehrmann Sam (1), Hanni und Nanni (1), Pettersson und Findus (1)

All 24 flags are `sub_series_bleed`. Kira Kolumna's 12 flags are all
"Reportage" episodes, where one provider includes them in the main series and
the other excludes them. LEGO City's 9 are older numbered episodes (Folge 3,
6-10, 25-27) that one provider treats as sub-series.

### Audit (Step 3/6)

- **39 series** queued for audit
- **All 39 skipped**: "audit is stale (curate ran after last audit)"
- **0 approved, 0 overridden, 0 escalated**

This is the circular dependency. The audit step refuses to process series where
curate ran more recently than the last audit. But after a `--force` re-curate,
that's always true. These series can never be audited without either:
1. A code fix to the staleness check, or
2. A `--force` flag on the audit step

### Lint (Step 4/6)

- **108 clean**, **138 with issues** (of 246 checked)

Major issue categories:

**Unaudited facts** (expected, since audit skipped all 39 re-curated series):
Most of the 138 "with issues" count comes from unaudited era_boundaries,
known_gaps, and sub_series. This will clear once audit runs.

**SpongeBob: 139 unaudited known_gaps** (ep 51-189). The curate model seems to
have discovered that SpongeBob Hörspiel skips from ep 50 straight to ~190 and
documented every gap. That's probably correct (the Hörspiel series doesn't
cover every TV episode), but 139 known_gaps is a lot of noise.

**Duplicate episodes within eras:**
- Hanni und Nanni: 12 duplicate eps in era 'klassik' (both providers)
- LEGO City: eps 25-27 duplicate in era '2020-2023'
- Otfried Preußler: ep 1 duplicate in 'digital_reissues' (both providers)
- Cornelia Funke: eps 4-5 duplicate in 'neue_produktionen'
- Das Sams: eps 1, 2, 5 duplicate in 'klassik'
- Hexe Lilli: ep 2 in 'original', ep 18 in 'continuation'
- Heidi: eps 3, 8 in 'cgi_reboot'
- Jan Tenner: ep 25 in 'der_neue_superheld'

**Cross-provider title counterparts** (included on one, content-excluded on other):
- Feuerwehrmann Sam: "Helden im Sturm" (sub_series_bleed)
- Hanni und Nanni: "Folge 2: Freundinnen für immer!" (sub_series_bleed)
- Michael Ende: "Momo" (wrong_content_type)
- Kira Kolumna: 12 Reportage episodes (sub_series_bleed)
- LEGO City: 9 episodes (sub_series_bleed)
- Deine Freunde, DIKKA, Senta, Sing Kinderlieder: music_single counterparts
- Der Gestiefelte Kater: wrong_content_type

**Implausible episode numbers:**
- Die Originale: "Folge 00: Goldrausch in Alaska" -> 0

**Low validation match rates (notable):**
- PAW Patrol spotify: 3/47 (6%) vs apple_music: 447/492 (91%)
- Wieso? Weshalb? Warum?: 64/170 spotify, 63/193 apple_music

### Apply (Step 5/6)

- **192 applied** (status: approved)
- **15 refused** (stale audit): Bibi Blocksberg, Bobo Siebenschläfer,
  Die Eiskönigin, Die Fuchsbande, Die kleine Schnecke Monika Häuschen,
  Die Olchis, Die Originale, Drachenzähmen leicht gemacht, Kati & Azuro,
  Kung Fu Panda, Madagascar, Prinzessin Lillifee, Rolf Zuckowski,
  Stephen Janetzko, Volker Rosin
- **2 no included albums**: 5_geschwister_adventskalender, bibi_und_tina_klangreise
- **1 not in series.yaml**: peter_pan_kinofilm

The 15 refused are all series that were re-curated in this run. Their curations
are valid but the pipeline's safety check blocks apply without a fresh audit.

### Validate (Step 6/6)

- **L1 syntax**: 254 series, no issues
- **L5 spotify**: 28/254 perfect match rate
- **L5 apple_music**: 32/249 perfect match rate

Notable low match rates (after apply):
- PAW Patrol/spotify: 3/47 (pattern matches only 3 of 47 discography albums)
- Wieso? Weshalb? Warum?: 64/170 spotify, 63/193 apple_music
- Bibi Blocksberg: 168/246 spotify, 175/240 apple_music
- Benjamin Blümchen: 168/275 spotify, 168/282 apple_music

Many 0/N entries are expected for series without episode patterns (film series,
music artists, author collections).

## Actionable Items

### Critical (blocks pipeline progress)

1. **Re-run pipeline for series 52-254.** series.yaml is now fixed. Die Biene
   Maja should pass and the remaining 204 series will finally be curated.

2. **Fix audit staleness logic.** The audit step skips ALL freshly-curated
   series because "curate is newer." This creates a circular dependency: audit
   won't process them, apply refuses without audit. Investigate the verify
   command's timestamp comparison and fix so it processes series with newer
   curate timestamps (that's exactly when audit SHOULD run).

### After audit fix

3. **Apply the 15 refused curations.** Once audit runs, these 15 series will
   unblock. If the audit fix takes time, consider using `--force` on the apply
   step as a temporary measure.

### Data quality

4. **Review 24 reconcile flags.** All `sub_series_bleed`. The big ones:
   - Kira Kolumna Reportage (12 flags): decide whether Reportage episodes
     belong in the main Kira Kolumna series or only in the split-off sub-series
   - LEGO City (9 flags): older numbered episodes (3, 6-10, 25-27) treated as
     sub-series by one provider

5. **Investigate Hanni und Nanni era duplicates.** 12 duplicate episodes in
   era 'klassik' on both providers. The era boundaries might be wrong, or
   there are genuine reissues within the same era that need deduplication.

6. **SpongeBob known_gaps noise.** 139 known_gaps (ep 51-189) is technically
   correct but creates enormous lint noise. Consider whether known_gaps should
   have a "bulk range" syntax (e.g., `51-189`) instead of 139 individual
   entries, or whether these should be handled differently.

7. **PAW Patrol spotify 3/47 match rate.** The episode pattern only matches 3
   of 47 albums in the Spotify discography. The pattern works on Apple Music
   (447/492). Spotify album titles probably use a different naming convention.

### Minor

8. **Die Originale ep 0.** "Folge 00: Goldrausch in Alaska" parsed as episode
   0. Either the pattern should skip this or the episode should be excluded.

9. **peter_pan_kinofilm not in series.yaml.** Curation exists but no
   series.yaml entry. Add it or remove the curation.

10. **LEGO City 73m curate time.** Investigate why this series took 3.5x longer
    than the next slowest. 201 `search_included_albums` calls suggest the agent
    was doing excessive verification. Could be a prompt issue or inherently
    complex discography.
