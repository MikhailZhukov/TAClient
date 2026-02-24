# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

iOS/iPadOS client for [Tube Archivist](https://github.com/tubearchivist/tubearchivist), a self-hosted YouTube archiver. SwiftUI + MobileVLCKit for VP9 codec support.

## Build & Run

```bash
# Build (shell has persistent zsh parse error — always use /bin/bash -c)
/bin/bash -c 'xcodebuild build -scheme iTubeArchivist -destination "platform=iOS Simulator,name=iPhone 17 Pro"'

# Run tests
/bin/bash -c 'xcodebuild test -scheme iTubeArchivist -destination "platform=iOS Simulator,name=iPhone 17 Pro"'
```

- Xcode 26.2, iOS 26.2 deployment target
- Swift concurrency: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- String Catalog localization (en + ru) via `Localizable.xcstrings`
- SPM dependency: `MobileVLCKit-SPM` (`https://github.com/MobileVLCKit-SPM/MobileVLCKit-SPM`)

## Architecture

Clean Architecture with three layers, all under `iTubeArchivist/`:

```
Domain/    → Models, Repository protocols, AppError, CodecSupport
Data/      → APIClient, DTOs, Mappers (DTO→Model), KeychainService, AuthState, AuthProxy, Repository impls
Data/Cache → VideoCache (in-memory sliding window), CachingResourceLoader (AVAssetResourceLoaderDelegate)
Presentation/ → Views + @Observable ViewModels per screen, Common components
DI/        → DependencyContainer (manual singleton)
```

**Data flow:** View → ViewModel → Repository (protocol) → APIClient → URLSession

**Key patterns:**
- `@Observable` ViewModels (iOS 17+) — no `@Published` needed
- `AppRouter` (@Observable) manages app state (splash → login → main) and `NavigationStack` path via typed `Route` enum
- `ImageCache` actor with `AuthenticatedAsyncImage` for auth'd image loading
- `AuthState` (@Observable) wraps Keychain reads/writes for token + serverURL
- Unauthorized (401/403) responses trigger `router.handleUnauthorized()` which clears Keychain and returns to login

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
- Do NOT set `automaticallyWaitsToMinimizeStalling` or `preferredForwardBufferDuration` on AVPlayer — both caused playback issues

**Key details:**
- `CodecSupport` only routes VP8/VP9 video codecs to VLC — AV1 and opus are AVPlayer-supported
- `AuthProxy` is an actor using Network.framework `NWListener` on port 0 (OS-assigned). Must set `newConnectionHandler` BEFORE `listener.start()`
- VLC controls: UIHostingController intercepts all touches — tap handling must be in SwiftUI layer (`Color.clear.contentShape(Rectangle()).onTapGesture`)
- VLC fullscreen: modal `VLCFullScreenVC` reparents BOTH drawable view (`insertSubview(at: 0)`) AND controls host view
- Progress saved every 10s; VLC also saves on stop via `lastVLCPosition`

## API Details

- Server URL is user-provided and dynamic
- **2-step login:** POST `/api/user/login/` (returns session cookie) → GET `/api/appsettings/token/` (returns token)
- Auth header on all subsequent requests: `Authorization: Token {token}`
- **CSRF gotcha:** API session must have `httpCookieStorage = nil` — otherwise the login session cookie leaks into API requests, Django uses `SessionAuthentication` instead of `TokenAuthentication`, and POST requests fail with 403 (CSRF required)
- All image/media URLs from API are **relative paths** — mappers prepend the server base URL
- Search param is `query` (not `q`): `GET /api/search/?query=X&page=N`
- Localization keys use `snake_case`; formatted dates use non-breaking spaces (`\u{00A0}`)
