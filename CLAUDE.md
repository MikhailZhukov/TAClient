# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TAClient — iOS/iPadOS client for [Tube Archivist](https://github.com/tubearchivist/tubearchivist), a self-hosted YouTube archiver. SwiftUI + MobileVLCKit for VP9 codec support. 69 app files + 1 Share Extension file, 26 test files, 188 passing tests. Renamed from iTubeArchivist.

## Build & Run

```bash
# Build (shell has persistent zsh parse error — always use /bin/bash -c)
/bin/bash -c 'xcodebuild build -scheme TAClient -destination "platform=iOS Simulator,name=iPhone 17 Pro"'

# Run tests
/bin/bash -c 'xcodebuild test -scheme TAClient -destination "platform=iOS Simulator,name=iPhone 17 Pro"'
```

- Xcode 26.2, iOS 26.2 deployment target
- Swift concurrency: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- String Catalog localization (en + ru) via `Localizable.xcstrings`
- SPM dependency: `MobileVLCKit-SPM` (`https://github.com/MobileVLCKit-SPM/MobileVLCKit-SPM`)
- FileSystemSynchronizedRootGroup — Xcode auto-detects new files, no need to add to project
- Bundle ID: `ru.mzhukov.TAClient`, display name: "TA Client"

## Architecture

Clean Architecture with three layers, all under `TAClient/`:

```
Domain/    → Models (Video, Channel, Comment, DownloadItem, DownloadTaskInfo, PlayerInfo)
             Repository protocols (5), AppError, CodecSupport
Data/      → APIClient + APIEndpoint, DTOs (8), Mappers (5), KeychainService, AuthState,
             AuthProxy, Repository impls (5)
Data/Cache → VideoCache (in-memory sliding window), CachingResourceLoader (AVAssetResourceLoaderDelegate)
Presentation/ → Views + @Observable ViewModels per screen (VideoList, VideoDetail, Search,
                ChannelDetail, DownloadQueue, Login, Splash), Common components, VLC player
DI/        → DependencyContainer (manual singleton)
```

**Separate target:** `ShareExtension/` — iOS Share Extension for adding YouTube videos to download queue from Share sheet.

**Data flow:** View → ViewModel → Repository (protocol) → APIClient → URLSession

**Key patterns:**
- `@Observable` ViewModels (iOS 17+) — no `@Published` needed
- `AppRouter` (@Observable) manages app state (splash → login → main), `NavigationStack` path via typed `Route` enum, and `deletedVideoIds` for cross-screen video removal
- `ImageCache` actor with `AuthenticatedAsyncImage` for auth'd image loading
- `AuthState` (@Observable) wraps Keychain reads/writes for token + serverURL
- Unauthorized (401/403) responses trigger `router.handleUnauthorized()` which clears Keychain and returns to login
- `scenePhase` observer in `TAClientApp` forces window layout on `.active` — fixes stale safe area insets after iPad wake from sleep
- Deleted videos removed from all lists (VideoList, ChannelDetail, Search) via `AppRouter.deletedVideoIds` + `.onChange` observers — no full reload needed

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
- **2-step login:** POST `/api/user/login/` (returns session cookie) → GET `/api/appsettings/token/` (returns token)
- Auth header on all subsequent requests: `Authorization: Token {token}`
- **CSRF gotcha:** API session must have `httpCookieStorage = nil` — otherwise the login session cookie leaks into API requests, Django uses `SessionAuthentication` instead of `TokenAuthentication`, and POST requests fail with 403 (CSRF required)
- All image/media URLs from API are **relative paths** — mappers prepend the server base URL
- Search param is `query` (not `q`): `GET /api/search/?query=X&page=N`
- Localization keys use `snake_case`; formatted dates use non-breaking spaces (`\u{00A0}`)

**Important API data formats:**
- `player.progress` is **0–100** (percentage), NOT 0–1. The TA frontend uses it as CSS `width: ${progress}%`
- `youtube_id` in add-to-queue accepts **full YouTube URLs** (not just video IDs) — TA server parses them. The browser extension sends video IDs for individual videos, full URLs for channels
- TA accepts multiple URL formats: `youtube.com/watch?v=`, `youtu.be/`, `youtube.com/shorts/`, `youtube.com/live/`, channel URLs, playlist URLs

