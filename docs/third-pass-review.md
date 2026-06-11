# Third-pass curation review

Manual review of all approved curations, on top of curate (kimi-k2.6)
and audit (minimax-m2.7). Lens: wrong-franchise content, adult-content
signals, undocumented episode gaps, same-provider duplicates,
content_type fit, wrongly excluded real episodes, overall match with
the series' real-world shape.

Verdicts: PASS (no action), NOTE (minor, no action needed), FIX
(mechanical fix applied), FLAG (needs Chris).

## Tranche 1

- 100_wolf: PASS. 2x26 episodes 1:1, Staffel 2 documented as gap,
  movie Hörspiele in, soundtracks/samplers out.
- 3berlin: FIX. Cross-provider inconsistency (audit had noted, not
  fixed): 8 Apple "Summ, Summ, Summ" twins of included Spotify albums
  now included, plus the 2014 Schlaflieder Spotify twin. 74 included.
- 5_geschwister: FIX. "01: Der Fahrraddieb" is the 5 Geschwister Kids
  spin-off (Wikipedia), excluded both providers as sub_series_bleed.
  Apple episode-29 double release deduped. Adventskalender Tag 16-24
  daily slices excluded (full story album included instead, now
  numbered as Folge 44 per curator notes); gap record updated.
- alles_steht_kopf: PASS. 2 films x 2 providers.
- angry_birds: NOTE. Film 1 only on Spotify, film 2 only on Apple;
  genuine provider exclusives, nothing to fix.
- asterix: PASS. 41x2 plus Sonderfolge, single foreign-artist single
  excluded.
- astrid_lindgren_deutsch: FIX. Spotify exact duplicate of Pippi 1
  deduped; 93-min suspected Lesung of Taka-Tuka excluded (proper
  Hörspielklassiker stays). FLAG: heavy content overlap with the
  standalone pippi_langstrumpf and bullerbue series; a parent adding
  both gets duplicates. Catalog-design call.
- bambi: FIX. Folge 1-3 (2020 All Ears run, Apple Music) were excluded
  with an unsure reason AND recorded as gaps; included now, gap notes
  rewritten as Spotify-side asymmetry.
- benjamin_bluemchen: PASS. 1-171 near-complete both providers, gaps
  documented. NOTE: excluded Minis/Gute-Nacht-Geschichten sub-series
  are future catalog candidates.
- bibi_blocksberg: FIX. Two short-story collections were included on
  Spotify but excluded on Apple; Apple twins now included.
- bibi_und_tina: FIX. Apple's 4th movie Hörspiel was excluded as
  sub_series_bleed while Spotify's twin was in (movies 1-3+5 on both);
  included. Spotify ASMR Klangreisen excluded for consistency with the
  Apple side and bibi_blocksberg's wrong_content_type treatment.

## Tranches 2-9 (remaining catalog)

Fixed:
- coco / encanto / dragons_die_reiter_von_berk: missing Apple Music
  albums added (Coco 2017 Hörspiel, Encanto Disney Hörspiel under the
  'Encanto Hörspiel' artist, Reiter-von-Berk ep 2 under the base
  Dragons artist). Apple users previously had no or incomplete content.
- manuel_straube: 75 adult crime-mystery Hörspiele (Sherlock Holmes
  Chronicles, Professor van Dusen, Oscar Wilde, Captor,
  Sonderermittlerin der Krone) were INCLUDED in the kids' catalog.
  All excluded as not_kids_content; only the 2 Phineas und Ferb
  volumes remain. Worst kid-safety finding of the review.
- julia_donaldson: re-typed audiobook; 7 German ungekürzt readings
  included (were excluded as wrong type while only English song albums
  were in).
- kira_kolumna: 13 Reportage episodes included/excluded near-randomly
  across providers; uniform inclusion.
- lego_ninjago: 8 of 20 Band book-readings included against the series'
  own rule; uniform exclusion.
- die_drei_ausrufezeichen / fragezeichen_kids: Adventskalender albums
  uniformed (29 in), Mini-Fall sub-series uniformed (out),
  Ponyverschwörung deduped.
- die_playmos: Folge 100 weekly parts vs collected album resolved.
- die_punkies: Teufelskicker crossover out, 55 bogus gaps removed.
- feuerwehrmann_sam, cornelia_funke, bobo, bullerbue, astrid_lindgren,
  bibi_blocksberg: same-provider duplicates deduped.
- der_gestiefelte_kater: foreign Märchen short excluded.
- die_fuchsbande / bibi_und_tina: ASMR Klangreisen excluded uniformly.

PASS (gaps and Folge-number collisions verified as documented era /
edition / sub-format structures): all remaining ~110 series.

## Flags for Chris

- astrid_lindgren_deutsch overlaps pippi_langstrumpf and bullerbue;
  michael_ende overlaps jim_knopf-ish content; flohtoene/kalle_klang
  share collab albums (already de-overlapped). Cross-series duplicate
  policy is a product decision.
- manuel_straube is now a 2-album series; consider renaming to
  "Phineas und Ferb" with proper artist IDs or dropping it.
- nils_holgersson: Apple episodes are Kapitel-format (likely readings);
  series may deserve audiobook typing like the WWW Erstleser case.
- Excluded sub-series that could become catalog entries: Benjamin
  Blümchen Minis + Gute-Nacht-Geschichten, Olchi-Detektive, ???-Kids
  Mini-Fälle, Kugelblitz city Ratekrimis, Alea Aquarius, Hanni&Nanni
  2025 reboot.
- Audit overrides design decision (task #544) still open; data is
  reconciled but the code still records without applying.
