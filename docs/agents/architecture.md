# Architecture

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

**Separate target:** `ShareExtension/` — iOS Share Extension for adding YouTube videos to download queue from Share sheet (see [share-extension.md](share-extension.md)).

**Data flow:** View → ViewModel → Repository (protocol) → APIClient → URLSession

## Key patterns

- `@Observable` ViewModels (iOS 17+) — no `@Published` needed
- `AppRouter` (@Observable) manages app state (splash → login → main / unavailable reconnect), `NavigationStack` path via typed `Route` enum, cross-screen state sync (`deletedVideoIds`, `watchedChanges`), and `handleError()` helper for DRY error handling across all ViewModels
- `ImageCache` actor with `AuthenticatedAsyncImage` for auth'd image loading; negative result caching (60s cooldown) to prevent retry storms
- `AuthState` (@Observable) wraps Keychain reads/writes for token + serverURL
- A 401 (or 403 the ping probe proves is a dead token) triggers `router.handleUnauthorized()` which clears Keychain and returns to login; a 403 with a live token surfaces as an `AppError.permissionDenied` banner without logout (see [session-resilience.md](session-resilience.md)). Data-layer components (`VideoCachePreloader`, `CachingResourceLoader`) post `Notification.Name.taAuthUnauthorized` (defined in `Domain/Util/Notification+Names.swift`) instead of holding a router reference — `AppRouter` subscribes on init and routes the event through its idempotent `handleUnauthorized()`, preserving Clean Architecture boundaries
- `scenePhase` observer in `TAClientApp` forces window layout on `.active` — fixes stale safe area insets after iPad wake from sleep
- Deleted videos removed from all lists (VideoList, ChannelDetail, Search) via `AppRouter.deletedVideoIds` + `.onChange` observers — no full reload needed
- Watched state synced across screens via `AppRouter.watchedChanges: [String: Bool]` + `.onChange` observers
- Pagination deduplication — `loadMoreIfNeeded` filters out already-loaded items by `youtubeId` to prevent duplicates from API drift
- Optimistic UI updates with revert on error — used for watched toggle, subscribe toggle, download queue removal
- Filter-aware list updates — `removeIfFilterMismatch()` removes videos from list when watched state no longer matches active `watchFilter`

## ViewModel lifecycle in NavigationStack

Each route in `TAClientApp.swift` uses a thin wrapper `<Feature>Screen` (e.g. `VideoDetailScreen`, `ChannelDetailScreen`, `PlaylistDetailScreen`, `VideoListScreen`, `SearchScreen`, `DownloadQueueScreen`, `PlaylistListScreen`, `SettingsScreen`, `LoginScreen`) instead of constructing the VM inline.

- Wrapper signature: `init(make: () -> VM)` storing the result via `_viewModel = State(wrappedValue: make())`
- Why: SwiftUI re-evaluates the `navigationDestination` closure (and any container body) on every parent body re-render. An inline `viewModel: container.makeXVM()` constructs a new VM each re-eval, accumulating parallel VMs (confirmed bug — multiple `AVPlayer` instances saturating the connection pool, duplicate observers, `Buffer underrun` log lines fired 6× per event). The `@State`-stored wrapper persists the VM across re-evals tied to the same view identity — created once per push, torn down once per pop
- Invariant: VM `init` must remain side-effect-free (no `Task`s, no observers, no `AVPlayer` allocation, no network calls). The `make` closure still runs on every body re-eval; only the FIRST result becomes `@State` storage and the rest are discarded. Side effects belong in `.task {}` / `.onAppear` / explicit lifecycle methods on the leaf view
- Do NOT collapse the 9 named wrappers into a generic `VMOwningView<VM, Content>` — named types support per-screen `#Preview` blocks, the call site reads better in `TAClientApp.swift`, and the side-effect-free-init contract lives per-file as a comment near each wrapper for grep + code review
- Do NOT swap the explicit closure for `@autoclosure` — the explicit braces at the call site (`VideoDetailScreen { container.makeVideoDetailViewModel(videoId: videoId) }`) signal that construction is deferred and make the throwaway-init invariant visible at every use site
- Test coverage: `TAClientTests/WrapperLifecycleTests.swift` — factory-counting tests for each wrapper assert the factory closure is invoked exactly once per init (catches regressions where someone moves construction outside `_viewModel = State(wrappedValue: make())`, e.g. introducing a stored property `let viewModel = make()`)

## User Privileges

Privilege-based UI gating — admin features hidden for non-privileged users.

- `GET /api/user/account/` fetched after login and auto-login, stored in `AuthState.isPrivileged`
- `isPrivileged = isSuperuser || isStaff`
- Gated UI: delete video/playlist, subscribe/unsubscribe channel, batch delete, download queue add/start/swipe actions, rescan subscriptions
- Non-privileged users see read-only UI — browse videos, watch, manage custom playlists

## iPad

- All screens wrapped in `NavigationStack` for proper safe area handling
- VLC controls constrained to `safeAreaLayoutGuide` in both inline and fullscreen modes
- **Wake from sleep fix:** `scenePhase == .active` triggers `forceLayoutUpdate()` on all windows — recalculates safe area insets that go stale after device sleep in landscape
