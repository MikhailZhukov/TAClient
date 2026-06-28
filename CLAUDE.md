# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TAClient — iOS/iPadOS client for [Tube Archivist](https://github.com/tubearchivist/tubearchivist), a self-hosted YouTube archiver. SwiftUI + MobileVLCKit for VP9 codec support. 104 app files + 1 Share Extension file, 53 test files, ~577 passing tests (excluding `testLaunchPerformance` — known XCUITest perf-metric flake unrelated to project code). Licensed under Apache-2.0 (MobileVLCKit remains under LGPL-2.1-or-later — see `NOTICE`).

## Build & Run

```bash
# Build (shell has persistent zsh parse error — always use /bin/bash -c)
/bin/bash -c 'xcodebuild build -scheme TAClient -destination "platform=iOS Simulator,name=iPhone 17 Pro"'

# Run tests
/bin/bash -c 'xcodebuild test -scheme TAClient -destination "platform=iOS Simulator,name=iPhone 17 Pro"'
```

- Xcode 26.2, **iOS 17.0 deployment target** (minimum: `@Observable`, `@Bindable`, new `.onChange` syntax)
- Swift 6 concurrency: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- String Catalog localization (en + ru) via `Localizable.xcstrings`
- SPM dependency: `MobileVLCKit-SPM` (`https://github.com/MobileVLCKit-SPM/MobileVLCKit-SPM`)
- FileSystemSynchronizedRootGroup — Xcode auto-detects new files, no need to add to project
- Bundle ID: `ru.mzhukov.TAClient`, display name: "TA Client"

## Apple Guidelines Compliance

This app targets App Store publication. **Strictly follow Apple Human Interface Guidelines:**

- **System colors only** — use `Color(.secondarySystemBackground)`, `Color(.tertiarySystemBackground)`, `.primary`, `.secondary`, etc. Never hardcode hex/RGB colors; all UI must adapt to Light and Dark Mode automatically
- **Dynamic Type** — use SwiftUI text styles (`.headline`, `.subheadline`, `.caption`, etc.), never hardcoded font sizes
- **Accessibility** — every interactive element must have `.accessibilityLabel()`. Use `Button` (not `.onTapGesture`) for tappable elements so VoiceOver announces them as buttons
- **Destructive actions** — always require confirmation via `.confirmationDialog()` (delete, logout, batch delete, etc.)
- **SF Symbols** — use system icons, not custom assets
- **Safe areas** — respect `safeAreaLayoutGuide` everywhere, especially on iPad
- **Localization** — all user-visible strings via `String(localized: "snake_case_key")`, both en and ru
- **Empty/Loading/Error states** — every screen must handle all three states
- **Privacy** — `PrivacyInfo.xcprivacy` manifest required; `Info.plist` with `NSAllowsArbitraryLoads` for user-provided server URLs

## Architecture

Clean Architecture with three layers, all under `TAClient/`:

```
Domain/    → Models (Video, Channel, Comment, DownloadItem, DownloadTaskInfo, PlayerInfo)
             Repository protocols (5), AppError, CodecSupport
Data/      → APIClient + APIEndpoint, DTOs (9), Mappers (5), KeychainService, AuthState,
             AuthProxy, StreamingSession, Repository impls (5)
Data/Cache → CacheStore (NSLock-guarded sync state), VideoCachePreloader (actor wrapping
             preload/download), CachingResourceLoader (AVAssetResourceLoaderDelegate)
Presentation/ → Views + @Observable ViewModels per screen (VideoList, VideoDetail, Search,
                ChannelDetail, DownloadQueue, Login, Splash), Common components, VLC player
DI/        → DependencyContainer (manual singleton)
```

**Separate target:** `ShareExtension/` — iOS Share Extension for adding YouTube videos to download queue from Share sheet.

**Data flow:** View → ViewModel → Repository (protocol) → APIClient → URLSession

**Key patterns:**
- `@Observable` ViewModels (iOS 17+) — no `@Published` needed
- `AppRouter` (@Observable) manages app state (splash → login → main), `NavigationStack` path via typed `Route` enum, cross-screen state sync (`deletedVideoIds`, `watchedChanges`), and `handleError()` helper for DRY error handling across all ViewModels
- `ImageCache` actor with `AuthenticatedAsyncImage` for auth'd image loading; negative result caching (60s cooldown) to prevent retry storms
- `AuthState` (@Observable) wraps Keychain reads/writes for token + serverURL
- Unauthorized (401/403) responses trigger `router.handleUnauthorized()` which clears Keychain and returns to login. Data-layer components (`VideoCachePreloader`, `CachingResourceLoader`) post `Notification.Name.taAuthUnauthorized` (defined in `Domain/Util/Notification+Names.swift`) instead of holding a router reference — `AppRouter` subscribes on init and routes the event through its idempotent `handleUnauthorized()`, preserving Clean Architecture boundaries
- `scenePhase` observer in `TAClientApp` forces window layout on `.active` — fixes stale safe area insets after iPad wake from sleep
- Deleted videos removed from all lists (VideoList, ChannelDetail, Search) via `AppRouter.deletedVideoIds` + `.onChange` observers — no full reload needed
- Watched state synced across screens via `AppRouter.watchedChanges: [String: Bool]` + `.onChange` observers
- Pagination deduplication — `loadMoreIfNeeded` filters out already-loaded items by `youtubeId` to prevent duplicates from API drift
- Optimistic UI updates with revert on error — used for watched toggle, subscribe toggle, download queue removal
- Filter-aware list updates — `removeIfFilterMismatch()` removes videos from list when watched state no longer matches active `watchFilter`

