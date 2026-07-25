# Split Proposal Decisions — Round 2

47 pending proposals reviewed against `split_guidelines.md` (2026-07).
Of the 87 entries `catalog-splits list` shows, 21 already have their child
series and 19 have zero albums; this round covers the rest.

Recommendations by Claude, decisions pending Chris.

## A. Accept — create new series (18)

| Parent :: label | Albums | Guideline | Reasoning |
|---|---|---|---|
| benjamin_bluemchen :: benjamin_minis | 16 | §1 age bracket | "Benjamin Minis" Folge 1-8, short format for younger kids, own numbering, cross-provider |
| benjamin_bluemchen :: finds_raus | 30 | distinct product line | "Find's raus mit Benjamin" educational line, 15 titles per provider |
| benjamin_bluemchen :: gute_nacht_geschichten | 74 | distinct product line | Bedtime line with own Folge 1-37 numbering, collides with parent numbering |
| benjamin_bluemchen :: tv_serie | 4 | distinct product line | "Hörspiele zur TV-Serie" launched 2026; same shape as petronella/ritter_rost tv_serie |
| die_drei_fragezeichen_kids :: mini_fall | 16 | §1 short format | Mini-Fall 01-08 with own numbering, ~half the runtime of regular Kids episodes |
| die_olchis :: olchi_detektive | 24 | distinct product line | "Olchi-Detektive" 1-20, own brand and numbering, parents search by name |
| die_schluempfe :: kinofilm | 6 | §2 films | 3 theatrical films × 2 providers, explicit Kinofilm branding |
| petronella_apfelmus :: erstleser | 10 | §1 age bracket | Erstleser Teil 1-4. Dedupe the Spotify duplicate copies; move the AM "Überraschungsfest für Lucius" (= Erstleser Teil 1, per audit) from parent into the child |
| petronella_apfelmus :: tv_serie | 36 | distinct product line | Teil 1-12 TV bundles, 3 stories per release. Dedupe Spotify duplicate copies |
| ritter_rost :: tv_serie | 24 | distinct product line | "Hörspiel zur TV-Serie" Folge 1-12, 4 TV episodes per disc |
| ritter_rost :: radio_schrottland | 18 | §3 format | Radio-show format (moderation, songs, word games), 9 themes × 2 providers. Consider content_type music |
| lego_city :: tv_serie | 50 | distinct product line | TV tie-in Folge 1-27 colliding with main numbering. Drop the two "Folgen 1-5"/"6-10" Sammelbände (exclude as compilation, don't move) |
| woodwalkers :: seawalkers | 12 | §4 standalone | Separate property in the same universe; parents search "Seawalkers" |
| woodwalkers :: woodwalkers_friends | 1 | §4 standalone | "Woodwalkers & Friends" companion line, first release 2026, will grow; without a child the excluded album is lost content |
| teufelskicker :: wissen | 32 | distinct product line | WM/EM/Frauen-WM-Wissen, publisher-marketed separate Staffel, numbering collision 1-5 |
| conni :: conni_co_kinofilm | 4 | §2 films | Two "Conni & Co" films × 2 providers; parent currently ships film 1 but not film 2 (inconsistent) |
| bobo_siebenschlaefer :: bobo_und_hasi | 3 | §1 age bracket | "Bobo & Hasi ... für ganz Kleine" spin-off, 2 titles 2023/2025 |
| mira_und_das_fliegende_haus :: traumreise + kindermeditation + mira_show | 27 | §3 format | Meditation/talk formats, not Hörspiel episodes. See open question E4 on how many children |

## B. Reject — stays in parent (7)

| Parent :: label | Albums | Reasoning |
|---|---|---|
| die_drei_ausrufezeichen :: kinofilm | 2 | One film cross-provider; §2 says keep a single film in the parent |
| kung_fu_panda :: winter_special | 2 | Sonderfolge, belongs in parent with episode_num=null |
| der_kleine_wassermann :: Mühlenweiher | 4 | Seasonal picture-book Hörspiele of the same character; parent has no numbered browsing to disrupt; splitting risks a graveyard |
| kalle_blomquist :: hörspielklassiker | 3 | The 1946/51 radio dramas ARE the core content (golden rule); eras handle generations |
| lauras_stern_laura :: numbered | 2 | Over-fragmentation of an already-broken child; fix via re-curation instead |
| lauras_stern_laura :: story_releases | 6 | Same; the Laura child needs a proper re-curation (AM side has counterparts under new IDs) |
| eule :: Hauptserie (Musik-Hörspiele) | 8 | The 4 Musik-Hörspiele are the parent's core content (golden rule) |

## C. Clear — documentation noise, no split (11)

Self-referential facts on split children, or proposals whose own reason
says they're obsolete. Remove the sub_series entries so `splits list`
stays trustworthy.

- die_biene_maja_kinofilm :: Kinofilm-Hörspiele (describes itself)
- feuerwehrmann_sam_film_hoerspiele :: Film Hörspiele (itself)
- fuenf_freunde_adventskalender :: adventskalender_format (pattern doc)
- haende_weg_von_mississippi :: standalone (itself)
- hexe_lilli_erstlesergeschichten :: double_episodes (format doc)
- janosch_kinofilm :: kinofilm_audio_plays (itself)
- mia_and_me_buch :: Hörspiele zum Buch (itself)
- pumuckl_weihnachten :: Weihnachten (itself)
- kommissar_kugelblitz :: hoerbuch (reason literally says "REMOVED")
- cornelia_funke :: haende_weg_von_mississippi_verified (child exists)
- trolljaeger :: dragons (misattributed DreamWorks content, already excluded; content lives in the dragons_* series)

## D. Merge / data-fix — overlaps existing series (3 clusters)

1. **cornelia_funke :: wilde_huehner + wilde_huehner_modern** — not a
   new series; `die_wilden_huehner` exists standalone. Move the 5 modern
   Folge 1-5 (2022/23 Atmende Bücher) + AM Folge 2 into it after overlap
   check. The 2007 film Hörspiel needs external verification (the
   Kapitel heuristic already produced one false positive), then goes to
   die_wilden_huehner or stays excluded. This closes the cornelia_funke
   escalation.
2. **der_kleine_rabe_socke :: film_sub_series** — child
   der_kleine_rabe_socke_movie exists; verify the 2 Spotify film albums
   are in it, then clear the fact.
3. **drachenreiter :: sequels + movie_tie-in** — single albums stay in
   the drachenreiter child (§2). But: verify "Die Vulkan-Mission"
   (umbrella audit says machine-generated audiobook, 31 tracks × exactly
   3:00 — if confirmed, exclude from the child too). The film Hörspiel
   is verified genuine (JUMBO press release); umbrella exclusion stands
   but its reason should be sub_series_bleed, not wrong_content_type.

## E. Open decisions for Chris (4)

1. **kalle_blomquist :: hörbuch-neuausgabe (2)** — §5 says multiple
   Hörbuch titles → split (as audiobook-typed series, liliane_susewind
   precedent). But the parent's Apple Music side then has zero albums.
   Split, or exclude the two audiobooks?
2. **lego_ninjago :: graphic_novel_hoerbuch (12)** — Band 01-12 narrated
   graphic-novel audiobooks, currently excluded. Accept as an
   audiobook-typed series (Ninjago fans would use it) or leave excluded?
3. **benjamin_bluemchen :: englisch_lernen (2)** — one title
   cross-provider. bibi_blocksberg_englisch_lernen exists as precedent
   (10 albums). Create a 1-album child for symmetry, or leave excluded
   until the line grows?
4. **mira meditation formats** — one merged child ("Mira Entspannung"),
   or three per product branding (Traumreise / Wolkenwunderland
   Kindermeditation / MiRA SHOW)? Three matches how parents see the
   products; one keeps the catalog lean.
