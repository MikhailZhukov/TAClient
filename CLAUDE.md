# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

iOS/iPadOS client for [Tube Archivist](https://github.com/tubearchivist/tubearchivist), a self-hosted YouTube archiver. Pure SwiftUI, no third-party dependencies.

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

## Architecture

Clean Architecture with three layers, all under `iTubeArchivist/`:

```
Domain/    → Models, Repository protocols, AppError
Data/      → APIClient, DTOs, Mappers (DTO→Model), KeychainService, AuthState, Repository impls
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

## API Details

- Server URL is user-provided and dynamic
- **2-step login:** POST `/api/user/login/` (returns session cookie) → GET `/api/appsettings/token/` (returns token)
- Auth header on all subsequent requests: `Authorization: Token {token}`
- All image/media URLs from API are **relative paths** — mappers prepend the server base URL
- Video playback uses `AVURLAsset` with auth headers via `AVURLAssetHTTPHeaderFieldsKey`
- Search param is `query` (not `q`): `GET /api/search/?query=X&page=N`
- Localization keys use `snake_case`; formatted dates use non-breaking spaces (`\u{00A0}`)
