# Spotify Search API — Filtering for Kids Content

Investigation for #87.

## Spotify Search API Capabilities

### Query field filters (prefix operators in `q` parameter)

The Spotify `/v1/search` endpoint supports these field filters in the query string:

- `album:` — filter by album name
- `artist:` — filter by artist name
- `year:` — filter by release year (e.g., `year:2020` or `year:2018-2024`)
- `genre:` — filter by genre tag
- `tag:new` — recently released (roughly 2 weeks)
- `tag:hipster` — low-discovery albums

**No kids/children-specific filter exists.** There's no `tag:kids`, `category:children`, or `content_rating` field.

### Album type (`album_type` / `album_group`)

The search response includes `album_type` with values:
- `album` — full album
- `single` — single or EP
- `compilation` — compilation

This does **not** distinguish Hörspiele from music. A TKKG episode and a Taylor Swift album are both `album_type: album`.

### Genre tags

Spotify genres are artist-level, not album-level. Relevant genres that exist:
- `kindermusik` (German children's music)
- `kinderhoerspiel` (German audio plays)
- `children's music`
- `audiobook`

The `genre:kinderhoerspiel` filter works in search queries but has limitations:
- Only matches artists tagged with that genre, not individual albums
- Coverage is inconsistent — not all Hörspiel artists are tagged
- Doesn't help for playlist search (playlists don't have genres)

### Practical search strategies

**For Hörspiele (current approach — already working):**
The catalog-based matching (`CatalogService.match()`) is more reliable than API filtering. The curated `series.yaml` with keyword + artist ID matching catches content that genre filters miss.

**For music (the gap):**
- `genre:kindermusik` can be appended to music search queries to bias results
- But it's too restrictive — excludes valid kids content not tagged with that genre
- Senta's music, for example, might not be tagged `kindermusik`

**For playlists:**
- No genre filtering available
- Search query alone determines results
- Adding "kinder" or "kids" to queries is the only option

## Recommendation

1. **Don't add genre filtering to search** — it's too unreliable and restrictive
2. **Do add `album_type` to the model** — useful for UI hints (show "Single" badge)
3. **Current approach is correct**: curated catalog for Hörspiele, free search for music
4. **Future**: consider a "Für Kinder" toggle that appends `genre:kindermusik` or `genre:kinderhoerspiel` to the query as a soft filter, with clear UX that it narrows results

## Changes Made

None — research-only. The current search implementation is appropriate.