**ViewModel lifecycle in NavigationStack:**
- Each route in `TAClientApp.swift` uses a thin wrapper `<Feature>Screen` (e.g. `VideoDetailScreen`, `ChannelDetailScreen`, `PlaylistDetailScreen`, `VideoListScreen`, `SearchScreen`, `DownloadQueueScreen`, `PlaylistListScreen`, `SettingsScreen`, `LoginScreen`) instead of constructing the VM inline
- Wrapper signature: `init(make: () -> VM)` storing the result via `_viewModel = State(wrappedValue: make())`
- Why: SwiftUI re-evaluates the `navigationDestination` closure (and any container body) on every parent body re-render. An inline `viewModel: container.makeXVM()` constructs a new VM each re-eval, accumulating parallel VMs (confirmed bug — multiple `AVPlayer` instances saturating the connection pool, duplicate observers, `Buffer underrun` log lines fired 6× per event). The `@State`-stored wrapper persists the VM across re-evals tied to the same view identity — created once per push, torn down once per pop
- Invariant: VM `init` must remain side-effect-free (no `Task`s, no observers, no `AVPlayer` allocation, no network calls). The `make` closure still runs on every body re-eval; only the FIRST result becomes `@State` storage and the rest are discarded. Side effects belong in `.task {}` / `.onAppear` / explicit lifecycle methods on the leaf view
- Do NOT collapse the 9 named wrappers into a generic `VMOwningView<VM, Content>` — named types support per-screen `#Preview` blocks, the call site reads better in `TAClientApp.swift`, and the side-effect-free-init contract lives per-file as a comment near each wrapper for grep + code review
- Do NOT swap the explicit closure for `@autoclosure` — the explicit braces at the call site (`VideoDetailScreen { container.makeVideoDetailViewModel(videoId: videoId) }`) signal that construction is deferred and make the throwaway-init invariant visible at every use site
- Test coverage: `TAClientTests/WrapperLifecycleTests.swift` — factory-counting tests for each wrapper assert the factory closure is invoked exactly once per init (catches regressions where someone moves construction outside `_viewModel = State(wrappedValue: make())`, e.g. introducing a stored property `let viewModel = make()`)

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

## Share Extension

`ShareExtension/` is a separate Xcode target (`com.apple.product-type.app-extension`) embedded in the main app.

**Files:**
- `ShareViewController.swift` — self-contained: inline keychain read, YouTube URL validation, API call, SwiftUI overlay (spinner → checkmark/error → auto-dismiss)
- `Info.plist` — `NSExtensionActivationRule` inside `NSExtensionAttributes` (NOT directly in `NSExtension`), supports both URL and text sharing
- `ShareExtension.entitlements` — shared keychain access group
- `Localizable.xcstrings` — 5 error strings (en + ru)

**Keychain sharing:**
- Shared access group: `5AS4WKH94K.ru.mzhukov.TAClient` (both main app and extension entitlements)
- `KeychainService` uses `kSecAttrAccessGroup` on all queries via `baseQuery(for:)`
- Extension reads credentials directly via `SecItemCopyMatching` with same service/account/accessGroup

**pbxproj integration:**
- `PBXFileSystemSynchronizedBuildFileExceptionSet` excludes `Info.plist` from resource copying (avoids "Multiple commands produce Info.plist" conflict)
- `PBXCopyFilesBuildPhase` with `dstSubfolderSpec = 13` (PlugIns) embeds the `.appex`
- Extension build settings: `SKIP_INSTALL = YES`, `GENERATE_INFOPLIST_FILE = NO`

## API Details

- Server URL is user-provided and dynamic, stored in `AuthState`
- **2-step login:** POST `/api/user/login/` (returns session cookie) → GET `/api/appsettings/token/` (returns token). Login session cookies cleared after token retrieval to prevent stale cookies on re-login to different server
- Auth header on all subsequent requests: `Authorization: Token {token}`
- **CSRF gotcha:** API session must have `httpCookieStorage = nil` — otherwise the login session cookie leaks into API requests, Django uses `SessionAuthentication` instead of `TokenAuthentication`, and POST requests fail with 403 (CSRF required)
- All image/media URLs from API are **relative paths** — mappers prepend the server base URL
- Search param is `query` (not `q`): `GET /api/search/?query=X&page=N`
- Localization keys use `snake_case`; formatted dates use non-breaking spaces (`\u{00A0}`)
- `APIClient` uses a static `JSONDecoder` (not per-request allocation)
- `CachingResourceLoader.cachingURL(from:)` stores original URL scheme in fragment; `originalURL(from:)` restores it (not hardcoded "https")

**Important API data formats:**
- `player.progress` is **0–100** (percentage), NOT 0–1. The TA frontend uses it as CSS `width: ${progress}%`
- `youtube_id` in add-to-queue accepts **full YouTube URLs** (not just video IDs) — TA server parses them. The browser extension sends video IDs for individual videos, full URLs for channels
- TA accepts multiple URL formats: `youtube.com/watch?v=`, `youtu.be/`, `youtube.com/shorts/`, `youtube.com/live/`, channel URLs, playlist URLs
- Video type filter query param is `type` (NOT `vid_type`); response field is `vid_type`