**Endpoints:**
| Method | Path | Notes |
|--------|------|-------|
| POST | `/api/user/login/` | Step 1: returns session cookie |
| GET | `/api/appsettings/token/` | Step 2: returns `{"token": "..."}` |
| GET | `/api/ping/` | Health check, returns `{"response": "pong"}` |
| GET | `/api/video/?page=&sort=&order=&watch=&channel=` | Video list with filters |
| GET | `/api/video/{id}/` | Video detail |
| POST | `/api/video/{id}/progress/` | Save progress `{"position": N}` (seconds) |
| DELETE | `/api/video/{id}/progress/` | Delete progress |
| DELETE | `/api/video/{id}/` | Delete video |
| GET | `/api/video/{id}/comment/` | Video comments |
| GET | `/api/search/?query=X&page=N` | Search (param is `query`, NOT `q`) |
| GET | `/api/channel/{id}/` | Channel detail |
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
- **VLCKit** (fallback for VP8/VP9) — `VLCPlayerView` UIViewControllerRepresentable with custom `VLCPlayerControls` SwiftUI overlay. Auth via `AuthProxy` (local NWListener HTTP proxy that injects `Authorization` header, since VLCKit doesn't support custom headers).

**In-memory video cache (`Data/Cache/`):**
- `VideoCache` actor singleton — sliding window of 512KB `[Data]` chunks, single video at a time
- `CachingResourceLoader` (`AVAssetResourceLoaderDelegate`) — serves AVPlayer byte-range requests from cache, falls back to network (16MB cap per request)
- Preload starts on `loadVideo()` before user presses play; uses `startPosition`/`duration` to seek via HTTP Range header
- Sliding window: 256MB max cache, trim at 282MB, pause download at 384MB, 30MB behind-margin for keyframe refs
- Trim position tracked from ViewModel's time observer (every 10s) — NOT from resource loader reads (AVPlayer read-ahead would cause trim overshoot)
- All cache URLSessions use `httpCookieStorage = nil` + `urlCache = nil`

**Important — do NOT:**
- Set `automaticallyWaitsToMinimizeStalling` or `preferredForwardBufferDuration` on AVPlayer — both caused playback issues
- Track playback offset from `readData()` — AVPlayer read-ahead advances ~45MB past actual playback, trim removes needed data
- Restart preload from resource loader byte offsets — AVPlayer metadata requests (moov at byte 0) look like seeks but aren't
- Use single contiguous `Data` buffer for cache — `removeSubrange` does memmove of ~370MB; use chunked `[Data]` instead

**VLC details:**
- `AuthProxy`: actor, NWListener on port 0, set `newConnectionHandler` BEFORE `listener.start()`, auto-restarts on `.failed`
- VLC controls: UIHostingController intercepts all touches — handle taps in SwiftUI layer (`Color.clear.contentShape(Rectangle()).onTapGesture`)
- VLC fullscreen: modal `VLCFullScreenVC` reparents BOTH drawable view (`insertSubview(at: 0)`) AND controls host view
- Both inline and fullscreen controls constrained to `safeAreaLayoutGuide`
- Progress saved every 10s; VLC also saves on stop via `lastVLCPosition`
- VLC restarts media only on `.error` state (NOT `.ended`) — restarting on `.ended` causes infinite loop of last seconds

## iPad

- All screens wrapped in `NavigationStack` for proper safe area handling
- VLC controls constrained to `safeAreaLayoutGuide` in both inline and fullscreen modes
- **Wake from sleep fix:** `scenePhase == .active` triggers `forceLayoutUpdate()` on all windows — recalculates safe area insets that go stale after device sleep in landscape

## Testing

**188 tests, all passing.** Swift Testing framework (`@Test`, `#expect()`) — NOT XCTest.

| Phase | Tests | Scope |
|-------|-------|-------|
| 1 ✅ | 58 | Pure logic: mappers, codecs, errors, date formatting |
| 2 ✅ | 51 | ViewModels + services with closure-based mock repos |
| 3 ✅ | 79 | Data layer: APIClient, endpoints, all repository impls via MockURLProtocol |
| 4 ❌ | — | Integration: VideoCache, CachingResourceLoader, ImageCache, KeychainService |

**Test infrastructure:**
- `Mocks.swift` — closure-based mock repositories + `TestData` factory for Phase 2
- `MockURLProtocol.swift` — URLProtocol subclass + `MockResponse` helpers for Phase 3
- `DataLayerSuite.swift` — `@Suite(.serialized)` parent for all Phase 3 tests (shared static state)

**Key gotchas:**
- `URL.path` strips trailing slashes in iOS 26.2 — assert with `contains("/api/video/vid1/progress")` not `/progress/`
- URLProtocol strips `httpBody`; read from `httpBodyStream` via helper
- Use `nonisolated(unsafe)` static vars for `MockURLProtocol.lastRequest` — avoids MainActor isolation issues
- Verify request properties via `MockURLProtocol.lastRequest` after await (not closure-captured objects — MainActor isolation prevents cross-thread writes to implicitly-isolated classes)
- Keychain is shared across parallel tests — don't test keychain roundtrip; verify in-memory state only
- `-only-testing:` with nested Swift Testing suite IDs may not match individual tests; may report vacuous success
- Need `import SwiftUI` for `NavigationPath` access, `import Foundation` for `URL`/`URLError`
