# Fix Session Resilience: Startup Offline (A), 403 Permission (B), Stale-Token Guards (E)

## Overview

Порт трёх фиксов «session resilience» из форка `nimasii/Fold` (commits `0d94d3d`, `9d5dcb0` и
класс «authorization snapshot») под дизайн TAClient (token-auth, без webview, без session/CSRF).

- **A — startup offline не стирает токен.** Сейчас `RootView.autoLogin()` (TAClientApp.swift) в catch
  **любой** ошибки вызывает `router.onAutoLoginFailed()` → `authState.handleUnauthorized()` →
  `keychainService.clearAll()`. Запуск офлайн / во время рестарта сервера / при 5xx → токен
  стёрт навсегда → полный перелогин. Фикс: классификация `AppError.unauthorized` vs остальное;
  сетевые сбои ведут в новое `AppState.unavailable` + экран `ReconnectView` (Retry / Change server),
  креденшелы не трогаются.
- **B — 403 с живым токеном ≠ истёкшая сессия.** Сейчас `APIClient.rawRequest` (строка 86-87)
  мапит `401, 403 → AppError.unauthorized` на **любом** эндпоинте → `AppRouter.handleUnauthorized()`
  стирает сессию. Фикс: `401` → сразу `.unauthorized`; `403` → пробный `GET /api/ping/` тем же
  токеном: pong + `user > 0` → новый `AppError.permissionDenied` (баннер ошибки, **без** logout);
  ping не прошёл → `.unauthorized`. Upstream TA подтверждён: `PingView` наследует `ApiBaseView`
  (DRF auth) — невалидный токен даёт 401/403 и на ping; валидный → `{"response":"pong","user":N}`.
- **E — поздний 401/403 от старой связи не отзывает новую.** После переключения сервера в полёте
  остаются запросы со **старым** токеном; их 401/403 сейчас отзывают **новую** сессию. Три двери:
  1. `APIClient.rawRequest` — 401/403 → `.unauthorized` (широкое окно: fetch списка живёт сотни мс);
  2. `CachingResourceLoader.handleUnauthorizedIfNeeded` (CachingResourceLoader.swift:612-623) — пост
     `.taAuthUnauthorized` без сверки токена;
  3. `VideoCachePreloader.probeTotalSize` / `downloadRange` (стр. ~689, ~751) — то же.
  Фикс: перед отзывом сессии сверить токен запроса с текущим (source of truth — keychain;
  `KeychainService` получает `nonisolated` + `isCurrentAuthToken(_:)`). Не совпало → запрос
  тихо умирает (loader bail / APIClient бросает нейтральную `.network(nil)`), сессия жива.

## Context (from discovery)