**Endpoints:**
| Method | Path | Notes |
|--------|------|-------|
| POST | `/api/user/login/` | Step 1: returns session cookie |
| GET | `/api/appsettings/token/` | Step 2: returns `{"token": "..."}` |
| GET | `/api/ping/` | Health check, returns `{"response": "pong"}` |
| GET | `/api/video/?page=&sort=&order=&watch=&type=` | Video list with filters |
| GET | `/api/video/{id}/` | Video detail |
| POST | `/api/video/{id}/progress/` | Save progress `{"position": N}` (seconds) |
| DELETE | `/api/video/{id}/progress/` | Delete progress |
| DELETE | `/api/video/{id}/` | Delete video |
| GET | `/api/video/{id}/comment/` | Video comments |
| GET | `/api/video/{id}/similar/` | Similar videos (returns `[VideoDTO]` array) |
| GET | `/api/playlist/?page=&type=` | Playlist list (type: regular/custom) |
| GET | `/api/playlist/{id}/` | Playlist detail with entries |
| POST | `/api/playlist/{id}/` | Update subscription `{"playlist_subscribed": bool}` |
| POST | `/api/playlist/custom/` | Create custom playlist `{"playlist_name": "..."}` |
| POST | `/api/playlist/custom/{id}/` | Add/remove video `{"action": "create"/"remove", "video_id": "..."}` |
| DELETE | `/api/playlist/{id}/?delete_videos=` | Delete playlist |
| GET | `/api/user/account/` | User account (id, name, is_superuser, is_staff) |
| POST | `/api/task/by-name/update_subscribed/` | Rescan subscriptions |
| GET | `/api/search/?query=X&page=N` | Search (param is `query`, NOT `q`) |
| GET | `/api/channel/{id}/` | Channel detail |
| POST | `/api/channel/{id}/` | Update channel `{"channel_subscribed": bool}` |
| POST | `/api/watched/` | Set watched `{"id": "...", "is_watched": bool}` |
| GET | `/api/download/?page=&filter=` | Download queue |
| POST | `/api/download/{id}/` | Update download status |
| DELETE | `/api/download/{id}/` | Delete from queue |
| POST | `/api/download/` | Add to queue `{"data": [{"youtube_id": "X", "status": "pending"}]}` |
| POST | `/api/download/{id}/` | Ignore video `{"status": "ignore-force"}` |
| POST | `/api/task/by-name/download_pending/` | Start download |
| GET | `/api/task/by-name/download_pending/` | Download notifications |
| POST | `/api/task/by-id/{id}/` | Kill task `{"command": "stop"}` |

## Video Playback

Two player paths, selected automatically by `CodecSupport.requiredPlayer(for:)`:

