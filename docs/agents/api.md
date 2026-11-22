# API Details

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