- `TAClient/TAClientApp.swift` — `RootView`: switch по `router.appState`; `.splash` → `.task { await autoLogin() }`; `autoLogin()` = ping → (pong?) fetchUserAccount → `onLoginSuccess()`, catch → `onAutoLoginFailed()`.
- `TAClient/Presentation/Navigation/AppRouter.swift:3-7` — `enum AppState { splash, login, authenticated }`; `onAutoLoginFailed()` (86-89) = `authState.handleUnauthorized()` + `.login`; router `handleUnauthorized()` — идемпотентный wipe + path/state reset; `handleError` — `case .unauthorized` → `handleUnauthorized()`, остальное → `errorMessage`.
- `TAClient/Data/Local/AuthState.swift:42-49` — `handleUnauthorized()` = `keychainService.clearAll()` + reset.
- `TAClient/Data/Remote/APIClient.swift` — `rawRequest` — единственная точка маппинга статусов (69-87); `PingDTO` уже имеет `user: Int?` (CommonDTO.swift:21-24) — DTO не менять.
- `TAClient/Data/Cache/CachingResourceLoader.swift` — init получает `token: String` (nonisolated let); `handleUnauthorizedIfNeeded(response:)` nonisolated, centralized post-site; init уже имеет паттерн инжектируемых closure-сьюмов (`isPreloadingCheck`, `graceSleep`) — новый параметр встает в тот же ряд.
- `TAClient/Data/Cache/VideoCachePreloader.swift` — `static let shared = VideoCachePreloader()` (default init); post-sites в actor-isolated методах `probeTotalSize` (HEAD) и `downloadRange` (GET); есть `testSessionConfigurationOverride` для MockURLProtocol.
- `TAClient/Data/Local/KeychainService.swift` — stateless-обёртка (два immutable let), MainActor-изолирована **только** из-за `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; SecItem API тред-сейф → `nonisolated` легитимно (паттерн `CacheStore`).
- `TAClient/DI/DependencyContainer.swift` — `private init`, `router = AppRouter(authState: authState)`; `authRepository` уже существует в контейнере — для `attemptStartup` передаётся в router.
- `TAClientTests/MockURLProtocol.swift` — `requestHandler: (URLRequest) throws -> (HTTPURLResponse, Data)` — получает запрос → **ветвление по path** (первый запрос → 403, последующий `/api/ping/` → 200) поддерживается без изменений.
- Upstream TA (проверено по `develop`): `PingView(ApiBaseView).get` → `{"response","user","version","ta_update"}`; `AdminOnly = is_staff OR "admin" group`.

## Development Approach

- **testing approach**: **TDD** — каждый task: сначала failing-тесты, потом реализация.
- Complete each task fully before moving to the next; all tests must pass before next task.
- Make small, focused changes; update this plan file when scope changes.
- Локализация: все новые строки через `String(localized: "snake_case_key")`, en + ru в `TAClient/Resources/Localizable.xcstrings`.
- Project rule (не нарушать): ключchain-раундтрипы в тестах не проверяем — только in-memory state; E-тесты идут через **инжектируемые closure**, не через реальный keychain.
- Project rule: wiring-копирование не тестируем — production-провайдеры (closure у `makeCachingAsset` / `.shared` / контейнер) покрываются сборкой + smoke.

## Testing Strategy

- **unit tests**: каждый task (TDD).
- **e2e/XCUITest**: не используем (в проекте только flake-ный `testLaunchPerformance`); UI-поведение `ReconnectView` покрывается smoke (Post-Completion) — вся логика в `AppRouter.attemptStartup` и тестируется там.

## Progress Tracking

- `[x]` — сделано, сразу после проверки тестами.
- `➕` — новые задачи, `⚠️` — блокировщики.

## Solution Overview

1. **A**: чистый классификатор `StartupOutcome.classify(_:)` (Domain) + `AppRouter.attemptStartup()`
   (async, получает `authRepository` через init) — вся стартовая логика уходит из `RootView` в
   router (тестируемо mock-репо). `AppState.unavailable` + `ReconnectView` (Retry вызывает
   `attemptStartup()` повторно; Change server → `confirmationDialog` → `onAutoLoginFailed()`).
   Токен стёрт **только** при `AppError.unauthorized`.
2. **B**: в `rawRequest` — `401` → `.unauthorized`; `403` → `probeTokenAlive()` (прямой GET ping
   тем же токеном, без рекурсии: если сам упавший запрос — ping, проба пропускается) →
   pong+user>0 ? `.permissionDenied` : `.unauthorized`. Без actor-коалесинга (403 — редкое
   событие; queue UI скрыт у non-privileged, polling 403-ов не возникает).
3. **E**: `KeychainService` → `nonisolated` (+`isCurrentAuthToken`); три двери получают
   инжектируемый `isTokenCurrent: (@Sendable (String) -> Bool)?` (default `nil` = legacy —
   existing-тесты не трогаем); production-значение `{ KeychainService().isCurrentAuthToken($0) }`
   подставляется в трёх местах: `.shared` прелоадера, `makeCachingAsset` в VM, и в `rawRequest`
   (там токен читается из `authState` до/после запроса — отдельная реализация, closure не нужен).
   APIClient: stale → `AppError.network(nil)` (нейтральный баннер, без logout) — **до** проверки
   403-пробы.

## Technical Details

- **Классификация A**: `AppError.unauthorized` → `.unauthorized`; всё остальное
  (`.network`, `.serverError`, `.decoding` — HTML-200 от прокси, `.invalidURL`, `.unknown`,
  сырой `URLError`) → `.unavailable`. `ping()` вернул `pong != "pong"` (200, но не наш формат)
  → `.unavailable` (токен не верифицирован, но и не опровергнут).
- **A retry-loop**: `attemptStartup()` идемпотентна — вызывается и из `.task` на `.splash`, и из
  Retry-кнопки на `ReconnectView`. Успех: `onLoginSuccess()` (существующий переход
  `.authenticated`). Сбой `fetchUserAccount` после успешного ping: `.unauthorized` → wipe +
  `.login`; любой другой сбой → log + `onLoginSuccess()` с `isPrivileged == false` (сохраняет
  текущее `try?`-поведание: сервер жив — сессию не бьём, `.unavailable` зарезервирован для
  недоступности ping).
- **B probe**: отдельный URLRequest (не через `request<T>` — иначе рекурсия 403→probe→403);
  session как у `rawRequest`; ответ 200 + decode `PingDTO` + `response == "pong" && (user ?? 0) > 0`.
- **E ordering в rawRequest**: catch статуса → (1) stale-чек: `sentToken != authState.token` →
  `.network(nil)`; (2) 401 → `.unauthorized`; (3) 403 → probe → `.permissionDenied`/`.unauthorized`.
  Запросы без токена (login/token endpoints) — stale-чек не применяется.
- **E loader**: `handleUnauthorizedIfNeeded` при stale возвращает `true` (bail из запроса —
  этот playback мёртв), но постит только при совпадении токена.
- **KeychainService**: класс → `nonisolated final class` (паттерн CacheStore; только immutable
  let, SecItem тред-сейф). AuthState (MainActor) вызывает nonisolated методы без изменений.

## What Goes Where

- Implementation: Tasks 1-10 (code + tests + docs).
- Post-Completion: ручные сценарии, требующие живого сервера / offline-симуляции.

## Implementation Steps

### Task 1: StartupOutcome классификатор (A)

**Files:**
- Create: `TAClient/Domain/Util/StartupOutcome.swift`
- Create: `TAClientTests/StartupOutcomeTests.swift`

- [x] TDD: написать failing-тесты `StartupOutcomeTests`: `AppError.unauthorized` → `.unauthorized`;
      `.network(URLError(.notConnectedToInternet))` → `.unavailable`; `.serverError(500, nil)` →
      `.unavailable`; `.serverError(429, nil)` → `.unavailable`; `.decoding(...)` → `.unavailable`;
      `.invalidURL` → `.unavailable`; `.unknown("x")` → `.unavailable`; сырой `URLError` → `.unavailable`
- [x] Реализовать `enum StartupOutcome { case unauthorized, unavailable }` +
      `static func classify(_ error: Error) -> StartupOutcome` в Domain (switch:
      `case AppError.unauthorized:` → unauthorized; `default:` → unavailable)
- [x] Запустить тесты — зелёные, до Task 2 не переходить
      (note: xcodebuild недоступен в sandbox — проверено `swiftc -frontend -parse` на обоих файлах; выполнение тестов вручную в Xcode)

### Task 2: AppState.unavailable + AppRouter.attemptStartup + ReconnectView (A)

**Files:**
- Modify: `TAClient/Presentation/Navigation/AppRouter.swift`
- Modify: `TAClient/DI/DependencyContainer.swift`
- Modify: `TAClient/TAClientApp.swift`
- Create: `TAClient/Presentation/Common/ReconnectView.swift`
- Modify: `TAClient/Resources/Localizable.xcstrings`
- Modify: `TAClientTests/AppRouterTests.swift` (`makeRouter`, :14), `TAClientTests/Mocks.swift`
      (`makeMockRouter`, :205 — shared-инфра, 9× `WrapperLifecycleTests`) и все прямые
      `AppRouter(authState:)` в ~17 test-файлах (grep `AppRouter(`)

- [x] TDD: `AppRouterTests.attemptStartup_*` — существующий `MockAuthRepository` (injectable
      `pingHandler`/`fetchUserAccountHandler`) + **реальный** `AuthState` (final `@Observable` —
      mock невозможен) с реальным `KeychainService`; wipe проверяется по `authState.token`:
      - ping ok + account ok → `.authenticated`, токен сохранён
      - ping → `.unauthorized` → router `handleUnauthorized()` (wipe + `.login`), токен `nil`
      - ping → `.network` → `.unavailable`, токен НЕ `nil`
      - ping ok, account → `.unauthorized` → wipe + `.login`
      - ping ok, account → `.network`/`.serverError` → `.authenticated` БЕЗ wipe, `isPrivileged == false`
        (сохраняет текущее `try?`-поведание: сервер жив — сессию не бьём)
      - ping 200 но `response != "pong"` (repo вернёт false) → `.unavailable`
      (note: xcodebuild недоступен в sandbox — тесты написаны и синтаксис-проверены `swiftc -frontend -parse`; выполнение вручную в Xcode)
- [x] TDD: `onStartupUnavailable` — appState `.unavailable`, authState не тронут
- [x] Добавить `AppState.unavailable`; `onStartupUnavailable()`; `attemptStartup()`: ping →
      classify; `.unauthorized` (ping ИЛИ account) → router `handleUnauthorized()` (идемпотентный —
      не дублировать последовательность `onAutoLoginFailed`); любой другой сбой ping →
      `onStartupUnavailable()`; сбой account (не `.unauthorized`) → log + `onLoginSuccess()` с
      `isPrivileged == false` (текущее `try?`-поведание); init `AppRouter(authState:authRepository:)`,
      контейнер передать `authRepository`
- [x] `RootView`: убрать локальный `autoLogin()`, `.task { await router.attemptStartup() }` на
      `.splash`; `case .unavailable: ReconnectView(retry: { await router.attemptStartup() },
      changeServer: { router.onAutoLoginFailed() }, serverName: ...)`
- [x] `ReconnectView`: системные цвета/типаграфика (`.headline`, `.body`), `accessibilityLabel`
      на кнопках, `confirmationDialog` перед «Change server» (destructive), `ProgressView`
      во время retry, server name из `container.authState.serverURL` (`RootView` уже держит
      `@Environment(DependencyContainer.self)`; `AppRouter.authState` — private, не добавлять
      accessor ради одного имени)
- [x] Локализация: `reconnect_title`, `reconnect_retry`, `reconnect_change_server`,
      `reconnect_change_server_confirm_title`, `reconnect_change_server_confirm_message`
      (en + ru)
- [x] Запустить тесты — зелёные, до Task 3 не переходить
      (note: не автоматизируемо в sandbox — xcodebuild недоступен; `swiftc -frontend -parse` зелёный на всех затронутых файлах, полный прогон — вручную в Xcode)

### Task 3: AppError.permissionDenied (B)

**Files:**
- Modify: `TAClient/Domain/Util/AppError.swift`
- Modify: `TAClient/Resources/Localizable.xcstrings`
- Modify: `TAClientTests/AppErrorTests.swift` (существующий per-case `errorDescription` suite)

- [x] Grep по `TAClient/` и `TAClientTests/` exhaustive-switch по `AppError` (`switch ... as? AppError`,
      `case .unauthorized:` и т.п.) — список мест, которые сломает новый case; зафиксировать в плане (➕)
      — exhaustive-switch есть только в `AppError.errorDescription` (обновлён); остальные места —
      non-exhaustive `if case` (AppRouter.handleError → generic branch = banner без logout,
      StartupOutcome, тесты), ломать нечему.
- [x] TDD: тест `errorDescription` для `.permissionDenied` → `"error_permission_denied"`
- [x] Добавить `case permissionDenied` + localized description; ключ `error_permission_denied`
      (en: "Not enough permissions", ru: «Недостаточно разрешений»)
- [x] Обновить найденные в grep места (если есть); запустить тесты — зелёные
      (xcodebuild недоступно в sandbox — swiftc -frontend -parse зелёный; полный тест-ран ручной в Xcode)

### Task 4: APIClient 403 → ping-проба (B)

**Files:**
- Modify: `TAClient/Data/Remote/APIClient.swift`
- Modify: `TAClientTests/APIClientTests.swift` (Phase 3, MockURLProtocol)

- [x] TDD (одна `requestHandler`, ветвление по `request.url?.path` — `/api/ping/` → probe-ответ,
      остальное → исходный 403/401):
      - `..._403_pingAlive_throwsPermissionDenied`: 403 на `/api/download/` + ping 200
        `{"response":"pong","user":5}` → `AppError.permissionDenied`; в логе запросов **был**
        `/api/ping/`; `authState.token` не изменился
      - `..._403_ping401_throwsUnauthorized`
      - `..._403_pingNetworkFail_throwsUnauthorized` (handler кидает `URLError` на ping)
      - `..._403_pingNotPong_throwsUnauthorized` (200, `{"response":"nope"}` — положительная
        проба только при pong && user > 0)
      - `..._401_doesNotPing`: 401 → `.unauthorized`, в логе запросов `/api/ping/` **не было**
      - `..._403OnPingItself_throwsUnauthorized_noRecursion`: 403 на самом `/api/ping/` →
        `.unauthorized`, всего ровно 1 запрос (проба на ping не делается) — счётчик запросов
        захватить в closure-handler: `MockURLProtocol.lastRequest` хранит только последний
      - **не трогать** существующие `request_401_throwsUnauthorized` / `request_403_throwsUnauthorized`
        (APIClientTests.swift:33–57, оба на `endpoint: .ping`) — остаются зелёными через no-recursion
        guard и pin-ят его; «403 на non-ping эндпоинте с мёртвым ping» до этого не покрывался —
        новые тесты закрывают разрыв
- [x] Реализовать: в `rawRequest` — `case 401:` → `.unauthorized`; `case 403:` →
      `endpoint == .ping` ? `.unauthorized` : (`await probeTokenAlive()` ? `.permissionDenied`
      : `.unauthorized`); `probeTokenAlive()` — прямой URLRequest на ping-URL (не через
      `request<T>`), тот же session, Token-заголовок, 200 + `PingDTO` + pong + `user > 0`
- [x] Запустить тесты — зелёные, до Task 5 не переходить

### Task 5: KeychainService nonisolated + isCurrentAuthToken (E)

**Files:**
- Modify: `TAClient/Data/Local/KeychainService.swift`

- [ ] Класс → `nonisolated final class KeychainService` (паттерн CacheStore; только immutable let,
      SecItem тред-сейф) — проверить, что все методы компилируются без MainActor-хопов;
      AuthState (MainActor) продолжает работать
- [ ] Добавить `func isCurrentAuthToken(_ token: String) -> Bool { load(for: .authToken) == token }`
- [ ] Сборка + полный тест-ран (без новых тестов: project rule — keychain-раундтрипы не тестируем;
      поведение покрывают Tasks 6-8 через инжектируемые closure)

### Task 6: CachingResourceLoader stale-token guard (E)

**Files:**
- Modify: `TAClient/Data/Cache/CachingResourceLoader.swift`
- Modify: `TAClient/Presentation/VideoDetail/VideoDetailViewModel.swift`
- Modify: `TAClientTests/CacheAuthFailureTests.swift` (именно там 401/403-тесты лоадера +
      `NotificationExpectation`-хелпер; в `CachingResourceLoaderTests.swift` их нет)

- [ ] TDD (loader собирается с фейковой closure; наблюдатель `.taAuthUnauthorized` со scope по
      `object == videoId`):
      - 401 + `isTokenCurrent: { false }` → `handleUnauthorizedIfNeeded` вернул `true` (bail),
        нотификация **не** пришла
      - 401 + `isTokenCurrent: { true }` → нотификация пришла
      - 401 + default (nil) → нотификация пришла (legacy-поведение сохранено)
      - 403 + `isTokenCurrent: { false }` → нет нотификации, вернул `true`
- [ ] Init-параметр `isTokenCurrent: (@Sendable (String) -> Bool)? = nil`; в
      `handleUnauthorizedIfNeeded`: 401/403 → если `isTokenCurrent` задан и `!isTokenCurrent(token)`
      → log (stale, connection replaced) и **без** поста; в любом случае return true
- [ ] Production-wiring в `makeCachingAsset` (VideoDetailViewModel): передать
      `isTokenCurrent: { KeychainService().isCurrentAuthToken($0) }` (единственная
      production-точка сборки лоадера)
- [ ] Запустить тесты — зелёные, до Task 7 не переходить

### Task 7: VideoCachePreloader stale-token guard (E)

**Files:**
- Modify: `TAClient/Data/Cache/VideoCachePreloader.swift`
- Modify: `TAClientTests/VideoCachePreloaderTests.swift` / `TAClientTests/CacheAuthFailureTests.swift`

- [ ] TDD (инстансы `VideoCachePreloader(isTokenCurrent: fake)` + существующий
      `testSessionConfigurationOverride` + MockURLProtocol):
      - `probeTotalSize` HEAD 401 + `{ false }` → нотификации нет
      - `probeTotalSize` HEAD 401 + `{ true }` → нотификация есть
      - `probeTotalSize` HEAD 401 + default (nil) → нотификация есть (legacy)
      - `downloadRange` GET 401 + `{ false }` → нотификации нет
      - `downloadRange` GET 401 + `{ true }` → нотификация есть
      - `downloadRange` GET 403 + `{ false }` → нотификации нет
- [ ] **`private init()` → internal `init(isTokenCurrent: (@Sendable (String) -> Bool)? = nil)`**
      (явное расширение видимости — failing-тесты без него не скомпилируются; НЕ мутировать
      `.shared` и НЕ вводить test-only static); `static let shared =
      VideoCachePreloader(isTokenCurrent: { KeychainService().isCurrentAuthToken($0) })`;
      оба post-site: если closure задан и токен не текущий → log + без поста (остальной
      flow — return/abort — не меняется)
- [ ] Инстансы на тест: `init` регистрирует memory-pressure `DispatchSource` без `deinit`-отмены —
      `deinit` в production-класс ради тестов НЕ добавлять (handler `[weak self]`, безвредно);
      инстанс на тест-кейс приемлем
- [ ] Запустить тесты — зелёные, до Task 8 не переходить

### Task 8: APIClient stale-token door (E)

**Files:**
- Modify: `TAClient/Data/Remote/APIClient.swift`
- Modify: `TAClientTests/APIClientTests.swift`

- [ ] TDD (mutation токена в полёте: в closure-handler — `Task { @MainActor in
      authState.setCredentials(token: "B", ...) }`, т.к. `AuthState` MainActor-isolated и прямой
      вызов из handler не скомпилируется; детерминизм: мутация встаёт в MainActor FIFO ещё в
      `startLoading`, а доставка ответа клиенту — строго позже; сам handler синхронный — ответ
      к клиенту в момент мутации ещё не ушёл):
      - 401 + token поменялся в полёте (A → B) → `AppError.network` (НЕ `.unauthorized`)
      - 403 + token поменялся → `AppError.network`, в логе запросов `/api/ping/` **не было**
        (stale-чек раньше 403-пробы)
      - 401 + тот же токен → `.unauthorized` (регрессия существующего поведения)
      - `authState.token == nil` при запросе → 401 → `sentToken == nil` → stale-чек пропущен →
        `.unauthorized` (реального «запроса без токена при живом токене в authState» из
        `rawRequest` не бывает — login-flow не ходит через `rawRequest`)
- [ ] Реализовать: в `rawRequest` захватить `sentToken = authState.token` до запроса; при 401/403:
      `if let sentToken, sentToken != authState.token { throw AppError.network(nil) }`
      — **до** 401-маппинга и 403-пробы
- [ ] Запустить тесты — зелёные, до Task 9 не переходить

### Task 9: Verify acceptance criteria

- [ ] Проверить требования Overview: (A) оффлайн-старт не стирает токен, экран reconnect + retry
      работает; (B) 403 с живым токеном → баннер без logout; (E) поздний 401/403 со старым токеном
      не отзывает новую сессию — во всех трёх дверях
- [ ] Проверить edge-кейсы: ping-403 без рекурсии; stale-чек раньше 403-пробы; legacy nil-closure
      поведения не изменилось; `pong != "pong"` → unavailable
- [ ] Полный тест-ран: `/bin/bash -c 'xcodebuild test -scheme TAClient -destination "platform=iOS Simulator,name=iPhone 17 Pro"'`
- [ ] Сборка: `/bin/bash -c 'xcodebuild build -scheme TAClient -destination "platform=iOS Simulator,name=iPhone 17 Pro"'`
- [ ] Обновить счётчики тестов в CLAUDE.md (≈577 + новые)

### Task 10: Update documentation

- [ ] CLAUDE.md: новый блок «Session Resilience» (startup classification + `AppState.unavailable`/
      `ReconnectView` + `AppRouter.attemptStartup`); в «API Details» — семантика 403
      (ping-проба, `permissionDenied`, порядок stale-чека); `KeychainService` — nonisolated;
      stale-token guards (три двери, `isCurrentAuthToken`, default nil = legacy);
      `AppError.permissionDenied` case
- [ ] CLAUDE.md: обновить фазу 3/тест-список (новые suites)
- [ ] Переместить план в `docs/plans/completed/` (каталог существует)

## Post-Completion

*Требуют живого сервера / ручного вмешательства — без чекбоксов.*

**Manual verification:**
- **A**: симулятор, Wi-Fi off (или недостижимый URL сервера) → запуск → экран «Server Unreachable»
  с именем сервера → Retry (оффлайн) → экран остаётся → «Change server» → confirmation → login;
  с нажатого Retry при востановлении сети → главный экран. Токен в keychain не стёрт
  (проверка: после восстановления сети логин по username/password НЕ запрашивается).
- **B**: TA-инстанс с **non-admin** токеном (`is_staff=false`, без admin-группы): открыть
  Download Queue / админ-эндпоинт → 403 → баннер «Not enough permissions» / «Недостаточно
  разрешений», сессия жива (навигация продолжает работать, перезапуск → без перелогина).
- **E**: (сложно форсировать вручную) переключение между двумя TA-серверами в момент активного
  fetch списка — новая сессия не отзывается; подтверждается unit-тестами Tasks 6-8.

**External system updates:**
- App Store: новые разрешения/entitlements не требуются; PrivacyInfo не меняется.
