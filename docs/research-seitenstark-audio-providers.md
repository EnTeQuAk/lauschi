# Research: Seitenstark Audio Content Providers

Source: https://seitenstark.de/kinder/kinderseiten
Date: 2025-02-25

## Summary

Most kids audio content in the DACH market flows through ARD Audiothek.
The seitenstark network has ~60 kids sites, but only a handful offer
audio content, and most of those are already on ARD Audiothek (which
we already integrate with).

**One genuinely independent source worth pursuing: Ohrka.**

## Already Covered by ARD Audiothek Integration

These are all accessible via our existing `ArdApi`:

| Show | Broadcaster | ARD Audiothek ID | Content |
|------|-------------|------------------|---------|
| Wunderwigwam | HR2 | 85587130 | Wissenspodcast, Grundschulalter |
| Kakadu (Podcast) | DLF Kultur | 30c22e3f2fc00769 | Kinderpodcast |
| Kakadu (Hörspiel) | DLF Kultur | 0be48d23cb060826 | Kinderhörspiele |
| CheckPod | BR | (on platform) | Checker Tobi Podcast |
| MausHörspiel | WDR | 36244846 | Die Maus Hörspiele |
| Gute Nacht mit der Maus | WDR | (on platform) | Einschlafgeschichten |
| Mikado Kinderhörspiel | NDR | 2ecc6d47de08d01e | Hörspiele ab 6 |
| Hörspielklassiker für Kinder | ARD | a98eaa600a311568 | Klassiker |

**No new integration needed.** Just catalog these shows so parents can
find and subscribe to them.

## Ohrka (ohrka.de) — Worth Pursuing

**What:** 150 Hörabenteuer, 100+ hours. Read by prominent actors (Anke
Engelke, Oliver Rohrbeck/Die drei ???, David Nathan/Johnny Depp, 
Katharina Thalbach). Classics: Dschungelbuch, Alice im Wunderland,
Robinson Crusoe, Schatzinsel, Grimm Märchen. Free, ad-free, nonprofit.

**Quality:** Extremely high. Government-funded (BMFSFJ, BKM, bpb).
Seitenstark-Gütesiegel certified. Read by A-list German voice actors.

**Technical:** TYPO3 CMS. No API, no RSS feed. MP3 files hosted at
predictable paths: `ohrka.de/fileadmin/audio/{story}/{file}.mp3`.
Static catalog (150 items, no new content being added, existing content
is permanent).

**Integration options:**
1. **Scrape + static catalog** — Catalog all 150 items with their MP3
   URLs in a local YAML/JSON. Content is static (no new episodes), so
   no sync needed. Just a one-time catalog build.
2. **Contact for partnership** — Ohrka e.V. is a small nonprofit
   (Michael Schulte, Berlin). They're donation-dependent. Could propose:
   "We'd like to make your content available in our kids audio player.
   We'll link back to ohrka.de and encourage donations."
3. **RSS feed request** — Ask if they'd add an RSS feed to their TYPO3
   site. Low effort for them, makes integration cleaner.

**Recommendation:** Contact them. They're a nonprofit that wants reach.
A kids audio player surfacing their content is aligned with their
mission. The static MP3 hosting means integration is trivial once we
have permission.

**Contact:** OHRKA e.V., Michael Schulte, Bornstr. 24, 12163 Berlin

## Not Relevant for Integration

| Site | Why Not |
|------|---------|
| Junge Klassik | Educational about music, not an audio library |
| Kidspods | Workshop-produced content by kids, small catalog |
| Die Gürbels | Text stories for reading aloud, no audio files |
| Auditorix | Sound effects library for schools, not stories |
| Haste Töne | Kid-produced media, Hamburg-local |
| Kinderfunkkolleg | Educational audio, on ARD Audiothek anyway |

## Broader Landscape (Beyond Seitenstark)

Worth noting: the WDR kids division (kinder.wdr.de) publishes podcast
RSS feeds directly:
- `kinder.wdr.de/radio/diemaus/audio/maushoerspiel-lang/*.podcast`
- `kinder.wdr.de/radio/diemaus/audio/gute-nacht-mit-der-maus/*.podcast`

These overlap with ARD Audiothek content. Not a separate provider, but
the RSS feeds could be useful for subscription sync if the ARD API's
change-detection isn't granular enough.

## Next Steps

1. Add the ARD kids shows above to our catalog/browse for discovery
2. Contact Ohrka e.V. about integration
3. Consider a generic "podcast RSS" provider for future expansion
   (would cover any podcast feed, not just ARD)
