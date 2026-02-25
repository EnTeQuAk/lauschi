# Design: Content Subscriptions & Expiration

Tickets: #142 (Subscriptions), #143 (Expiration)

## Context

ARD episodes expire (endDate). Spotify content is permanent but series
release new episodes. Both need lifecycle management.

## Implementation Order

1. **#143 Expiration** first (acute pain, prerequisite for subscriptions)
2. **#142 Subscriptions** builds on expiration infrastructure

---

## #143: Expiration

### Data

TileItem already has `availableUntil` (nullable DateTime). ARD items
set this from `endDate`. Spotify items leave it null (permanent).

No schema changes needed. Just need to:
- Populate `availableUntil` when adding ARD items
- Filter on it in kid-facing queries
- Refresh it on sync (ARD sometimes extends availability)

### Kid home screen

Query filters: `WHERE available_until IS NULL OR available_until > now()`

- Tile shows count of *available* items only
- If all items expired + active subscription: greyed tile, "New stories
  coming soon" (calendar badge)
- If all items expired + no subscription: tile hidden from kid grid
  (still visible in parent dashboard)

### Player

- Before play: check `availableUntil`. If expired, show friendly screen:
  "This story flew away 🐦" with illustration. No error messages.
- During play (404 from audio URL): catch, show same screen, save final
  position to DB.
- NowPlayingBar: if last-played item expired, greyed out. Tap opens
  expired message.

### Parent dashboard

- Expired items: grey overlay, "Expired [date]" badge
- "Expires in 7 days" warning on soon-to-expire items
- Bulk action: "Clean up expired" (hard delete from tile)

### Position preservation

- `isHeard`, `lastPositionMs`, `lastTrackUri` stay in DB after expiration
- If ARD re-publishes same episode (same external ID, new endDate),
  upsert restores previous listening state

---

## #142: Subscriptions

### Subscription scope

- **ARD**: subscribe to programSet (show level). Clean boundary.
- **Spotify**: subscribe to catalog series (series.yaml ID). Catalog
  matching is the quality gate.
- **Non-catalog Spotify content**: manual add only, no auto-subscribe.
  MVP limitation, acceptable because the catalog is expandable.

The data model is provider-agnostic. The sync engine branches on
provider.

### Schema: ShowSubscriptions table

```dart
@DataClassName('ShowSubscription')
class ShowSubscriptions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get provider => text()();
  // ARD: programSet ID. Spotify: catalog series ID (e.g. 'tkkg')
  TextColumn get externalShowId => text()();
  TextColumn get title => text()();
  TextColumn get coverUrl => text().nullable()();
  // FK to Tile
  TextColumn get groupId =>
      text().references(Groups, #id, onDelete: KeyAction.cascade)();
  // Null = no cap (Spotify). 20 = default for ARD rolling shows.
  IntColumn get maxEpisodes => integer().nullable()();
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();
  // ARD: programSet.lastItemAdded. Spotify: most recent album date.
  DateTimeColumn get remoteLastItemAdded => dateTime().nullable()();
  TextColumn get status =>
      text().withDefault(const Constant('active'))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();

  @override
  List<String> get customConstraints => [
    'UNIQUE (group_id, provider, external_show_id)',
  ];
}
```

### Deduplication

Dedup key: `(groupId, provider, providerUri)`.

Upsert logic: if item exists in tile with same provider+URI, update
metadata (title, cover, availableUntil, duration) but preserve user
state (isHeard, lastPositionMs, lastPlayedAt). If item doesn't exist,
insert.

### Sync algorithm

**Triggers:**
- App foreground: sync subscriptions stale > 6 hours
- Pull-to-refresh in parent dashboard
- Manual "Sync now" per subscription
- Future: background sync (WorkManager / BGFetch)

**ARD path:**
1. Fetch programSet, compare lastItemAdded vs stored
2. If changed, fetch items (paginated, up to maxEpisodes)
3. Upsert each item (refreshes availableUntil for existing items)
4. Evict excess items if over maxEpisodes (oldest first, skip if
   played in last 7 days)

**Spotify path:**
1. Look up catalog series by externalShowId
2. Get artist IDs from catalog
3. Fetch albums by artist IDs, filter to after remoteLastItemAdded
4. Run CatalogService.match() on each album
5. Only insert if match.series.id == subscribed series (strict)
6. Update remoteLastItemAdded to most recent album date

### Eviction (ARD only)

When new episode arrives and tile is at maxEpisodes:
1. Candidates: items sorted by publishDate ASC
2. Skip items with lastPlayedAt within 7 days
3. Hard delete oldest candidate
4. If all candidates protected, exceed cap temporarily

Spotify tiles don't evict. Content is permanent.

### Kid-facing tile UX

- Tile cover: series artwork (not episode cover)
- Sort: episodeNumber ASC for numbered series, publishDate DESC for
  rolling shows
- "New" badge: pill on tile if unplayed items added in last 7 days
- Eviction: episodes "fly away" naturally (ARD). Kid learns this.

### Parent UX flow

**Subscribe from catalog browse:**
1. Parent opens "Add content" > browses official series
2. Taps "Subscribe to TKKG"
3. Chooses target tile (existing or new)
4. Initial sync runs immediately
5. Shows "12 episodes added to 'Bedtime Stories'"

**Subscribe from ARD browse:**
1. Parent opens ARD Audiothek section
2. Taps "Subscribe" on Ohrenbär
3. Chooses target tile
4. Syncs most recent 20 episodes

**Non-catalog Spotify content:**
- "Add album" only, no Subscribe option
- Small nudge: "Request this series for auto-updates"

**Managing subscriptions:**
- Parent dashboard > Subscriptions tab
- Shows: title, provider badge, target tile, last sync, status
- Actions: sync now, pause, unsubscribe
- Unsubscribe keeps existing items (parent can bulk-delete separately)

### Migration

- On upgrade, scan existing tiles
- If items share same externalShowId or match a catalog series,
  suggest subscription: "You have 8 TKKG episodes. Enable auto-sync?"
- Opt-in only. Never auto-create subscriptions.

---

## Open Questions

1. **Soft delete vs hard delete for evicted items?** Hard delete for
   MVP. Soft delete adds complexity for little benefit.
2. **Spotify maxEpisodes?** Probably not needed. Spotify content is
   permanent. Parents expect persistent libraries.
3. **Manual add + sync overlap?** Upsert handles dedup. Sync title
   wins over manual title (canonical).
4. **Subscription status visible to kids?** No. Kids see static
   content. Sync is invisible infrastructure.
5. **"Request series" flow?** GitHub issue template? In-app feedback?
   Defer to post-MVP.
