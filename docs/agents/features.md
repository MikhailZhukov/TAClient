# Feature Docs: Video List, Channel Detail, Playlists, SponsorBlock

## Video List Features

**Video type filter** (`VidTypeFilter` enum):
- Toolbar title is a `Menu` with chevron — tapping shows Videos/Shorts/Streams/All options
- API query param is `type` (NOT `vid_type` — `vid_type` is the response field name)
- `setVidType()` creates its own `Task` inside the ViewModel — do NOT create `Task` in Menu button action (gets cancelled on menu dismiss)
- No `.onChange` handler for vidTypeFilter — only `setVidType()` triggers reload (prevents double-firing)

**Sort & filter** (`SortFilterMenu`):
- Compact toolbar Menu with sort options, order toggle, watch filter
- `.onChange` handlers on `sortOption`, `sortAscending`, `watchFilter` trigger `onSortOrFilterChanged()`
- SwiftUI `Picker` inside `Menu` doesn't work reliably on iPad — use explicit `Button` with checkmark `Label` instead

**Multi-select batch operations:**
- Long press enters selection mode (first video auto-selected); context menu hidden during selection
- `AdaptiveVideoGrid` shows checkmark overlay on selected cards, tap toggles selection
- Selection toolbar: count (`.principal`), watched/unwatched/delete/select-all/cancel (`.topBarTrailing`)
- Watched/unwatched buttons shown conditionally based on active watch filter (`showMarkWatched`/`showMarkUnwatched`)
- Batch delete requires `.confirmationDialog()` confirmation
- Deselecting all videos exits selection mode automatically
- Works on VideoListView and ChannelDetailView

**SwiftUI gotchas:**
- `.contextMenu` intercepts long press before `.onLongPressGesture` — use conditional view modifier (`.if()`) to apply only one
- `.adaptive` LazyVGrid has known rotation animation artifact on first orientation change — `.geometryGroup()` on ScrollView is the best mitigation but doesn't fully eliminate it
- Do NOT use `.transaction { $0.animation = nil }` on images — causes massive layout delay (10+ seconds for column recount)

## Channel Detail Features

- Subscribe/unsubscribe button with optimistic toggle + revert on error
- Multi-select batch operations (same as video list)
- Watched state changes notify router via `markWatchedChanged()` for cross-screen sync

## Playlists

Full CRUD for regular (YouTube) and custom (user-created) playlists.

- Toolbar button (`music.note.list`) on VideoListView → PlaylistListView
- Filter by type: All / Regular / Custom via toolbar menu
- Create custom playlists via "+" button (alert with text field)
- PlaylistDetailView shows header (thumbnail, name, channel, type, subscribe button) + video grid via `AdaptiveVideoGrid`
- Delete playlist with option to keep or delete videos (confirmation dialog)
- Optimistic subscribe/unsubscribe toggle with revert on error
- Custom playlists: add/remove videos via `POST /api/playlist/custom/{id}/` with `action: "create"/"remove"`
- Playlist videos fetched via existing `/api/video/?playlist={id}` endpoint

## SponsorBlock

Automatic skip of sponsor segments and other non-content sections during playback.

- Data comes from `GET /api/video/{id}/` → `sponsorblock` field (when enabled on TA server)
- 8 categories: sponsor, selfpromo, interaction, intro, outro, preview, hook, filler
- Only `actionType == "skip"` segments are mapped; `mute` and others are filtered out
- `SponsorBlockSettings` (@Observable, UserDefaults) — master toggle + per-category toggles
- AVPlayer: 1-second periodic time observer checks current time against active segments
- VLC: check runs on every `onVLCTimeChanged` (1s frequency), seek target passed via `sponsorBlockSeekTarget` parameter
- Skip notification banner with "Undo" button — auto-dismisses after 5 seconds
- Undo removes segment from `skippedSegmentIds`, allowing re-skip on re-entry
- Settings screen accessible from VideoListView toolbar (gear icon) → Route `.settings`