- **AVPlayer** (default) — `AVPlayerViewController` via UIViewControllerRepresentable, inline in `VideoDetailView`. Handles H.264/H.265/AV1. Auth via `CachingResourceLoader` (custom `itacache://` URL scheme); fallback to `AVURLAssetHTTPHeaderFieldsKey` if URL conversion fails.
- **VLCKit** (fallback for VP8/VP9) — `VLCPlayerView` UIViewControllerRepresentable with `@Observable VLCPlayerState` + `VLCPlayerControls` SwiftUI overlay. Auth via `AuthProxy` (local NWListener HTTP proxy that injects `Authorization` header, since VLCKit doesn't support custom headers).

**Background audio + lock screen:**
- `ObserverBag` (`Presentation/VideoDetail/`) — thread-safe nonisolated bag that owns KVO + NotificationCenter tokens registered during AVPlayer setup. Lets `VideoDetailViewModel`'s nonisolated Swift 6 `deinit` tear observers down without a MainActor hop (both `NSKeyValueObservation.invalidate()` and `NotificationCenter.removeObserver(_:)` are thread-safe). `stopPlayback()` calls `tearDown()` on the normal path; `deinit` calls it again as a safety net (idempotent).
- `PlayerSessionCoordinator` (`Presentation/VideoDetail/`) — `@MainActor` class owning `AVAudioSession` activation + the three notification observers (interruption, routeChange, mediaServicesWereReset). VM wires callbacks (`onInterruptionBegan/Ended`, `onHeadphonesUnplugged`, `onAirPlayBecameActive`, `onMediaServicesReset`) in `startAVPlayback` and calls `coordinator.start()`; `stopPlayback` calls `coordinator.stop()` which deactivates the session with `.notifyOthersOnDeactivation` so Music/Podcasts resume. Category `.playback`/`.moviePlayback` is set once at `TAClientApp.init`; activation is deferred until playback actually starts.
- `NowPlayingController` (AVPlayer-only for now) — populates `MPNowPlayingInfoCenter` with title/artist/duration/elapsed/rate/artwork (loaded via `ImageCache`), registers targets on `MPRemoteCommandCenter.shared()` for play/pause/togglePlayPause/skipForward/skipBackward/changePlaybackPosition. `nextTrackCommand`/`previousTrackCommand` are explicitly disabled. Handlers return `MPRemoteCommandHandlerStatus` explicitly. VM calls `nowPlaying?.refresh()` from the 1s UI observer, after SponsorBlock skips, after interruption resume, and on `AVPlayerItemDidPlayToEndTime`. Controller is rebuilt when `sponsorBlockSettings.seekInterval` changes (triggered from `VideoDetailView` via `.onChange`). VLC Now Playing is future work.
- **AVPlayer error observation**: `AVPlayerItem.status` KVO + `AVPlayerItemFailedToPlayToEndTime` + `AVPlayerItemDidPlayToEndTime` notification observers feed `VideoDetailViewModel.handlePlaybackFailure(message:)` / `handleDidPlayToEnd()`. Failure sets `playbackError` (distinct from `errorMessage` which covers initial load) and returns to thumbnail + Retry button; end-of-playback forces a final `saveProgress` with `position == duration`.
- **Background continuation invariant** (load-bearing for App Store): `AVPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible` plus `AVPlayerViewController.canStartPictureInPictureAutomaticallyFromInline = true` and `allowsPictureInPicturePlayback = true`. Without `.continuesIfPossible` iOS suspends the app within ~5s of backgrounding even though the audio session is `.playback`. The policy must travel with the player on every swap — applied in both `makeUIViewController` and `updateUIViewController` (when `controller.player !== player`) via the `AVPlayerView.applyPlayerConfig(_:)` helper. Do NOT inline the assignment in only one path; the player swap path matters when the VM rebuilds the player after stop/start.
- **Tail-replay drift on fullscreen exit** (AVKit Replay-affordance workaround): when a video plays to natural end and the user dismisses fullscreen at the same moment, AVKit pre-seeks the AVPlayerItem back ~3-7s to prepare the system Replay button — leaving the player visibly resting on a frame from before duration. `AVPlayerView.Coordinator.shouldClampToEnd(didPlayToEnd:duration:status:)` predicate fires in the `willEnd` animation completion when `didPlayToEnd && status == .paused && duration > 0`, issuing `seek(to: itemDuration, .zero, .zero)` plus a single 150ms `DispatchQueue.main.asyncAfter` re-clamp guarded by `player.currentItem === item` identity, `duration2.seconds > 0`, and `.paused` status (race mitigation against AVKit's seek-back firing AFTER our seek). The `didPlayToEnd` flag is set by an `AVPlayerItemDidPlayToEndTime` observer and reset both when `observeEnd` rewires to a new item AND when an `AVPlayerItem.timeJumpedNotification` arrives that satisfies the `shouldClearEndFlag(currentTime:duration:)` predicate — true only when `currentTime < 1.0` (near zero). The threshold is deliberately a near-zero check, NOT `duration - 1.0`: production logs measured AVKit's seek-back drift at 4-8s before duration, so any "back from end" threshold would be defeated by the very pattern the clamp exists to fix. The Replay button always seeks to ~0; AVKit's drift never lands near 0; the near-zero check separates them cleanly.
- **Diagnostic-field init-time defaulting**: `VideoDetailViewModel.lastExplicitSeekAt: CFAbsoluteTime` defaults to `CFAbsoluteTimeGetCurrent()` (not `0`) at instance init AND on every `stopPlayback()` reset path. CFAbsoluteTime epoch is 2001-01-01, so a `= 0` default produced bogus `[TailReplay] sinceLastSeek=800005224.34s` (~25 years) diagnostic readings on videos starting at `startPosition == 0` and on stop→re-start cycles. Both sites must stay in sync — locked by `SeekTimestampInitTests`. Do NOT revert either site to `= 0` during v0.9.1 diagnostic cleanup.

**Streaming:**
- `StreamingSession` (`URLSessionDataDelegate`) — produces `AsyncThrowingStream<Data, Error>` chunks. Used by both `VideoCachePreloader` and `AuthProxy` instead of byte-by-byte `URLSession.AsyncBytes`
- **URLSession lifecycle invariant:** a delegate-based `URLSession(configuration:, delegate:, delegateQueue:)` strong-retains its delegate until invalidated — including when the task completes naturally, fails, or is cancelled. `StreamingSession.urlSession(_:task:didCompleteWithError:)` MUST call `finishTasksAndInvalidate()` on the local session reference (after nil'ing `self.session`) on every terminal path; without it the session's HTTP/2 connection cache plus the `StreamingSession` instance leak indefinitely. For delegate-less sessions used as one-shots (e.g. `VideoCachePreloader.downloadVideo`'s HEAD probe), use `defer { session.finishTasksAndInvalidate() }` immediately after construction so the lifetime is bound to the enclosing scope.

**In-memory video cache (`Data/Cache/`):**
- **Split architecture** (PR 6/7): `CacheStore` (`final class`, NSLock-guarded) owns all state — entry, chunks, `lastPlaybackOffset`, memory-pressure source. Sync API (`readData`, `writeChunk`, `cacheStatus`, `updatePlaybackPosition`, `trimFront`, `emergencyTrim`, `clear`) means `CachingResourceLoader` reads cache on AVPlayer's hot path with zero `await`s. `VideoCachePreloader` is an `actor` (singleton `.shared`) that wraps download/preload orchestration; it exposes a `nonisolated let store: CacheStore` so the loader can read directly via `VideoCachePreloader.shared.store.readData(...)`.
- **Two-region architecture**: each entry holds a `[RegionID: CacheRegion]` map keyed by `.prefix` and `.main`. The **prefix** region is pinned at `[0, N)` where `N = clamp(totalSize × 1%, 8MB, 50MB)` and survives both `.warning` and `.critical` memory pressure AND the `restartPreloadIfNeeded` → `downloadVideo` → `setEntry` chain that fires post-`.critical` (the latter via the idempotent `setEntry` short-circuit — see below). Only an explicit `store.clear()` drops it (the `.critical` policy was softened in `fix-memory-pressure-recovery` from `store.clear()` to `emergencyTrim(.main)`; see "Memory pressure split" below). The **main** region spans `[max(N, resumeByte), ∞)` and slides with playback as today (trim-front, emergency-trim, behind-margin all scoped to main). The preloader launches prefix and main downloads in parallel via `async let`. Why: a pinned cached moov atom (always within the prefix) prevents AVPlayer item-reload after scrub on resumed playback — root cause of the scrub-after-resume freeze where AVPlayer failed on a moov-range request, replaced `currentItem`, and stalled with the main region pointing far past byte 0.
- **Idempotent `setEntry`**: `CacheStore.setEntry(videoId:totalSize:contentType:resumeByte:)` is a no-op when `videoId`, `totalSize`, AND `contentType` all match the existing entry — regions, chunks, and `lastPlaybackOffset` are preserved. LOAD-BEARING for the `.critical` → `restartPreloadIfNeeded` → `startPreloadWithRetry` → `downloadVideo` chain: the restart hook calls `resetMainRegion(newStartOffset:)` first to re-anchor `.main` at the current playhead while keeping `.prefix` intact, then `downloadVideo` re-issues `setEntry` with identical `(videoId, totalSize, contentType)` from the HEAD probe. Without idempotency, that final `setEntry` allocates fresh empty regions and wipes the `~26 MB` prefix bytes the soft-`.critical` policy preserved — opening a multi-second moov-cache-miss window where AVPlayer's moov-range request falls through to the network and a coincident scrub re-triggers the scrub-after-resume freeze the two-region architecture exists to prevent. A `resumeByte` change alone is NOT enough to bust the cache; the caller must use `resetMainRegion` for anchor changes, not a fresh `setEntry`. A `contentType` mismatch still busts the cache (different MIME → different bytes). Tests: `CacheStoreTests.setEntry_idempotent_whenSameVideoIdTotalSizeContentType_preservesRegions` + `setEntry_sameVideoIdAndTotalSize_butDifferentContentType_replaces` (unit) and `VideoCachePreloaderTests.restartPreloadIfNeeded_afterCritical_preservesPrefixBytes` (integration).
- **Region accessors**: `store.cacheStatus(videoId:)` returns the `.main` region status only and is `nil` for small files (where only prefix exists, `totalSize <= prefixSize`) or after an explicit `clear()` before re-seeding. Callers that need prefix or want a generic "is region X populated" check MUST use `regionStatus(videoId:region:)` explicitly. The loader's `fillContentInfo` falls back to `regionStatus(.prefix)` because content-info needs only `totalSize`/`contentType`, both entry-scoped; the preloader's fast-path requires BOTH `.prefix` and `.main` populated before skipping (a prior explicit `clear()` may have wiped prefix).
- **Per-task failure isolation in `downloadVideo`**: each of `prefixResult`/`mainResult` async lets is awaited inside its own do/catch, so a 503 / auth failure / transport error in one region does not propagate to the sibling task. The store's per-region `writeChunk(videoId:toRegion:)` keeps writes scoped — main's auto-trim never touches prefix bytes.
- **Generation-guarded clear**: `downloadVideo` captures the preloader's `preloadGeneration` at spawn; the empty-cache `store.clear()` at the end of `downloadVideo` runs ONLY when `generation == preloadGeneration`. Otherwise a newer `startPreloadWithRetry` for the same `videoId` that already cancelled this attempt and seeded a fresh entry would be wiped by the orphan task's terminal clear.
- **Degenerate-range guards**: `CacheStore.setEntry` clamps `resumeByte` into `[0, totalSize]` and skips creating `.main` when `clampedResumeByte >= totalSize` (small file / EOF resume); `VideoCachePreloader.downloadVideo` does the same clamp before constructing `mainStartByte..<totalSize` so Swift's `Range` cannot trap on a corrupted/rounded-past-end resume.
- **Pause gate is per-region**: only the `.main` download task observes `pauseThreshold` and calls `trimFront`. Summing both regions would let the `.main` task fill past pauseThreshold while playback sits at byte 0 (no trim leverage) and deadlock the `.prefix` task in its Task.sleep loop forever — prefix has no trim mechanism of its own and is bounded by `maxPrefixSize = 50MB ≪ pauseThreshold = 384MB` so it can never trip the gate on its own.
- `CachingResourceLoader` (`AVAssetResourceLoaderDelegate`, must be `nonisolated`) — serves AVPlayer byte-range requests from `store`, falls back to network (16MB cap per request). Tracks in-flight tasks in `activeTasks` under an `NSLock`; `resourceLoader(_:didCancel:)` cancels the matching task. Invalidates its `URLSession` in `deinit`. Implements preloader-catches-up grace window (`coverSoonWindow = 8MB`, up to 3× 200ms sleeps) before falling through to network when the preloader is active and close to serving the requested offset.
- Preload starts on `loadVideo()` before user presses play; uses `startPosition`/`duration` to seek via HTTP Range header
- Preload has retry with exponential backoff (1s, 2s) on transient network errors
- Sliding window: 256MB max cache, trim at 282MB, pause download at 384MB, 30MB behind-margin for keyframe refs
- Trim position tracked from ViewModel's time observer — NOT from resource loader reads (AVPlayer read-ahead would cause trim overshoot)
- All cache URLSessions use `httpCookieStorage = nil` + `urlCache = nil`
- HEAD probe runs unconditionally in `VideoCachePreloader.probeTotalSize` (called by `downloadVideo` for every preload — we always need `totalSize` to compute the prefix/main boundary, not just when resuming); the delegate-less probe session is short-lived and bound by `defer { headSession.finishTasksAndInvalidate() }` immediately after construction so cleanup runs on every exit path including the early 401/403 return
- AVPlayer appetite caps set in `VideoDetailViewModel.startAVPlayback` via the `configurePlayerItemAppetite(_:)` helper (centralizes both settings; tested in `AVPlayerItemConfigurationTests`): `preferredForwardBufferDuration = 10` limits AVPlayer's internal forward buffer since we manage our own 256MB cache (was 30; lowered to defeat the 4K AV1 spike). `preferredPeakBitRate = 25_000_000` (25 Mbps) caps the byte-fetch appetite — AVPlayer's `observedBitrate` mis-measures as multi-Gbps during the first HTTPS chunks of a single-rendition stream and pre-fetches aggressively in response; 25 Mbps covers 4K AV1's typical 12-20 Mbps sustained envelope with VBR headroom while still capping the bogus-Gbps measurement. Without these caps a real-device test measured ~3.89 GB RSS during initial buffering.
- Memory pressure split: `.warning` → `store.emergencyTrim(targetSize: maxCacheSize / 2)` (surgical, preload keeps running, **prefix is pinned through `.warning`** — only main is trimmed); `.critical` → `store.emergencyTrim(targetSize: 8MB)` + cancel in-flight preload (softened from the previous `store.clear()` policy as of `fix-memory-pressure-recovery`). The entry itself survives — videoId, totalSize, contentType, and `lastPlaybackOffset` are preserved — so the restart-preload-after-clear contract below has something to recover from. Prefix is still pinned through `.critical` (only main is trimmed). The cache-data loss is compensated by the restart hook, which rebuilds main from the current playhead once the spike subsides (see below). **Load-bearing 8 MB target**: the restart hook only fires when `.main` cached count is strictly less than `RestartTrigger.mainCachedByteThreshold` (16 MB); the 8 MB trim target guarantees post-`.critical` cache sits below the restart threshold so the next post-cooldown 1Hz tick can dispatch. A higher target (e.g. 64 MB) would leave the cache permanently stalled at the trim target because the restart predicate would return `false` forever.
- **Reseed contract for large scrubs — trigger**: the VM's 1Hz time observer (`VideoDetailViewModel.swift`, inside `registerPlayerObservers`) evaluates `ReseedTrigger.shouldReseed` — a seconds-space comparison with a 30s VBR guard band — to detect playback landing outside `.main` (forward scrub past `endOffset` OR backward scrub before `startOffset`). On out-of-bounds main, it dispatches `VideoCachePreloader.reseedMain(videoId:atByte:url:token:)` as a fire-and-forget Task hop. Seconds-space comparison sidesteps VBR linear-interpolation error: the same `avgByterate = totalSize / duration` slop appears on both sides of the inequality, and the 30s guard absorbs it. The orphan-reseed guard (`preloadTask != nil`) is load-bearing because `cancelPreload` nils `preloadTask` WITHOUT clearing the store entry, so `store.currentVideoId() == videoId` alone would still match after the user navigated away in `stopPlayback`; the pair check is the actual "is there a live preload to follow?" signal. AirPlay skips reseed entirely at the evaluator level (`isUsingDirectAsset` early-bail) because the AirPlay path reads directly from the server URL and bypasses the local cache.
- **Reseed orchestration (actor)**: the actor drains every live `preloadTask` via a `while let` loop (justification in code comments at `reseedMain`), bumps `preloadGeneration`, calls `store.resetMainRegion(videoId:newStartOffset:)`, and respawns the download from the new anchor via `downloadRange(into: .main, ...)`. Post-drain the actor re-checks `store.currentVideoId() == videoId` and re-reads `regionStatus(.main)` — the pre-drain snapshot is stale because peer actor methods may have mutated the store during the suspension. **Only `.main` is reset; `.prefix` is preserved** so AVPlayer's moov re-reads after scrub still hit the cache (the prefix-region invariant from `20260510-fix-prefix-cache-region.md` is unaffected).
- **Reseed debounce + URL/token snapshot**: a 2s debounce + 10MB target-similarity guard on the VM side (`progressStateLock`-protected `lastReseedAt` / `lastReseedTargetByte`) prevents rapid-scrub thrash; the debounce timestamps advance **only inside the lock and only when the `streamingURL`/`authToken` pair-check passes**, so a `stopPlayback`-cleared snapshot mid-tick cannot silently consume the debounce window. URL + token are snapshotted at TWO sites — `configureAsset` (covers AVPlayer / caching-loader / first AirPlay start) AND `handleAirPlayBecameActive` (covers the runtime route-change AirPlay swap that bypasses `configureAsset` by rebuilding the AVURLAsset against the existing player) — so reseed always dispatches with the auth context of the currently-playing asset; stale-token-at-reseed → 401 → existing `.taAuthUnauthorized` path.
- **Reseed logs (PERMANENT)**: `[Reseed]` tag is **NOT** in the v0.9.1 cleanup bucket. Two emitters: `[Reseed] main reset @byte=N (was [start..end))` signals a true wipe-and-rebuild of `.main`; `[Reseed] main keep @byte=N (was [start..end)) for {id} — already anchored` signals the backward-into-prefix short-circuit where the clamped target equals the existing `.main.startOffset` (the existing region already satisfies the caller's intent — discarding bytes would be pure waste).
- **Restart contract for memory-pressure recovery — trigger**: the VM's 1Hz time observer (`VideoDetailViewModel.swift`, inside `registerPlayerObservers`) evaluates `RestartTrigger.shouldRestart` — a pure-function predicate that returns true when `.main`'s cached byte count is below 16MB AND at least 15s have elapsed since the last restart attempt. On true, the observer dispatches `VideoCachePreloader.restartPreloadIfNeeded(videoId:url:token:startPosition:duration:)` as a fire-and-forget Task hop. The hook is **idempotent** — the preloader no-ops if a preload is already in flight, if no entry exists for the videoId, or if the computed byte offset is at/past `totalSize`. The cooldown lives solely on the VM side (`lastRestartAt` under `progressStateLock`); the preloader trusts the VM to throttle. AirPlay skips restart entirely at the evaluator level (`isUsingDirectAsset` early-bail) for the same reason reseed does — direct-asset playback bypasses the cache.
- **Restart orchestration (actor)**: `restartPreloadIfNeeded` first calls `store.resetMainRegion(videoId:newStartOffset: byteForStartPosition)` to drop any post-`.critical`-trim leftover bytes that are at the wrong anchor (without this, `startPreloadWithRetry`'s internal `isCacheSufficient` check could short-circuit on stale-anchored cache and silently no-op). It then calls `startPreloadWithRetry(...)` from the **current playhead position** (NOT byte 0) — restart rebuilds main where the user actually is, not where the original `loadVideo` started. The bytes sacrificed by the `resetMainRegion` (at most `criticalTrimTargetBytes`, currently 8 MB) are an acceptable cost — they were at the wrong anchor anyway.
- **Restart + reseed compose**: the two hooks are independent and complementary. Restart rebuilds the region when it's been emptied or destroyed (post-`.critical` recovery, or any other path that leaves main thin). Reseed re-anchors the region when the user scrubs far outside main's current `[startOffset, endOffset)`. Reseed requires main to exist (`preloadTask != nil` orphan guard); restart bootstraps that precondition by recreating main after a `.critical` trim. Without restart, the new reseed-trigger would bail forever after `.critical` because `regionStatus(.main)` would stay `nil`.
- 401/403 from the preloader download or the loader network fallback posts `.taAuthUnauthorized` (see API Details).

**Important — do NOT:**
- Set `automaticallyWaitsToMinimizeStalling` on AVPlayer — caused playback issues
- Track playback offset from `readData()` — AVPlayer read-ahead advances ~45MB past actual playback, trim removes needed data
- Restart preload from resource loader byte offsets — AVPlayer metadata requests (moov at byte 0) look like seeks but aren't
- Use single contiguous `Data` buffer for cache — `removeSubrange` does memmove of ~370MB; use chunked `[Data]` instead
- Use byte-by-byte `URLSession.AsyncBytes` for streaming — use `StreamingSession` (chunk-based `URLSessionDataDelegate`) instead
- Construct a delegate-based `URLSession` without invalidating it on every terminal path — URLSession strong-retains the delegate; missing invalidate leaks the session, its HTTP/2 connection cache, and the delegate object indefinitely (see URLSession lifecycle invariant under Streaming above)

**VLC details:**
- `AuthProxy`: actor, NWListener on port 0, per-request `StreamingSession` (no shared URLSession)
- Set `newConnectionHandler` BEFORE `listener.start()`, monitor `stateUpdateHandler` for auto-restart on `.failed`
- VLC controls: `@Observable VLCPlayerState` shared between `VLCPlayerContainerVC` and `VLCPlayerControls` SwiftUI view — controls created once, SwiftUI handles granular updates automatically (no `refreshControls()`/`makeControls()` rebuilds)
- UIHostingController intercepts all touches — handle taps in SwiftUI layer (`Color.clear.contentShape(Rectangle()).onTapGesture`)
- VLC fullscreen: modal `VLCFullScreenVC` reparents BOTH drawable view (`insertSubview(at: 0)`) AND controls host view
- Both inline and fullscreen controls constrained to `safeAreaLayoutGuide`
- Progress saved every 10s; VLC also saves on stop via `lastVLCPosition`
- VLC restarts media only on `.error` state (NOT `.ended`) — restarting on `.ended` causes infinite loop of last seconds

**Temporary diagnostic instrumentation (slated for v0.9.1 cleanup):**
- `VideoDetailViewModel` and `VideoDetailView` carry a set of diagnostic helpers added during the VM-recreation freeze investigation: `tailObserver`, `freezeWatchdogTask`, `recordSeek` / `detectBackwardJump`, `observeAVLogs`, `logVideoFormat`, fullscreen lifecycle logs, plus several `.info → .notice` log-level promotions. These tag log lines with `[Tail]`, `[Freeze]`, `[TailReplay]`, `[Seek]`, `[Format]`, `[AVAccess]`, `[AVError]`, `[Fullscreen]`.
- They proved the VM-recreation antipattern in production logs (`Buffer underrun` × 6, parallel `pts=` reads in distant byte regions of the same MP4) and surfaced a separate tail-replay bug at end-of-stream on fullscreen exit.
- They are intentionally retained on `main` for now so the next TestFlight build can confirm the wrapper fix in the wild, and so the tail-replay mini-fix can use the same telemetry. **Removal is tracked in a separate cleanup plan** before App Store v0.9.1 submission — do not extend or repurpose this instrumentation without owning the cleanup task.
- **`[Reseed]` is PERMANENT** — NOT part of the v0.9.1 cleanup bucket. The reseed log line (emitted by `VideoCachePreloader.reseedMain`) is load-bearing telemetry for the large-scrub-follow contract (see "In-memory video cache" above) and stays in production logs alongside the existing memory-pressure / auth markers.
- **`[Mem]` and `[Restart]` are PERMANENT** — NOT part of the v0.9.1 cleanup bucket. The `[Mem]` markers (emitted by `VideoCachePreloader.handleMemoryPressure`, `downloadVideo` start/complete, and `VideoDetailViewModel.startAVPlayback` + `logCacheHealth`) capture resident-memory snapshots at the key inflection points used by the memory-pressure recovery contract (`fix-memory-pressure-recovery`); the `[Restart]` marker (emitted by `VideoCachePreloader.restartPreloadIfNeeded`) records the 1Hz-observer-driven preload restart after `.critical` trims. Both are operational telemetry for diagnosing memory regressions in production and stay in shipping logs.

**Test-only seams (PERMANENT — separate category, NOT in the v0.9.1 cleanup bucket):**
- `VideoDetailViewModel.setDirectAssetState(_:)` — internal setter exposed via `@testable import TAClient` so `ReseedDispatchEvaluationTests` can flip `isUsingDirectAsset` without wiring a real AirPlay session. Writes under `progressStateLock` to match the production contract.
- `VideoDetailViewModel.snapshotPlaybackContext(...)` and `evaluateReseedDispatch(...)` are `internal` (not `private`) for the same reason — direct test access via `@testable import` avoids the need for a shim layer.
- Treat these as a permanent test-API surface, not as diagnostic instrumentation. Rename only with a corresponding test update; do not remove during diagnostic-instrumentation cleanup.

## User Privileges

Privilege-based UI gating — admin features hidden for non-privileged users.

- `GET /api/user/account/` fetched after login and auto-login, stored in `AuthState.isPrivileged`
- `isPrivileged = isSuperuser || isStaff`
- Gated UI: delete video/playlist, subscribe/unsubscribe channel, batch delete, download queue add/start/swipe actions, rescan subscriptions
- Non-privileged users see read-only UI — browse videos, watch, manage custom playlists

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

## iPad

- All screens wrapped in `NavigationStack` for proper safe area handling
- VLC controls constrained to `safeAreaLayoutGuide` in both inline and fullscreen modes
- **Wake from sleep fix:** `scenePhase == .active` triggers `forceLayoutUpdate()` on all windows — recalculates safe area insets that go stale after device sleep in landscape

## Testing

**~577 tests, all passing** (excluding `testLaunchPerformance` — known XCUITest perf-metric flake unrelated to project code). Swift Testing framework (`@Test`, `#expect()`) — NOT XCTest.

Phase counts below are approximate scope buckets, not exact tallies — suites have grown organically and a number of cross-cutting suites (`AppRouterTests`, `AuthStateTests`, `NotificationTests`, `SponsorBlock*Tests`, `UserPrivilegesTests`, `PlayerGestureTests`, `SimilarVideosTests`, several ViewModel suites, etc.) cover behaviour spanning multiple phases. Only the ~577 total is canonical.

| Phase | Tests | Scope |
|-------|-------|-------|
| 1 ✅ | ~58 | Pure logic: mappers, codecs, errors, date formatting |
| 2 ✅ | ~71 | ViewModels + services with closure-based mock repos |
| 3 ✅ | ~79 | Data layer: APIClient, endpoints, all repository impls via MockURLProtocol |
| 4 ✅ | ~130 | Playback + cache: `CacheStoreTests` (32+ sync-API tests, incl. 9 `resetMain_*` cases for the preloader-reseed contract — replaces, clamps below prefix, clamps at/above totalSize, wrongVideoId noop, missingEntry noop, doesNotResetLastPlaybackOffset, clampedEqualsPreviousStart preserves main, clampedAboveStart still wipes, smallFileNoMain noop), `CacheStoreStressTests` (concurrent readers/writer + `resetMain_concurrentWithWrite_noCorruption` under `@Suite(.serialized)`), `CachingResourceLoaderTests`, `CacheAuthFailureTests` (401/403 → `.taAuthUnauthorized`), `VideoCachePreloaderTests` (baseline + memory pressure + HEAD-probe success and HEAD-probe 401 + 10 `reseedMain_*` cases — resetsMainRegion, downloadsCorrectRange, wrongVideoId noop, atByteAtOrAboveTotal noop, noMainRegion noop, oldTaskCompletionDoesNotClobber, afterCancelPreload noop, backwardIntoPrefix preservesMain, postReseedBytesAreFromNewRange byte-content verification, loaderGraceWindowStillFires), `PlayerSessionCoordinatorTests`, `NowPlayingControllerTests`, `ObserverBagTests`, `StreamingSessionTests`, `ReseedTriggerTests` (14 cases on pure `shouldReseed` / `shouldDebounce` decision logic), `SnapshotPlaybackContextTests` (5 cases pinning the `streamingURL` / `authToken` locked-write helper), `ReseedDispatchEvaluationTests` (8 cases on the `evaluateReseedDispatch` seam — debounce, nil-guard, paused-scrub, inside-main, no-region) |
| 5 ✅ | ~52 | Navigation lifecycle + Coordinator state machine: `WrapperLifecycleTests` — factory-counting tests for each `*Screen` wrapper (one-shot + two-instance) defending the screen-wrapper structural contract; `FullscreenExitGuardTests` — 7 `shouldResumePlayback` cases + 9 `shouldClampToEnd` cases (boolean predicate matrix: end signal × duration validity (incl. negative) × time control status, plus mutual-exclusivity sanity check vs `shouldResumePlayback` with positive-coverage anchors so a regression that drove BOTH predicates to `false` everywhere would fail); `ShouldClearEndFlagTests` — 11 cases for the `timeJumpedNotification`-driven `didPlayToEnd` reset predicate covering Replay-to-zero (clear), AVKit drift-back-from-end at 4-8s (KEEP — load-bearing because AVKit's drift is precisely what `shouldClampToEnd` exists to fix), threshold boundary at 1.0, mid-playback, plus defensive shape (NaN / zero / negative / infinite duration, NaN currentTime); `CoordinatorEndFlagWiringTests` — Mirror-reflection tests for the `didPlayToEnd` flag mutation paths (initial false, set on `AVPlayerItemDidPlayToEndTime`, reset on `observeEnd` rewire); `SeekTimestampInitTests` — 4 cases for the init invariant (Mirror over `nonisolated(unsafe)` storage) plus the static `resetExplicitSeekTimestamp()` helper (the `stopPlayback()` reset path's testable seam) |

**Test infrastructure:**
- `Mocks.swift` — closure-based mock repositories + `TestData` factory (supports `startIndex` for pagination dedup tests)
- `MockURLProtocol.swift` — URLProtocol subclass + `MockResponse` helpers for Phase 3. Two handler modes: the default `requestHandler` returns a single response/data tuple, and `slowStreamHandler` (used by `StreamingSessionTests`) emits a sequence of `Data` chunks with a configurable delay between them, honouring a `stopped` flag that `stopLoading()` flips so a consumer's mid-stream cancel pre-empts natural completion (otherwise the URLSession→delegate cancel path is never exercised)
- `DataLayerSuite.swift` — `@Suite(.serialized)` parent for all Phase 3 tests (shared static state)
- `CacheStoreStressTests` — also uses `@Suite(.serialized)`; 10 concurrent readers + 1 writer via `Task.detached` exercise the `CacheStore` NSLock invariants

**Key gotchas:**
- `URL.path` strips trailing slashes — assert with `contains("/api/video/vid1/progress")` not `/progress/`
- URLProtocol strips `httpBody`; read from `httpBodyStream` via helper
- Use `nonisolated(unsafe)` static vars for `MockURLProtocol.lastRequest` — avoids MainActor isolation issues
- Verify request properties via `MockURLProtocol.lastRequest` after await (not closure-captured objects — MainActor isolation prevents cross-thread writes to implicitly-isolated classes)
- Keychain is shared across parallel tests — don't test keychain roundtrip; verify in-memory state only
- `-only-testing:` with nested Swift Testing suite IDs may not match individual tests; may report vacuous success
- Need `import SwiftUI` for `NavigationPath` access, `import Foundation` for `URL`/`URLError`
