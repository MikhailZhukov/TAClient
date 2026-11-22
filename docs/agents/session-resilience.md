# Session Resilience

Startup and auth-failure semantics — a live session must only be destroyed by a **proven-expired**
token, never by an offline server, a 403 with a valid token, or a late response from an old token.

- **Startup classification (A):** `StartupOutcome.classify` (`Domain/Util/StartupOutcome.swift`)
  maps ONLY `AppError.unauthorized` to `.unauthorized`; every other error (network, 5xx, decoding,
  HTML-200 from a proxy) is `.unavailable`. `AppRouter.attemptStartup()` runs
  `authRepository.ping()` → on `.unavailable` sets `AppState.unavailable` (credentials untouched,
  `onStartupUnavailable()`); on success fetches the user account, and a non-`.unauthorized`
  account failure logs and continues unprivileged (matches the old `try?` behavior). RootView
  renders `ReconnectView` (server name + Retry + Change Server behind a destructive
  `.confirmationDialog`) for `.unavailable`. Only `.unauthorized` wipes via `handleUnauthorized()`.
- **403 semantics (B):** `APIClient.rawRequest` — 401 → `.unauthorized`; 403 → if the endpoint is
  `.ping` throw `.unauthorized` (no recursion), else `probeTokenAlive()` (direct GET `/api/ping/`
  with the current token, NOT routed through `request<T>`): pong + `user > 0` →
  `AppError.permissionDenied` (banner via `handleError`'s generic branch, no logout); any probe
  failure → `.unauthorized`. `AppError` has a `permissionDenied` case (`error_permission_denied`,
  en + ru).
- **Stale-token guards (E):** a 401/403 whose request carried a **since-replaced** token must not
  revoke the new session. Ordering in `rawRequest` is load-bearing: stale check
  (`sentToken != authState.token` → neutral `AppError.network`) runs BEFORE both the 401 mapping
  and the 403 probe, and is re-checked AFTER the probe (a credential swap during the 5 s probe
  window must not wipe the fresh session). The same guard exists at the two non-APIClient doors —
  `CachingResourceLoader.handleUnauthorizedIfNeeded` and `VideoCachePreloader` (HEAD probe +
  download post-sites) — via an `isTokenCurrent: (@Sendable (String) -> Bool)?` closure; **default
  nil = legacy behavior** (always post `.taAuthUnauthorized`). Production wiring captures ONE
  shared `KeychainService` instance per closure (loader in `makeCachingAsset`, preloader in
  `VideoCachePreloader.shared`) — `isCurrentAuthToken` returns `true` on keychain READ failure
  (staleness can never be proven from a failed read, so the revoke path stays conservative).
- **`KeychainService` is `nonisolated final class`** (immutable `let` storage; SecItem is
  thread-safe — CacheStore pattern) exposing `isCurrentAuthToken(_:)` so nonisolated data-layer
  objects can check token currency without a MainActor hop.
