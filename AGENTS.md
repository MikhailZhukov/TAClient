# AGENTS.md

Guidance for AI coding agents in this repository. Deep-dive material lives in
[`docs/agents/`](docs/agents/) — **read the relevant file before modifying that area**;
the invariants there are load-bearing and were learned from production bugs.

## Project Overview

TAClient — iOS/iPadOS client for [Tube Archivist](https://github.com/tubearchivist/tubearchivist),
a self-hosted YouTube archiver. SwiftUI + MobileVLCKit for VP9 codec support.
109 app files + 1 Share Extension file, 62 test files, ~730 tests (per `@Test` attribute count;
confirm passing count with the full suite run). Licensed under Apache-2.0 (MobileVLCKit remains
under LGPL-2.1-or-later — see `NOTICE`).

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

## Ground Rules

The app targets App Store publication. **Strictly follow Apple Human Interface Guidelines:**

- **System colors only** — `Color(.secondarySystemBackground)`, `.primary`, `.secondary`, etc. Never hardcode hex/RGB; UI must adapt to Light/Dark Mode automatically
- **Dynamic Type** — SwiftUI text styles (`.headline`, `.subheadline`, `.caption`…), never hardcoded font sizes
- **Accessibility** — `.accessibilityLabel()` on interactive elements; use `Button` (not `.onTapGesture`) so VoiceOver announces buttons
- **Destructive actions** — always `.confirmationDialog()` (delete, logout, batch delete…)
- **SF Symbols** only (no custom icons), respect safe areas, all three screen states (Empty/Loading/Error)
- **Localization** — every user-visible string via `String(localized: "snake_case_key")`, en + ru; `PrivacyInfo.xcprivacy` manifest required; `Info.plist` keeps `NSAllowsArbitraryLoads` for user-provided server URLs

Testing & conventions:

- Swift Testing (`@Test`, `#expect()`) — NOT XCTest; `testLaunchPerformance` is a known XCUITest flake
- **Keychain is shared across parallel tests** — never test keychain roundtrips; verify in-memory state only
- `URL.path` strips trailing slashes; URLProtocol strips `httpBody` (read `httpBodyStream`)
- Reuse existing patterns; clean cutover (no dead code, shims, or compatibility aliases)
- Commit style: conventional commits (`feat:`, `fix:`, `docs:`, `chore:`) — see git history

## Architecture at a Glance

Clean Architecture under `TAClient/`: `Domain/` (models, repository protocols, AppError) →
`Data/` (APIClient + DTOs + mappers, KeychainService, AuthState, AuthProxy, StreamingSession;
`Data/Cache/` = CacheStore + VideoCachePreloader + CachingResourceLoader) → `Presentation/`
(@Observable ViewModels + SwiftUI views) → `DI/DependencyContainer` (manual singleton).
Separate target: `ShareExtension/`. Data flow: View → ViewModel → Repository → APIClient → URLSession.

Cross-cutting: `AppRouter` (@Observable) owns app state (splash → login → authenticated /
unavailable-reconnect), typed `Route` navigation, cross-screen sync, and DRY error handling.
A 401 — or a 403 the ping probe proves is a dead token — wipes the session; a live-token 403 is a
banner; a stale-token 401/403 is ignored. Details: [docs/agents/architecture.md](docs/agents/architecture.md)
and [docs/agents/session-resilience.md](docs/agents/session-resilience.md).

## Critical Invariants

Violating these shipped bugs before; each links to its full contract.

1. **Screen wrappers**: VMs are constructed via `_viewModel = State(wrappedValue: make())` and
   `init` must stay side-effect-free — never inline VM construction, never `@autoclosure`.
   → [architecture.md](docs/agents/architecture.md#viewmodel-lifecycle-in-navigationstack)
2. **Download queue never collapses pagination**: no page-1 reloads outside refresh/tab-switch;
   swipe actions mutate surgically; progress banner is a safe-area inset, not a List sibling.
   → [download-queue.md](docs/agents/download-queue.md)
3. **`AVPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible`** must travel with the
   player on every swap. → [playback.md](docs/agents/playback.md)
4. **Delegate-based URLSessions must `finishTasksAndInvalidate()` on every terminal path**;
   every `StreamingSession` consumer pairs cancellation with `cancelUpstream()`.
   → [playback.md](docs/agents/playback.md#streaming)
5. **Cache is two-region (pinned prefix + sliding main)**; `setEntry` is idempotent; trim/playback
   offsets come from the VM time observer, never loader reads; reseed/restart hooks have exact
   trigger/orchestration contracts. → [playback.md](docs/agents/playback.md#in-memory-video-cache-datacache)
6. **Only a proven-dead token wipes the session**; stale check runs before AND after the 403 probe;
   `isTokenCurrent == nil` means legacy always-post. → [session-resilience.md](docs/agents/session-resilience.md)
7. **`lastExplicitSeekAt` defaults to `CFAbsoluteTimeGetCurrent()`, never `0`** (both init and
   `stopPlayback()` reset; locked by `SeekTimestampInitTests`).
8. **Never**: `automaticallyWaitsToMinimizeStalling`, private `AVURLAssetHTTPHeaderFieldsKey`,
   a `deinit` on `AuthProxy`, `Task.isCancelled` as an abandonment guard, per-member `nonisolated`
   on lock-guarded classes. → [playback.md](docs/agents/playback.md#important--do-not)

## Documentation Index

| File | Read before touching |
|---|---|
| [docs/agents/architecture.md](docs/agents/architecture.md) | AppRouter, DI, VM wrappers, navigation, privileges, iPad quirks |
| [docs/agents/api.md](docs/agents/api.md) | APIClient, endpoints, auth flow, DTO/data formats |
| [docs/agents/session-resilience.md](docs/agents/session-resilience.md) | Startup classification, 403 probe, stale-token guards |
| [docs/agents/playback.md](docs/agents/playback.md) | Players, streaming, in-memory cache, AuthProxy, diagnostics |
| [docs/agents/download-queue.md](docs/agents/download-queue.md) | DownloadQueueViewModel stable-scroll contract |
| [docs/agents/features.md](docs/agents/features.md) | Video list, channel detail, playlists, SponsorBlock |
| [docs/agents/share-extension.md](docs/agents/share-extension.md) | Share extension target, keychain sharing, pbxproj wiring |
| [docs/agents/testing.md](docs/agents/testing.md) | Test infrastructure, phase map, test gotchas |
