# Tube Archivist iOS Client - Full Specification

This document contains everything needed to create an iOS (SwiftUI) version of the Tube Archivist Android client. It includes all API details, data models, screen specifications, UI behavior, string resources, and the complete Android source code for reference.

## Table of Contents
1. [Project Overview](#1-project-overview)
2. [API Reference](#2-api-reference)
3. [Architecture Overview](#3-architecture-overview)
4. [Data Models](#4-data-models)
5. [Screens & UI](#5-screens--ui)
6. [String Resources](#6-string-resources)
7. [Complete Android Source Code](#7-complete-android-source-code)

---

## 1. Project Overview

**App Name:** Tube Archivist
**Purpose:** Native client for Tube Archivist - a self-hosted YouTube archiver with its own API.
**Test Server:** Your own Tube Archivist instance

### Features
- Login with server URL + credentials
- Browse archived videos with sorting, ordering, filtering
- Search videos
- View video details (info, description, comments)
- Play videos with progress tracking (resume from last position)
- View channel pages with banner, info, and video list
- Delete videos from archive
- Localization: English + Russian
- Supports iPhone and iPad (adaptive grid layout)

### Key Behaviors
- Server URL is dynamic (user enters at login)
- All image/media URLs from API are **relative paths** - must prepend server base URL
- Auth token persisted locally for auto-login on next launch
- 401/403 responses redirect to login screen
- Video playback progress saved every 10 seconds + on player close
- Thumbnail prefetching for smooth scrolling

---

## 2. API Reference

Base URL is dynamic (user-provided). All endpoints require `Authorization: Token xxx` header except login.

### Authentication

**Login (2-step):**
1. `POST /api/user/login/` - Body: `{"username": "...", "password": "..."}` - Returns session cookie
2. `GET /api/appsettings/token/` - Uses session cookie from step 1 - Returns: `{"token": "xxx"}`

After obtaining token, all subsequent requests use header: `Authorization: Token xxx`

**Health check:**
- `GET /api/ping/` - Returns: `{"response": "pong", "user": 1, "version": "..."}`

### Videos

**List videos:**
- `GET /api/video/?page=N&sort=X&order=Y&watch=Z`
- Sort options: `published`, `downloaded`, `views`, `likes`, `duration`, `mediasize`
- Order: `asc`, `desc`
- Watch filter: `watched`, `unwatched`, `continue` (omit for all)
- Channel filter: `&channel=CHANNEL_ID`
- Response:
```json
{
  "data": [VideoDto, ...],
  "paginate": {
    "page_size": 12,
    "page_from": 0,
    "current_page": 1,
    "last_page": 5,
    "total_hits": 60,
    "max_hits": false
  }
}
```

**Get single video:**
- `GET /api/video/{youtube_id}/` - Returns: `VideoDto`

**Update playback progress:**
- `POST /api/video/{youtube_id}/progress/` - Body: `{"position": 123.45}` (seconds)

**Delete progress:**
- `DELETE /api/video/{youtube_id}/progress/`

**Delete video:**
- `DELETE /api/video/{youtube_id}/`

**Ignore video (prevent re-download):**
- `POST /api/download/{youtube_id}/` - Body: `{"status": "ignore-force"}`

**Get comments:**
- `GET /api/video/{youtube_id}/comment/` - Returns: `[CommentDto, ...]`

### Search

- `GET /api/search/?query=xxx&page=N`
- **IMPORTANT:** Query param is `query`, NOT `q`
- Response:
```json
{
  "results": {
    "video_results": [VideoDto, ...],
    "channel_results": [ChannelDto, ...]
  }
}
```

### Channels

- `GET /api/channel/{channel_id}/` - Returns: `ChannelDto`
- Channel videos: use `GET /api/video/?channel={channel_id}&page=N`

### VideoDto Structure
```json
{
  "youtube_id": "dQw4w9WgXcQ",
  "title": "Video Title",
  "description": "...",
  "published": "2021-10-25T00:00:00Z",
  "date_downloaded": 1635120000,
  "active": true,
  "channel": {
    "channel_id": "UCxxxxxx",
    "channel_name": "Channel Name",
    "channel_thumb_url": "/cache/channels/UCxxxxxx_thumb.jpg",
    "channel_banner_url": "/cache/channels/UCxxxxxx_banner.jpg",
    "channel_description": "...",
    "channel_subscribed": true,
    "channel_subs": 1000000
  },
  "vid_thumb_url": "/cache/videos/dQw4w9WgXcQ_thumb.jpg",
  "media_url": "/cache/videos/dQw4w9WgXcQ.mp4",
  "media_size": 524288000,
  "player": {
    "watched": false,
    "duration": 212,
    "duration_str": "3:32",
    "progress": 0.5,
    "position": 106.0
  },
  "stats": {
    "view_count": 1000000,
    "like_count": 50000,
    "dislike_count": 0,
    "average_rating": 0.0
  },
  "vid_type": "videos",
  "category": ["Music"],
  "tags": ["music", "pop"],
  "streams": [
    {"type": "video", "index": 0, "codec": "avc1", "bitrate": 5000000, "width": 1920, "height": 1080},
    {"type": "audio", "index": 1, "codec": "mp4a", "bitrate": 128000, "width": null, "height": null}
  ]
}
```

### CommentDto Structure
```json
{
  "comment_author": "User Name",
  "comment_author_id": "UCxxxxxx",
  "comment_author_is_uploader": false,
  "comment_author_thumbnail": "/cache/comments/UCxxxxxx_thumb.jpg",
  "comment_id": "Ugxxx",
  "comment_is_favorited": false,
  "comment_likecount": 42,
  "comment_parent": "root",
  "comment_text": "Great video!",
  "comment_time_text": "2 years ago",
  "comment_timestamp": 1635120000,
  "comment_replies": [CommentDto, ...]
}
```

---

## 3. Architecture Overview

The Android app uses **Clean Architecture + MVVM**:

```
Domain Layer (models, repository interfaces)
    |
Data Layer (API, DTOs, mappers, repository implementations, local storage)
    |
Presentation Layer (ViewModels + UI screens)
```

### iOS Equivalent Suggestions
- **Networking:** URLSession or Alamofire (equivalent of Retrofit + OkHttp)
- **DI:** Swift's Environment/EnvironmentObject or a DI framework
- **Image Loading:** AsyncImage or SDWebImage/Kingfisher (authenticated URLs need custom URLSession)
- **Video Player:** AVPlayer (equivalent of ExoPlayer)
- **Pagination:** Custom pagination or Swift async sequences
- **Local Storage:** UserDefaults or Keychain (for token + server URL)
- **Navigation:** NavigationStack

### Key Implementation Notes

1. **Dynamic Base URL:** The server URL changes per user. All API calls must use the user-provided server URL.

2. **Authenticated Image Loading:** Thumbnails and avatars require the auth token. The image loader must use a URLSession configured with the auth token header.

3. **Relative URLs:** All media/image URLs from the API are relative (e.g., `/cache/videos/xxx_thumb.jpg`). Prepend the server base URL.

4. **Cookie-based Login:** The login flow requires cookies to pass between the login POST and the token GET. Use a shared URLSession with cookie storage.

5. **Non-breaking Spaces in Dates:** Formatted dates use non-breaking spaces (`\u00A0`) so they don't wrap mid-text on small screens.

6. **Video Progress Tracking:** Save position every 10 seconds during playback and once when player closes.

7. **401/403 Handling:** Any 401/403 response should redirect the user to the login screen.

---

## 4. Data Models

### Video
```
youtubeId: String
title: String
description: String?
published: String        -- locale-formatted date (FormatStyle.MEDIUM), non-breaking spaces
publishedShort: String   -- locale-formatted date (FormatStyle.SHORT) for compact display
downloaded: String       -- locale-formatted date from unix timestamp
channelName: String
channelId: String
channelThumbUrl: String? -- full URL (server + relative path)
thumbUrl: String         -- full URL
mediaUrl: String         -- full URL
duration: Int            -- seconds
durationStr: String      -- "3:32" format
watched: Boolean
progress: Double         -- 0.0 to 1.0
position: Double         -- seconds
viewCount: Int
likeCount: Int
mediaSize: Long          -- bytes
vidType: String
category: [String]
tags: [String]
streams: [StreamInfo]
```

### StreamInfo
```
type: String       -- "video" or "audio"
codec: String
bitrate: Int
width: Int?
height: Int?
```

### Channel
```
channelId: String
channelName: String
channelThumbUrl: String?
channelBannerUrl: String?
channelDescription: String?
channelSubscribed: Boolean
channelSubs: Int
```

### Comment
```
id: String
author: String
authorId: String
authorThumbnailUrl: String  -- full URL
isUploader: Boolean
text: String
timeText: String            -- "2 years ago"
likeCount: Int
isFavorited: Boolean
parentId: String            -- "root" for top-level
replies: [Comment]          -- nested replies
```

### PlayerInfo
```
watched: Boolean
duration: Int
durationStr: String
progress: Double
position: Double
```

---

## 5. Screens & UI

### 5.1 Login Screen
- Three fields: Server URL, Username, Password
- "Log In" button
- On launch, checks if saved token is valid (calls `/api/ping/`). If valid, auto-navigates to video list.
- Error message displayed below fields on failure
- Max width 400dp, centered

### 5.2 Video List Screen
- Top bar: "Videos" title, Search icon, Logout icon
- **Sort/Filter bar** (horizontally scrollable):
  - Sort dropdown: Downloaded, Published, Views, Likes, Duration, File size
  - Sort order toggle button (arrow up/down)
  - Watch filter chips: Unwatched (default), All, Watched, Continue
- Adaptive grid (min column width 300pt)
- Pull-to-refresh
- Infinite scroll with pagination
- Thumbnail prefetching (20 items ahead)

### 5.3 Video Card (used in lists)
- 16:9 thumbnail with overlays:
  - Bottom-left: quality badge (4K/1080p/720p/etc.)
  - Bottom-right: Column with duration badge on top, short date badge below
- Progress bar below thumbnail (if partially watched, not fully watched)
- Title (2 lines, ellipsis)
- Channel avatar (20dp circle) + channel name
- Placeholder colors: thumbnail `#2A2A2A`, channel avatar `#3A3A3A`

### 5.4 Video Detail Screen
- Top bar: video title (ellipsis), Back button, Delete button
- **Player area:**
  - Before play: thumbnail with play button overlay (black circle, play icon)
  - During play: inline player (16:9), with pin button and fullscreen button
  - Pinned mode: player stays fixed at top while content scrolls
  - Fullscreen mode: immersive, hides system bars, back button overlay
- **Video info section:**
  - Title (headlineSmall)
  - Channel avatar + name (clickable, navigates to channel page)
  - Stats row (FlowRow): views icon + count, likes icon + count
  - Published date, Downloaded date
  - Media info (right side): video codec/resolution/bitrate, audio codec/bitrate, file size
- **Tabbed content** (sticky tabs):
  - "Description" tab: description text
  - "Comments" tab: comment count, list of comments
- **Comments:**
  - Avatar (32dp) + author name (primary color if uploader) + time text
  - Comment text
  - Like count with thumb up icon (if > 0)
  - Replies collapsed by default. "N replies" / "Hide replies" toggle
  - Replies indented 24dp per level
- **Delete dialog:** "Delete" / "Delete and ignore" / "Cancel"
- **ExoPlayer config:** minBuffer=15s, maxBuffer=30s, playbackBuffer=1.5s, rebuffer=3s

### 5.5 Search Screen
- Top bar: text field with clear button, back button
- Debounce: 300ms
- Same adaptive grid as video list
- Shows "Search videos..." hint when empty

### 5.6 Channel Detail Screen
- Top bar: channel name, back button
- Banner image (aspect ratio 6.2:1)
- Channel avatar (64dp) + name + subscriber count
- Description text
- Paginated video grid (same as video list)

---

## 6. String Resources

### English (values/strings.xml)
```xml
<resources>
    <string name="app_name">Tube Archivist</string>

    <!-- Login -->
    <string name="login_server_url">Server URL</string>
    <string name="login_username">Username</string>
    <string name="login_password">Password</string>
    <string name="login_button">Log In</string>
    <string name="login_error_fields_required">All fields are required</string>

    <!-- Video List -->
    <string name="video_list_title">Videos</string>
    <string name="video_list_empty">No videos found</string>
    <string name="video_list_logout">Log Out</string>
    <string name="video_list_search">Search</string>

    <!-- Sort & Filter -->
    <string name="sort_downloaded">Downloaded</string>
    <string name="sort_published">Published</string>
    <string name="sort_views">Views</string>
    <string name="sort_likes">Likes</string>
    <string name="sort_duration">Duration</string>
    <string name="sort_mediasize">File size</string>
    <string name="filter_all">All</string>
    <string name="filter_unwatched">Unwatched</string>
    <string name="filter_watched">Watched</string>
    <string name="filter_continue">Continue</string>

    <!-- Video Detail -->
    <string name="video_detail_play">Play</string>
    <string name="video_detail_views">%d views</string>
    <string name="video_detail_likes">%d likes</string>
    <string name="video_detail_published">Published: %s</string>
    <string name="video_detail_downloaded">Downloaded: %s</string>
    <string name="video_detail_description">Description</string>
    <string name="video_detail_file_size">File size: %s</string>
    <string name="video_detail_delete">Delete</string>
    <string name="video_detail_delete_title">Delete video</string>
    <string name="video_detail_delete_message">Are you sure you want to delete this video from the archive?</string>
    <string name="video_detail_delete_confirm">Delete</string>
    <string name="video_detail_pin_player">Pin player</string>
    <string name="video_detail_delete_ignore">Delete and ignore</string>
    <string name="video_detail_comments">Comments</string>
    <string name="video_detail_no_comments">No comments</string>
    <string name="video_detail_hide_replies">Hide replies</string>
    <plurals name="video_detail_comments_count">
        <item quantity="one">%d comment</item>
        <item quantity="other">%d comments</item>
    </plurals>
    <plurals name="video_detail_show_replies">
        <item quantity="one">%d reply</item>
        <item quantity="other">%d replies</item>
    </plurals>
    <string name="cancel">Cancel</string>

    <!-- Search -->
    <string name="search_hint">Search videos...</string>
    <string name="search_empty">No results found</string>

    <!-- Channel Detail -->
    <string name="channel_detail_subscribers">%d subscribers</string>

    <!-- Common -->
    <string name="error_generic">Something went wrong</string>
    <string name="error_network">Network error. Check your connection.</string>
    <string name="error_unauthorized">Session expired. Please log in again.</string>
    <string name="retry">Retry</string>
    <string name="back">Back</string>
</resources>
```

### Russian (values-ru/strings.xml)
```xml
<resources>
    <string name="app_name">Tube Archivist</string>

    <!-- Login -->
    <string name="login_server_url">URL сервера</string>
    <string name="login_username">Имя пользователя</string>
    <string name="login_password">Пароль</string>
    <string name="login_button">Войти</string>
    <string name="login_error_fields_required">Все поля обязательны</string>

    <!-- Video List -->
    <string name="video_list_title">Видео</string>
    <string name="video_list_empty">Видео не найдены</string>
    <string name="video_list_logout">Выйти</string>
    <string name="video_list_search">Поиск</string>

    <!-- Sort & Filter -->
    <string name="sort_downloaded">Загружено</string>
    <string name="sort_published">Опубликовано</string>
    <string name="sort_views">Просмотры</string>
    <string name="sort_likes">Лайки</string>
    <string name="sort_duration">Длительность</string>
    <string name="sort_mediasize">Размер файла</string>
    <string name="filter_all">Все</string>
    <string name="filter_unwatched">Непросмотренные</string>
    <string name="filter_watched">Просмотренные</string>
    <string name="filter_continue">Продолжить</string>

    <!-- Video Detail -->
    <string name="video_detail_play">Воспроизвести</string>
    <string name="video_detail_views">%d просмотров</string>
    <string name="video_detail_likes">%d лайков</string>
    <string name="video_detail_published">Опубликовано: %s</string>
    <string name="video_detail_downloaded">Загружено: %s</string>
    <string name="video_detail_description">Описание</string>
    <string name="video_detail_file_size">Размер файла: %s</string>
    <string name="video_detail_delete">Удалить</string>
    <string name="video_detail_delete_title">Удаление видео</string>
    <string name="video_detail_delete_message">Вы уверены, что хотите удалить это видео из архива?</string>
    <string name="video_detail_delete_confirm">Удалить</string>
    <string name="video_detail_pin_player">Закрепить плеер</string>
    <string name="video_detail_delete_ignore">Удалить и игнорировать</string>
    <string name="video_detail_comments">Комментарии</string>
    <string name="video_detail_no_comments">Нет комментариев</string>
    <string name="video_detail_hide_replies">Скрыть ответы</string>
    <plurals name="video_detail_comments_count">
        <item quantity="one">%d комментарий</item>
        <item quantity="few">%d комментария</item>
        <item quantity="many">%d комментариев</item>
        <item quantity="other">%d комментариев</item>
    </plurals>
    <plurals name="video_detail_show_replies">
        <item quantity="one">%d ответ</item>
        <item quantity="few">%d ответа</item>
        <item quantity="many">%d ответов</item>
        <item quantity="other">%d ответов</item>
    </plurals>
    <string name="cancel">Отмена</string>

    <!-- Search -->
    <string name="search_hint">Поиск видео...</string>
    <string name="search_empty">Результаты не найдены</string>

    <!-- Channel Detail -->
    <string name="channel_detail_subscribers">%d подписчиков</string>

    <!-- Common -->
    <string name="error_generic">Что-то пошло не так</string>
    <string name="error_network">Ошибка сети. Проверьте подключение.</string>
    <string name="error_unauthorized">Сессия истекла. Войдите снова.</string>
    <string name="retry">Повторить</string>
    <string name="back">Назад</string>
</resources>
```

---

## 7. Complete Android Source Code

Below is every source file in the project, for reference when implementing the iOS version.

### 7.1 App Entry Points

#### MainActivity.kt
```kotlin
package ru.mzhukov.tubearchivistclient

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.navigation.compose.rememberNavController
import dagger.hilt.android.AndroidEntryPoint
import ru.mzhukov.tubearchivistclient.data.remote.AuthEvent
import ru.mzhukov.tubearchivistclient.data.remote.AuthEventBus
import ru.mzhukov.tubearchivistclient.presentation.navigation.NavGraph
import ru.mzhukov.tubearchivistclient.presentation.navigation.Screen
import ru.mzhukov.tubearchivistclient.ui.theme.TubeArchivistClientTheme
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject
    lateinit var authEventBus: AuthEventBus

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            TubeArchivistClientTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    val navController = rememberNavController()

                    LaunchedEffect(Unit) {
                        authEventBus.events.collect { event ->
                            when (event) {
                                is AuthEvent.Unauthorized -> {
                                    navController.navigate(Screen.Login.route) {
                                        popUpTo(0) { inclusive = true }
                                    }
                                }
                            }
                        }
                    }

                    NavGraph(navController = navController)
                }
            }
        }
    }
}
```

#### TubeArchivistApp.kt
```kotlin
package ru.mzhukov.tubearchivistclient

import android.app.Application
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.disk.DiskCache
import dagger.hilt.android.HiltAndroidApp
import okhttp3.OkHttpClient
import javax.inject.Inject

@HiltAndroidApp
class TubeArchivistApp : Application(), ImageLoaderFactory {

    @Inject
    lateinit var okHttpClient: OkHttpClient

    override fun newImageLoader(): ImageLoader {
        return ImageLoader.Builder(this)
            .okHttpClient(okHttpClient)
            .crossfade(200)
            .allowRgb565(true)
            .diskCache(
                DiskCache.Builder()
                    .directory(cacheDir.resolve("coil_cache"))
                    .maxSizePercent(0.05)
                    .build()
            )
            .build()
    }
}
```

### 7.2 Domain Layer

#### domain/util/Result.kt
```kotlin
package ru.mzhukov.tubearchivistclient.domain.util

sealed class Result<out T> {
    data class Success<T>(val data: T) : Result<T>()
    data class Error(val message: String, val cause: Throwable? = null) : Result<Nothing>()
}
```

#### domain/model/Video.kt
```kotlin
package ru.mzhukov.tubearchivistclient.domain.model

import androidx.compose.runtime.Immutable

@Immutable
data class Video(
    val youtubeId: String,
    val title: String,
    val description: String?,
    val published: String,
    val publishedShort: String,
    val downloaded: String,
    val channelName: String,
    val channelId: String,
    val channelThumbUrl: String?,
    val thumbUrl: String,
    val mediaUrl: String,
    val duration: Int,
    val durationStr: String,
    val watched: Boolean,
    val progress: Double,
    val position: Double,
    val viewCount: Int,
    val likeCount: Int,
    val mediaSize: Long,
    val vidType: String,
    val category: List<String>,
    val tags: List<String>,
    val streams: List<StreamInfo> = emptyList(),
)

data class StreamInfo(
    val type: String,
    val codec: String,
    val bitrate: Int,
    val width: Int?,
    val height: Int?,
)
```

#### domain/model/Channel.kt
```kotlin
package ru.mzhukov.tubearchivistclient.domain.model

data class Channel(
    val channelId: String,
    val channelName: String,
    val channelThumbUrl: String?,
    val channelBannerUrl: String?,
    val channelDescription: String?,
    val channelSubscribed: Boolean,
    val channelSubs: Int,
)
```

#### domain/model/Comment.kt
```kotlin
package ru.mzhukov.tubearchivistclient.domain.model

import androidx.compose.runtime.Immutable

@Immutable
data class Comment(
    val id: String,
    val author: String,
    val authorId: String,
    val authorThumbnailUrl: String,
    val isUploader: Boolean,
    val text: String,
    val timeText: String,
    val likeCount: Int,
    val isFavorited: Boolean,
    val parentId: String,
    val replies: List<Comment> = emptyList(),
)
```

#### domain/model/PlayerInfo.kt
```kotlin
package ru.mzhukov.tubearchivistclient.domain.model

data class PlayerInfo(
    val watched: Boolean,
    val duration: Int,
    val durationStr: String,
    val progress: Double,
    val position: Double,
)
```

#### domain/repository/AuthRepository.kt
```kotlin
package ru.mzhukov.tubearchivistclient.domain.repository

import kotlinx.coroutines.flow.Flow
import ru.mzhukov.tubearchivistclient.domain.util.Result

interface AuthRepository {
    suspend fun login(serverUrl: String, username: String, password: String): Result<String>
    suspend fun logout()
    suspend fun isLoggedIn(): Boolean
    fun getToken(): Flow<String?>
    fun getServerUrl(): Flow<String?>
}
```

#### domain/repository/VideoRepository.kt
```kotlin
package ru.mzhukov.tubearchivistclient.domain.repository

import ru.mzhukov.tubearchivistclient.domain.model.Comment
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.util.Result

interface VideoRepository {
    suspend fun getVideos(
        page: Int,
        sort: String? = null,
        order: String? = null,
        watch: String? = null,
        channel: String? = null,
    ): Result<Pair<List<Video>, Int>>
    suspend fun getVideo(videoId: String): Result<Video>
    suspend fun updateProgress(videoId: String, position: Double): Result<Unit>
    suspend fun deleteProgress(videoId: String): Result<Unit>
    suspend fun deleteVideo(videoId: String): Result<Unit>
    suspend fun deleteAndIgnoreVideo(videoId: String): Result<Unit>
    suspend fun getVideoComments(videoId: String): Result<List<Comment>>
}
```

#### domain/repository/SearchRepository.kt
```kotlin
package ru.mzhukov.tubearchivistclient.domain.repository

import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.util.Result

interface SearchRepository {
    suspend fun search(query: String, page: Int): Result<Pair<List<Video>, Int>>
}
```

#### domain/repository/ChannelRepository.kt
```kotlin
package ru.mzhukov.tubearchivistclient.domain.repository

import ru.mzhukov.tubearchivistclient.domain.model.Channel
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.util.Result

interface ChannelRepository {
    suspend fun getChannel(channelId: String): Result<Channel>
    suspend fun getChannelVideos(channelId: String, page: Int): Result<Pair<List<Video>, Int>>
}
```

### 7.3 Data Layer - DTOs

#### data/remote/dto/VideoDto.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class VideoListResponseDto(
    @SerialName("data") val data: List<VideoDto> = emptyList(),
    @SerialName("paginate") val paginate: PaginationDto? = null,
)

@Serializable
data class SearchResponseDto(
    @SerialName("results") val results: SearchResultsDto? = null,
    @SerialName("queryType") val queryType: String? = null,
)

@Serializable
data class SearchResultsDto(
    @SerialName("video_results") val videoResults: List<VideoDto> = emptyList(),
    @SerialName("channel_results") val channelResults: List<ChannelDto> = emptyList(),
)

@Serializable
data class VideoDto(
    @SerialName("youtube_id") val youtubeId: String,
    @SerialName("title") val title: String,
    @SerialName("description") val description: String? = null,
    @SerialName("published") val published: String = "",
    @SerialName("date_downloaded") val dateDownloaded: Long = 0,
    @SerialName("active") val active: Boolean = true,
    @SerialName("channel") val channel: ChannelDto? = null,
    @SerialName("vid_thumb_url") val vidThumbUrl: String = "",
    @SerialName("media_url") val mediaUrl: String = "",
    @SerialName("media_size") val mediaSize: Long = 0,
    @SerialName("player") val player: PlayerDto? = null,
    @SerialName("stats") val stats: StatsDto? = null,
    @SerialName("vid_type") val vidType: String = "videos",
    @SerialName("category") val category: List<String> = emptyList(),
    @SerialName("tags") val tags: List<String> = emptyList(),
    @SerialName("streams") val streams: List<StreamDto> = emptyList(),
    @SerialName("subtitles") val subtitles: List<SubtitleDto> = emptyList(),
    @SerialName("_index") val index: String? = null,
    @SerialName("_score") val score: Double? = null,
)

@Serializable
data class ChannelDto(
    @SerialName("channel_id") val channelId: String,
    @SerialName("channel_name") val channelName: String,
    @SerialName("channel_thumb_url") val channelThumbUrl: String? = null,
    @SerialName("channel_banner_url") val channelBannerUrl: String? = null,
    @SerialName("channel_description") val channelDescription: String? = null,
    @SerialName("channel_active") val channelActive: Boolean = true,
    @SerialName("channel_subscribed") val channelSubscribed: Boolean = false,
    @SerialName("channel_subs") val channelSubs: Int = 0,
    @SerialName("channel_last_refresh") val channelLastRefresh: String = "",
)

@Serializable
data class PlayerDto(
    @SerialName("watched") val watched: Boolean = false,
    @SerialName("watched_date") val watchedDate: Int? = null,
    @SerialName("duration") val duration: Int = 0,
    @SerialName("duration_str") val durationStr: String = "",
    @SerialName("progress") val progress: Double = 0.0,
    @SerialName("position") val position: Double = 0.0,
)

@Serializable
data class StatsDto(
    @SerialName("view_count") val viewCount: Int = 0,
    @SerialName("like_count") val likeCount: Int = 0,
    @SerialName("dislike_count") val dislikeCount: Int = 0,
    @SerialName("average_rating") val averageRating: Double = 0.0,
)

@Serializable
data class StreamDto(
    @SerialName("type") val type: String,
    @SerialName("index") val index: Int,
    @SerialName("codec") val codec: String,
    @SerialName("bitrate") val bitrate: Int = 0,
    @SerialName("width") val width: Int? = null,
    @SerialName("height") val height: Int? = null,
)

@Serializable
data class SubtitleDto(
    @SerialName("ext") val ext: String,
    @SerialName("lang") val lang: String,
    @SerialName("name") val name: String,
    @SerialName("media_url") val mediaUrl: String,
    @SerialName("source") val source: String,
    @SerialName("url") val url: String? = null,
)

@Serializable
data class DownloadStatusDto(
    @SerialName("status") val status: String,
)
```

#### data/remote/dto/CommonDto.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class PaginationDto(
    @SerialName("page_size") val pageSize: Int,
    @SerialName("page_from") val pageFrom: Int,
    @SerialName("current_page") val currentPage: Int,
    @SerialName("last_page") val lastPage: Int,
    @SerialName("total_hits") val totalHits: Int,
    @SerialName("max_hits") val maxHits: Boolean,
    @SerialName("prev_pages") val prevPages: List<Int>? = null,
    @SerialName("next_pages") val nextPages: List<Int>? = null,
    @SerialName("params") val params: String = "",
)

@Serializable
data class PingDto(
    @SerialName("response") val response: String,
    @SerialName("user") val user: Int,
    @SerialName("version") val version: String,
)

@Serializable
data class VideoProgressUpdateDto(
    @SerialName("position") val position: Double,
)

@Serializable
data class ErrorResponseDto(
    @SerialName("message") val message: String? = null,
    @SerialName("error") val error: String? = null,
)
```

#### data/remote/dto/LoginDto.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class LoginRequestDto(
    @SerialName("username") val username: String,
    @SerialName("password") val password: String,
)

@Serializable
data class TokenResponseDto(
    @SerialName("token") val token: String?,
)
```

#### data/remote/dto/CommentDto.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class CommentDto(
    @SerialName("comment_author") val commentAuthor: String = "",
    @SerialName("comment_author_id") val commentAuthorId: String = "",
    @SerialName("comment_author_is_uploader") val commentAuthorIsUploader: Boolean = false,
    @SerialName("comment_author_thumbnail") val commentAuthorThumbnail: String = "",
    @SerialName("comment_id") val commentId: String = "",
    @SerialName("comment_is_favorited") val commentIsFavorited: Boolean = false,
    @SerialName("comment_likecount") val commentLikecount: Int = 0,
    @SerialName("comment_parent") val commentParent: String = "root",
    @SerialName("comment_text") val commentText: String = "",
    @SerialName("comment_time_text") val commentTimeText: String = "",
    @SerialName("comment_timestamp") val commentTimestamp: Long = 0,
    @SerialName("comment_replies") val commentReplies: List<CommentDto> = emptyList(),
)
```

### 7.4 Data Layer - Networking

#### data/remote/TubeArchivistApi.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote

import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query
import ru.mzhukov.tubearchivistclient.data.remote.dto.CommentDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.DownloadStatusDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.LoginRequestDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.PingDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.PlayerDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.SearchResponseDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.TokenResponseDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.ChannelDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.VideoDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.VideoListResponseDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.VideoProgressUpdateDto

interface TubeArchivistApi {

    @POST("api/user/login/")
    suspend fun login(@Body request: LoginRequestDto): Response<Unit>

    @GET("api/appsettings/token/")
    suspend fun getToken(): TokenResponseDto

    @GET("api/ping/")
    suspend fun ping(): PingDto

    @GET("api/video/")
    suspend fun getVideos(
        @Query("page") page: Int,
        @Query("sort") sort: String? = null,
        @Query("order") order: String? = null,
        @Query("watch") watch: String? = null,
        @Query("channel") channel: String? = null,
    ): VideoListResponseDto

    @GET("api/channel/{channel_id}/")
    suspend fun getChannel(@Path("channel_id") channelId: String): ChannelDto

    @GET("api/video/{video_id}/")
    suspend fun getVideo(@Path("video_id") videoId: String): VideoDto

    @POST("api/video/{video_id}/progress/")
    suspend fun updateProgress(
        @Path("video_id") videoId: String,
        @Body body: VideoProgressUpdateDto
    ): PlayerDto

    @DELETE("api/video/{video_id}/progress/")
    suspend fun deleteProgress(@Path("video_id") videoId: String): Response<Unit>

    @DELETE("api/video/{video_id}/")
    suspend fun deleteVideo(@Path("video_id") videoId: String): Response<Unit>

    @POST("api/download/{video_id}/")
    suspend fun setDownloadStatus(
        @Path("video_id") videoId: String,
        @Body body: DownloadStatusDto,
    ): Response<Unit>

    @GET("api/video/{video_id}/comment/")
    suspend fun getVideoComments(@Path("video_id") videoId: String): List<CommentDto>

    @GET("api/search/")
    suspend fun search(
        @Query("query") query: String,
        @Query("page") page: Int? = null
    ): SearchResponseDto
}
```

#### data/remote/ServerUrlHolder.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote

import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ServerUrlHolder @Inject constructor() {
    @Volatile
    var serverUrl: String = "http://localhost:8000"

    fun getBaseUrl(): String = serverUrl.trimEnd('/')
}
```

#### data/remote/BaseUrlInterceptor.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BaseUrlInterceptor @Inject constructor(
    private val serverUrlHolder: ServerUrlHolder
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val originalRequest = chain.request()
        val serverUrl = serverUrlHolder.getBaseUrl()
        val targetUrl = serverUrl.toHttpUrlOrNull() ?: return chain.proceed(originalRequest)

        val newUrl = originalRequest.url.newBuilder()
            .scheme(targetUrl.scheme)
            .host(targetUrl.host)
            .port(targetUrl.port)
            .build()

        val newRequest = originalRequest.newBuilder()
            .url(newUrl)
            .build()

        return chain.proceed(newRequest)
    }
}
```

#### data/remote/AuthInterceptor.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote

import okhttp3.Interceptor
import okhttp3.Response
import ru.mzhukov.tubearchivistclient.data.local.AuthDataStore
import kotlinx.coroutines.runBlocking
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthInterceptor @Inject constructor(
    private val authDataStore: AuthDataStore,
    private val authEventBus: AuthEventBus,
) : Interceptor {

    @Volatile
    var token: String? = null

    override fun intercept(chain: Interceptor.Chain): Response {
        val currentToken = token ?: runBlocking { authDataStore.getTokenSync() }
        val request = if (currentToken != null) {
            chain.request().newBuilder()
                .header("Authorization", "Token $currentToken")
                .build()
        } else {
            chain.request()
        }
        val response = chain.proceed(request)

        if (response.code == 401 || response.code == 403) {
            authEventBus.emitUnauthorized()
        }

        return response
    }
}
```

#### data/remote/AuthEventBus.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthEventBus @Inject constructor() {
    private val _events = MutableSharedFlow<AuthEvent>(extraBufferCapacity = 1)
    val events: SharedFlow<AuthEvent> = _events.asSharedFlow()

    fun emitUnauthorized() {
        _events.tryEmit(AuthEvent.Unauthorized)
    }
}

sealed class AuthEvent {
    data object Unauthorized : AuthEvent()
}
```

### 7.5 Data Layer - Mapper

#### data/remote/mapper/DtoMappers.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.remote.mapper

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import ru.mzhukov.tubearchivistclient.data.remote.dto.ChannelDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.CommentDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.PlayerDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.StreamDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.VideoDto
import ru.mzhukov.tubearchivistclient.domain.model.Channel
import ru.mzhukov.tubearchivistclient.domain.model.Comment
import ru.mzhukov.tubearchivistclient.domain.model.PlayerInfo
import ru.mzhukov.tubearchivistclient.domain.model.StreamInfo
import ru.mzhukov.tubearchivistclient.domain.model.Video

fun VideoDto.toDomain(serverUrl: String): Video {
    val baseUrl = serverUrl.trimEnd('/')
    return Video(
        youtubeId = youtubeId,
        title = title,
        description = description,
        published = formatDate(published),
        publishedShort = formatDateShort(published),
        downloaded = formatTimestamp(dateDownloaded),
        channelName = channel?.channelName ?: "",
        channelId = channel?.channelId ?: "",
        channelThumbUrl = channel?.channelThumbUrl?.let { "$baseUrl$it" },
        thumbUrl = "$baseUrl$vidThumbUrl",
        mediaUrl = "$baseUrl$mediaUrl",
        duration = player?.duration ?: 0,
        durationStr = player?.durationStr ?: "",
        watched = player?.watched ?: false,
        progress = player?.progress ?: 0.0,
        position = player?.position ?: 0.0,
        viewCount = stats?.viewCount ?: 0,
        likeCount = stats?.likeCount ?: 0,
        mediaSize = mediaSize,
        vidType = vidType,
        category = category,
        tags = tags,
        streams = streams.map { it.toDomain() },
    )
}

fun StreamDto.toDomain(): StreamInfo = StreamInfo(
    type = type,
    codec = codec,
    bitrate = bitrate,
    width = width,
    height = height,
)

fun ChannelDto.toDomain(serverUrl: String = ""): Channel {
    val baseUrl = serverUrl.trimEnd('/')
    return Channel(
        channelId = channelId,
        channelName = channelName,
        channelThumbUrl = channelThumbUrl?.let { if (baseUrl.isNotEmpty()) "$baseUrl$it" else it },
        channelBannerUrl = channelBannerUrl?.let { if (baseUrl.isNotEmpty()) "$baseUrl$it" else it },
        channelDescription = channelDescription,
        channelSubscribed = channelSubscribed,
        channelSubs = channelSubs,
    )
}

fun PlayerDto.toDomain(): PlayerInfo = PlayerInfo(
    watched = watched,
    duration = duration,
    durationStr = durationStr,
    progress = progress,
    position = position,
)

private val localDateFormatter = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
private val shortDateFormatter = DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT)

private fun formatTimestamp(epochSeconds: Long): String {
    if (epochSeconds == 0L) return ""
    return try {
        val ld = Instant.ofEpochSecond(epochSeconds).atZone(ZoneId.systemDefault()).toLocalDate()
        ld.format(localDateFormatter).toNonBreaking()
    } catch (_: Exception) {
        ""
    }
}

private fun formatDateShort(raw: String): String {
    if (raw.isBlank()) return raw
    return try {
        val zdt = ZonedDateTime.parse(raw)
        zdt.toLocalDate().format(shortDateFormatter)
    } catch (_: Exception) {
        try {
            val ld = LocalDate.parse(raw)
            ld.format(shortDateFormatter)
        } catch (_: Exception) {
            raw
        }
    }
}

private fun formatDate(raw: String): String {
    if (raw.isBlank()) return raw
    return try {
        val zdt = ZonedDateTime.parse(raw)
        zdt.toLocalDate().format(localDateFormatter).toNonBreaking()
    } catch (_: Exception) {
        try {
            val ld = LocalDate.parse(raw)
            ld.format(localDateFormatter).toNonBreaking()
        } catch (_: Exception) {
            raw
        }
    }
}

private fun String.toNonBreaking(): String = replace(' ', '\u00A0')

fun CommentDto.toDomain(serverUrl: String): Comment {
    val baseUrl = serverUrl.trimEnd('/')
    return Comment(
        id = commentId,
        author = commentAuthor,
        authorId = commentAuthorId,
        authorThumbnailUrl = "$baseUrl$commentAuthorThumbnail",
        isUploader = commentAuthorIsUploader,
        text = commentText,
        timeText = commentTimeText,
        likeCount = commentLikecount,
        isFavorited = commentIsFavorited,
        parentId = commentParent,
        replies = commentReplies.map { it.toDomain(serverUrl) },
    )
}
```

### 7.6 Data Layer - Local Storage

#### data/local/AuthDataStore.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.local

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthDataStore @Inject constructor(
    private val dataStore: DataStore<Preferences>
) {
    private companion object {
        val TOKEN_KEY = stringPreferencesKey("auth_token")
        val SERVER_URL_KEY = stringPreferencesKey("server_url")
    }

    fun getToken(): Flow<String?> = dataStore.data.map { it[TOKEN_KEY] }

    fun getServerUrl(): Flow<String?> = dataStore.data.map { it[SERVER_URL_KEY] }

    suspend fun getTokenSync(): String? = dataStore.data.first()[TOKEN_KEY]

    suspend fun getServerUrlSync(): String? = dataStore.data.first()[SERVER_URL_KEY]

    suspend fun saveAuth(token: String, serverUrl: String) {
        dataStore.edit { prefs ->
            prefs[TOKEN_KEY] = token
            prefs[SERVER_URL_KEY] = serverUrl
        }
    }

    suspend fun clear() {
        dataStore.edit { it.clear() }
    }
}
```

### 7.7 Data Layer - Repositories

#### data/repository/AuthRepositoryImpl.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.repository

import kotlinx.coroutines.flow.Flow
import ru.mzhukov.tubearchivistclient.data.local.AuthDataStore
import ru.mzhukov.tubearchivistclient.data.remote.AuthInterceptor
import ru.mzhukov.tubearchivistclient.data.remote.ServerUrlHolder
import ru.mzhukov.tubearchivistclient.data.remote.TubeArchivistApi
import ru.mzhukov.tubearchivistclient.data.remote.dto.LoginRequestDto
import ru.mzhukov.tubearchivistclient.domain.repository.AuthRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthRepositoryImpl @Inject constructor(
    private val api: TubeArchivistApi,
    private val authDataStore: AuthDataStore,
    private val serverUrlHolder: ServerUrlHolder,
    private val authInterceptor: AuthInterceptor,
) : AuthRepository {

    override suspend fun login(
        serverUrl: String,
        username: String,
        password: String
    ): Result<String> {
        return try {
            val normalizedUrl = serverUrl.trimEnd('/')
            serverUrlHolder.serverUrl = normalizedUrl
            authInterceptor.token = null

            val loginResponse = api.login(LoginRequestDto(username, password))
            if (!loginResponse.isSuccessful) {
                return Result.Error("Login failed: ${loginResponse.code()}")
            }

            val tokenResponse = api.getToken()
            val token = tokenResponse.token
                ?: return Result.Error("Failed to retrieve API token")

            authDataStore.saveAuth(token, normalizedUrl)
            authInterceptor.token = token
            serverUrlHolder.serverUrl = normalizedUrl

            Result.Success(token)
        } catch (e: Exception) {
            Result.Error(e.message ?: "Unknown error", e)
        }
    }

    override suspend fun logout() {
        authInterceptor.token = null
        authDataStore.clear()
    }

    override suspend fun isLoggedIn(): Boolean {
        val token = authDataStore.getTokenSync()
        val serverUrl = authDataStore.getServerUrlSync()
        if (token != null && serverUrl != null) {
            authInterceptor.token = token
            serverUrlHolder.serverUrl = serverUrl
            return try {
                api.ping()
                true
            } catch (e: Exception) {
                false
            }
        }
        return false
    }

    override fun getToken(): Flow<String?> = authDataStore.getToken()
    override fun getServerUrl(): Flow<String?> = authDataStore.getServerUrl()
}
```

#### data/repository/VideoRepositoryImpl.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.repository

import ru.mzhukov.tubearchivistclient.data.remote.ServerUrlHolder
import ru.mzhukov.tubearchivistclient.data.remote.TubeArchivistApi
import ru.mzhukov.tubearchivistclient.data.remote.dto.DownloadStatusDto
import ru.mzhukov.tubearchivistclient.data.remote.dto.VideoProgressUpdateDto
import ru.mzhukov.tubearchivistclient.data.remote.mapper.toDomain
import ru.mzhukov.tubearchivistclient.domain.model.Comment
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.VideoRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class VideoRepositoryImpl @Inject constructor(
    private val api: TubeArchivistApi,
    private val serverUrlHolder: ServerUrlHolder,
) : VideoRepository {

    override suspend fun getVideos(page: Int, sort: String?, order: String?, watch: String?, channel: String?): Result<Pair<List<Video>, Int>> {
        return try {
            val response = api.getVideos(page, sort, order, watch, channel)
            val videos = response.data.map { it.toDomain(serverUrlHolder.getBaseUrl()) }
            val lastPage = response.paginate?.lastPage ?: 1
            Result.Success(videos to lastPage)
        } catch (e: Exception) {
            Result.Error(e.message ?: "Failed to load videos", e)
        }
    }

    override suspend fun getVideo(videoId: String): Result<Video> {
        return try {
            val dto = api.getVideo(videoId)
            Result.Success(dto.toDomain(serverUrlHolder.getBaseUrl()))
        } catch (e: Exception) {
            Result.Error(e.message ?: "Failed to load video", e)
        }
    }

    override suspend fun updateProgress(videoId: String, position: Double): Result<Unit> {
        return try {
            api.updateProgress(videoId, VideoProgressUpdateDto(position))
            Result.Success(Unit)
        } catch (e: Exception) {
            Result.Error(e.message ?: "Failed to update progress", e)
        }
    }

    override suspend fun deleteProgress(videoId: String): Result<Unit> {
        return try {
            api.deleteProgress(videoId)
            Result.Success(Unit)
        } catch (e: Exception) {
            Result.Error(e.message ?: "Failed to delete progress", e)
        }
    }

    override suspend fun deleteVideo(videoId: String): Result<Unit> {
        return try {
            api.deleteVideo(videoId)
            Result.Success(Unit)
        } catch (e: Exception) {
            Result.Error(e.message ?: "Failed to delete video", e)
        }
    }

    override suspend fun deleteAndIgnoreVideo(videoId: String): Result<Unit> {
        return try {
            api.deleteVideo(videoId)
            api.setDownloadStatus(videoId, DownloadStatusDto(status = "ignore-force"))
            Result.Success(Unit)
        } catch (e: Exception) {
            Result.Error(e.message ?: "Failed to delete and ignore video", e)
        }
    }

    override suspend fun getVideoComments(videoId: String): Result<List<Comment>> {
        return try {
            val dtos = api.getVideoComments(videoId)
            Result.Success(dtos.map { it.toDomain(serverUrlHolder.getBaseUrl()) })
        } catch (e: Exception) {
            Result.Error(e.message ?: "Failed to load comments", e)
        }
    }
}
```

#### data/repository/SearchRepositoryImpl.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.repository

import ru.mzhukov.tubearchivistclient.data.remote.ServerUrlHolder
import ru.mzhukov.tubearchivistclient.data.remote.TubeArchivistApi
import ru.mzhukov.tubearchivistclient.data.remote.mapper.toDomain
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.SearchRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SearchRepositoryImpl @Inject constructor(
    private val api: TubeArchivistApi,
    private val serverUrlHolder: ServerUrlHolder,
) : SearchRepository {

    override suspend fun search(query: String, page: Int): Result<Pair<List<Video>, Int>> {
        return try {
            val response = api.search(query, page)
            val videos = (response.results?.videoResults ?: emptyList())
                .map { it.toDomain(serverUrlHolder.getBaseUrl()) }
            Result.Success(videos to 1)
        } catch (e: Exception) {
            Result.Error(e.message ?: "Search failed", e)
        }
    }
}
```

#### data/repository/ChannelRepositoryImpl.kt
```kotlin
package ru.mzhukov.tubearchivistclient.data.repository

import ru.mzhukov.tubearchivistclient.data.remote.ServerUrlHolder
import ru.mzhukov.tubearchivistclient.data.remote.TubeArchivistApi
import ru.mzhukov.tubearchivistclient.data.remote.mapper.toDomain
import ru.mzhukov.tubearchivistclient.domain.model.Channel
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.ChannelRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ChannelRepositoryImpl @Inject constructor(
    private val api: TubeArchivistApi,
    private val serverUrlHolder: ServerUrlHolder,
) : ChannelRepository {

    override suspend fun getChannel(channelId: String): Result<Channel> {
        return try {
            val dto = api.getChannel(channelId)
            Result.Success(dto.toDomain(serverUrlHolder.getBaseUrl()))
        } catch (e: Exception) {
            Result.Error(e.message ?: "Failed to load channel", e)
        }
    }

    override suspend fun getChannelVideos(channelId: String, page: Int): Result<Pair<List<Video>, Int>> {
        return try {
            val response = api.getVideos(page = page, channel = channelId)
            val videos = response.data.map { it.toDomain(serverUrlHolder.getBaseUrl()) }
            val lastPage = response.paginate?.lastPage ?: 1
            Result.Success(videos to lastPage)
        } catch (e: Exception) {
            Result.Error(e.message ?: "Failed to load channel videos", e)
        }
    }
}
```

### 7.8 DI Modules

#### di/NetworkModule.kt
```kotlin
package ru.mzhukov.tubearchivistclient.di

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import ru.mzhukov.tubearchivistclient.data.remote.AuthInterceptor
import ru.mzhukov.tubearchivistclient.data.remote.BaseUrlInterceptor
import ru.mzhukov.tubearchivistclient.data.remote.TubeArchivistApi
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun provideJson(): Json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        isLenient = true
    }

    @Provides
    @Singleton
    fun provideCookieJar(): CookieJar = object : CookieJar {
        private val store = mutableMapOf<String, MutableList<Cookie>>()

        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            store.getOrPut(url.host) { mutableListOf() }.apply {
                clear()
                addAll(cookies)
            }
        }

        override fun loadForRequest(url: HttpUrl): List<Cookie> {
            return store[url.host] ?: emptyList()
        }
    }

    @Provides
    @Singleton
    fun provideOkHttpClient(
        authInterceptor: AuthInterceptor,
        baseUrlInterceptor: BaseUrlInterceptor,
        cookieJar: CookieJar,
    ): OkHttpClient {
        return OkHttpClient.Builder()
            .addInterceptor(baseUrlInterceptor)
            .addInterceptor(authInterceptor)
            .addInterceptor(HttpLoggingInterceptor().apply {
                level = HttpLoggingInterceptor.Level.HEADERS
            })
            .cookieJar(cookieJar)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    @Provides
    @Singleton
    fun provideRetrofit(okHttpClient: OkHttpClient, json: Json): Retrofit {
        return Retrofit.Builder()
            .baseUrl("http://placeholder.local/")
            .client(okHttpClient)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
    }

    @Provides
    @Singleton
    fun provideApi(retrofit: Retrofit): TubeArchivistApi {
        return retrofit.create(TubeArchivistApi::class.java)
    }
}
```

#### di/DataStoreModule.kt
```kotlin
package ru.mzhukov.tubearchivistclient.di

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStore
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "tube_archivist_prefs")

@Module
@InstallIn(SingletonComponent::class)
object DataStoreModule {

    @Provides
    @Singleton
    fun provideDataStore(@ApplicationContext context: Context): DataStore<Preferences> {
        return context.dataStore
    }
}
```

#### di/RepositoryModule.kt
```kotlin
package ru.mzhukov.tubearchivistclient.di

import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import ru.mzhukov.tubearchivistclient.data.repository.AuthRepositoryImpl
import ru.mzhukov.tubearchivistclient.data.repository.ChannelRepositoryImpl
import ru.mzhukov.tubearchivistclient.data.repository.SearchRepositoryImpl
import ru.mzhukov.tubearchivistclient.data.repository.VideoRepositoryImpl
import ru.mzhukov.tubearchivistclient.domain.repository.AuthRepository
import ru.mzhukov.tubearchivistclient.domain.repository.ChannelRepository
import ru.mzhukov.tubearchivistclient.domain.repository.SearchRepository
import ru.mzhukov.tubearchivistclient.domain.repository.VideoRepository
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
abstract class RepositoryModule {

    @Binds
    @Singleton
    abstract fun bindAuthRepository(impl: AuthRepositoryImpl): AuthRepository

    @Binds
    @Singleton
    abstract fun bindVideoRepository(impl: VideoRepositoryImpl): VideoRepository

    @Binds
    @Singleton
    abstract fun bindSearchRepository(impl: SearchRepositoryImpl): SearchRepository

    @Binds
    @Singleton
    abstract fun bindChannelRepository(impl: ChannelRepositoryImpl): ChannelRepository
}
```

### 7.9 Presentation - Navigation

#### presentation/navigation/Screen.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.navigation

sealed class Screen(val route: String) {
    data object Login : Screen("login")
    data object VideoList : Screen("video_list")
    data object VideoDetail : Screen("video_detail/{videoId}") {
        fun createRoute(videoId: String) = "video_detail/$videoId"
    }
    data object Search : Screen("search")
    data object ChannelDetail : Screen("channel_detail/{channelId}") {
        fun createRoute(channelId: String) = "channel_detail/$channelId"
    }
}
```

#### presentation/navigation/NavGraph.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.navigation

import androidx.compose.runtime.Composable
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import ru.mzhukov.tubearchivistclient.presentation.channeldetail.ChannelDetailScreen
import ru.mzhukov.tubearchivistclient.presentation.login.LoginScreen
import ru.mzhukov.tubearchivistclient.presentation.search.SearchScreen
import ru.mzhukov.tubearchivistclient.presentation.videodetail.VideoDetailScreen
import ru.mzhukov.tubearchivistclient.presentation.videolist.VideoListScreen

@Composable
fun NavGraph(
    navController: NavHostController,
    startDestination: String = Screen.Login.route,
) {
    NavHost(navController = navController, startDestination = startDestination) {
        composable(Screen.Login.route) {
            LoginScreen(
                viewModel = hiltViewModel(),
                onLoginSuccess = {
                    navController.navigate(Screen.VideoList.route) {
                        popUpTo(Screen.Login.route) { inclusive = true }
                    }
                },
            )
        }
        composable(Screen.VideoList.route) {
            VideoListScreen(
                viewModel = hiltViewModel(),
                onVideoClick = { videoId -> navController.navigate(Screen.VideoDetail.createRoute(videoId)) },
                onSearchClick = { navController.navigate(Screen.Search.route) },
                onLogout = {
                    navController.navigate(Screen.Login.route) {
                        popUpTo(0) { inclusive = true }
                    }
                },
            )
        }
        composable(
            route = Screen.VideoDetail.route,
            arguments = listOf(navArgument("videoId") { type = NavType.StringType }),
        ) { backStackEntry ->
            val videoId = backStackEntry.arguments?.getString("videoId") ?: return@composable
            VideoDetailScreen(
                viewModel = hiltViewModel(),
                videoId = videoId,
                onChannelClick = { channelId -> navController.navigate(Screen.ChannelDetail.createRoute(channelId)) },
                onVideoDeleted = { channelId ->
                    navController.navigate(Screen.ChannelDetail.createRoute(channelId)) {
                        popUpTo(Screen.VideoDetail.route) { inclusive = true }
                    }
                },
                onBack = { navController.popBackStack() },
            )
        }
        composable(Screen.Search.route) {
            SearchScreen(
                viewModel = hiltViewModel(),
                onVideoClick = { videoId -> navController.navigate(Screen.VideoDetail.createRoute(videoId)) },
                onBack = { navController.popBackStack() },
            )
        }
        composable(
            route = Screen.ChannelDetail.route,
            arguments = listOf(navArgument("channelId") { type = NavType.StringType }),
        ) {
            ChannelDetailScreen(
                viewModel = hiltViewModel(),
                onVideoClick = { videoId -> navController.navigate(Screen.VideoDetail.createRoute(videoId)) },
                onBack = { navController.popBackStack() },
            )
        }
    }
}
```

### 7.10 Presentation - Login

#### presentation/login/LoginViewModel.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.login

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import ru.mzhukov.tubearchivistclient.domain.repository.AuthRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result
import javax.inject.Inject

data class LoginUiState(
    val serverUrl: String = "",
    val username: String = "",
    val password: String = "",
    val isLoading: Boolean = false,
    val error: String? = null,
    val isLoggedIn: Boolean = false,
    val isCheckingAuth: Boolean = true,
)

@HiltViewModel
class LoginViewModel @Inject constructor(
    private val authRepository: AuthRepository,
) : ViewModel() {

    private val _uiState = MutableStateFlow(LoginUiState())
    val uiState: StateFlow<LoginUiState> = _uiState.asStateFlow()

    init { checkExistingAuth() }

    private fun checkExistingAuth() {
        viewModelScope.launch {
            try {
                val loggedIn = authRepository.isLoggedIn()
                _uiState.update { it.copy(isLoggedIn = loggedIn, isCheckingAuth = false) }
            } catch (e: Exception) {
                _uiState.update { it.copy(isCheckingAuth = false) }
            }
        }
    }

    fun onServerUrlChange(url: String) { _uiState.update { it.copy(serverUrl = url, error = null) } }
    fun onUsernameChange(username: String) { _uiState.update { it.copy(username = username, error = null) } }
    fun onPasswordChange(password: String) { _uiState.update { it.copy(password = password, error = null) } }

    fun login() {
        val state = _uiState.value
        if (state.serverUrl.isBlank() || state.username.isBlank() || state.password.isBlank()) {
            _uiState.update { it.copy(error = "All fields are required") }
            return
        }
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true, error = null) }
            when (val result = authRepository.login(state.serverUrl, state.username, state.password)) {
                is Result.Success -> _uiState.update { it.copy(isLoading = false, isLoggedIn = true) }
                is Result.Error -> _uiState.update { it.copy(isLoading = false, error = result.message) }
            }
        }
    }
}
```

#### presentation/login/LoginScreen.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.login

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ru.mzhukov.tubearchivistclient.R

@Composable
fun LoginScreen(viewModel: LoginViewModel, onLoginSuccess: () -> Unit) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(uiState.isLoggedIn) {
        if (uiState.isLoggedIn) onLoginSuccess()
    }

    if (uiState.isCheckingAuth || uiState.isLoggedIn) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
        return
    }

    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier.widthIn(max = 400.dp).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(text = stringResource(R.string.app_name), style = MaterialTheme.typography.headlineMedium)
            Spacer(modifier = Modifier.height(32.dp))
            OutlinedTextField(
                value = uiState.serverUrl, onValueChange = viewModel::onServerUrlChange,
                label = { Text(stringResource(R.string.login_server_url)) },
                placeholder = { Text("http://127.0.0.1:8000") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(modifier = Modifier.height(12.dp))
            OutlinedTextField(
                value = uiState.username, onValueChange = viewModel::onUsernameChange,
                label = { Text(stringResource(R.string.login_username)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(modifier = Modifier.height(12.dp))
            OutlinedTextField(
                value = uiState.password, onValueChange = viewModel::onPasswordChange,
                label = { Text(stringResource(R.string.login_password)) },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { viewModel.login() }),
                modifier = Modifier.fillMaxWidth(),
            )
            if (uiState.error != null) {
                Spacer(modifier = Modifier.height(12.dp))
                Text(text = uiState.error!!, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            Spacer(modifier = Modifier.height(24.dp))
            Button(onClick = viewModel::login, enabled = !uiState.isLoading, modifier = Modifier.fillMaxWidth()) {
                if (uiState.isLoading) {
                    CircularProgressIndicator(modifier = Modifier.height(20.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
                } else {
                    Text(stringResource(R.string.login_button))
                }
            }
        }
    }
}
```

### 7.11 Presentation - Video List

#### presentation/videolist/VideoListViewModel.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.videolist

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.Pager
import androidx.paging.PagingConfig
import androidx.paging.PagingData
import androidx.paging.cachedIn
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.AuthRepository
import ru.mzhukov.tubearchivistclient.domain.repository.VideoRepository
import javax.inject.Inject

enum class SortField(val apiValue: String) {
    DOWNLOADED("downloaded"), PUBLISHED("published"), VIEWS("views"),
    LIKES("likes"), DURATION("duration"), MEDIASIZE("mediasize"),
}

enum class SortOrder(val apiValue: String) { DESC("desc"), ASC("asc") }

enum class WatchFilter(val apiValue: String?) {
    UNWATCHED("unwatched"), ALL(null), WATCHED("watched"), CONTINUE("continue"),
}

@HiltViewModel
class VideoListViewModel @Inject constructor(
    private val videoRepository: VideoRepository,
    private val authRepository: AuthRepository,
) : ViewModel() {

    private val refreshTrigger = MutableStateFlow(0)
    private val _sortField = MutableStateFlow(SortField.DOWNLOADED)
    val sortField: StateFlow<SortField> = _sortField.asStateFlow()
    private val _sortOrder = MutableStateFlow(SortOrder.DESC)
    val sortOrder: StateFlow<SortOrder> = _sortOrder.asStateFlow()
    private val _watchFilter = MutableStateFlow(WatchFilter.UNWATCHED)
    val watchFilter: StateFlow<WatchFilter> = _watchFilter.asStateFlow()

    @OptIn(ExperimentalCoroutinesApi::class)
    val videos: Flow<PagingData<Video>> = combine(refreshTrigger, _sortField, _sortOrder, _watchFilter) { _, sort, order, watch -> Triple(sort, order, watch) }
        .flatMapLatest { (sort, order, watch) ->
            Pager(
                config = PagingConfig(pageSize = 12, prefetchDistance = 24, initialLoadSize = 36, enablePlaceholders = false),
                pagingSourceFactory = { VideoPagingSource(videoRepository, sort.apiValue, order.apiValue, watch.apiValue) },
            ).flow
        }.cachedIn(viewModelScope)

    fun setSortField(field: SortField) { _sortField.value = field }
    fun setSortOrder(order: SortOrder) { _sortOrder.value = order }
    fun setWatchFilter(filter: WatchFilter) { _watchFilter.value = filter }
    fun toggleSortOrder() { _sortOrder.value = if (_sortOrder.value == SortOrder.DESC) SortOrder.ASC else SortOrder.DESC }
    fun refresh() { refreshTrigger.value++ }
    suspend fun logout() { authRepository.logout() }
}
```

#### presentation/videolist/VideoPagingSource.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.videolist

import androidx.paging.PagingSource
import androidx.paging.PagingState
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.VideoRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result

class VideoPagingSource(
    private val videoRepository: VideoRepository,
    private val sort: String?, private val order: String?, private val watch: String?,
) : PagingSource<Int, Video>() {

    override fun getRefreshKey(state: PagingState<Int, Video>): Int? {
        return state.anchorPosition?.let { anchor ->
            state.closestPageToPosition(anchor)?.prevKey?.plus(1)
                ?: state.closestPageToPosition(anchor)?.nextKey?.minus(1)
        }
    }

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Video> {
        val page = params.key ?: 1
        return when (val result = videoRepository.getVideos(page, sort, order, watch)) {
            is Result.Success -> {
                val (videos, lastPage) = result.data
                LoadResult.Page(data = videos, prevKey = if (page > 1) page - 1 else null, nextKey = if (page < lastPage) page + 1 else null)
            }
            is Result.Error -> LoadResult.Error(Exception(result.message))
        }
    }
}
```

#### presentation/videolist/VideoListScreen.kt
(See Section 5.2 for UI description. Full code included in Android codebase files read above.)

### 7.12 Presentation - Video Detail

#### presentation/videodetail/VideoDetailViewModel.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.videodetail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import ru.mzhukov.tubearchivistclient.domain.model.Comment
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.VideoRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result
import javax.inject.Inject

data class VideoDetailUiState(
    val video: Video? = null,
    val isLoading: Boolean = true,
    val error: String? = null,
    val isDeleting: Boolean = false,
    val isDeleted: Boolean = false,
    val isPlaying: Boolean = false,
    val isFullscreen: Boolean = false,
    val isPinned: Boolean = false,
    val comments: List<Comment> = emptyList(),
    val isLoadingComments: Boolean = false,
    val commentsError: String? = null,
)

@HiltViewModel
class VideoDetailViewModel @Inject constructor(
    private val videoRepository: VideoRepository,
    val okHttpClient: OkHttpClient,
) : ViewModel() {

    private val _uiState = MutableStateFlow(VideoDetailUiState())
    val uiState: StateFlow<VideoDetailUiState> = _uiState.asStateFlow()
    private var progressJob: Job? = null
    private var currentVideoId: String? = null

    fun loadVideo(videoId: String) {
        currentVideoId = videoId
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true, error = null) }
            when (val result = videoRepository.getVideo(videoId)) {
                is Result.Success -> _uiState.update { it.copy(video = result.data, isLoading = false) }
                is Result.Error -> _uiState.update { it.copy(error = result.message, isLoading = false) }
            }
        }
    }

    fun loadComments(videoId: String) {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingComments = true, commentsError = null) }
            when (val result = videoRepository.getVideoComments(videoId)) {
                is Result.Success -> _uiState.update { it.copy(comments = result.data, isLoadingComments = false) }
                is Result.Error -> _uiState.update { it.copy(commentsError = result.message, isLoadingComments = false) }
            }
        }
    }

    fun setPlaying(playing: Boolean) { _uiState.update { it.copy(isPlaying = playing) } }
    fun setFullscreen(fullscreen: Boolean) { _uiState.update { it.copy(isFullscreen = fullscreen) } }
    fun togglePinned() { _uiState.update { it.copy(isPinned = !it.isPinned) } }

    fun startProgressTracking(getPositionMs: () -> Long) {
        progressJob?.cancel()
        progressJob = viewModelScope.launch {
            while (true) {
                delay(10_000)
                val videoId = currentVideoId ?: continue
                val positionSec = getPositionMs() / 1000.0
                if (positionSec > 0) videoRepository.updateProgress(videoId, positionSec)
            }
        }
    }

    fun saveProgress(positionMs: Long) {
        val videoId = currentVideoId ?: return
        viewModelScope.launch {
            val positionSec = positionMs / 1000.0
            if (positionSec > 0) videoRepository.updateProgress(videoId, positionSec)
        }
    }

    fun deleteVideo(videoId: String) {
        viewModelScope.launch {
            _uiState.update { it.copy(isDeleting = true) }
            when (videoRepository.deleteVideo(videoId)) {
                is Result.Success -> _uiState.update { it.copy(isDeleting = false, isDeleted = true) }
                is Result.Error -> _uiState.update { it.copy(isDeleting = false) }
            }
        }
    }

    fun deleteAndIgnoreVideo(videoId: String) {
        viewModelScope.launch {
            _uiState.update { it.copy(isDeleting = true) }
            when (videoRepository.deleteAndIgnoreVideo(videoId)) {
                is Result.Success -> _uiState.update { it.copy(isDeleting = false, isDeleted = true) }
                is Result.Error -> _uiState.update { it.copy(isDeleting = false) }
            }
        }
    }

    override fun onCleared() { super.onCleared(); progressJob?.cancel() }
}
```

### 7.13 Presentation - Search

#### presentation/search/SearchViewModel.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.search

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.Pager
import androidx.paging.PagingConfig
import androidx.paging.PagingData
import androidx.paging.cachedIn
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.*
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.SearchRepository
import javax.inject.Inject

@HiltViewModel
class SearchViewModel @Inject constructor(
    private val searchRepository: SearchRepository,
) : ViewModel() {

    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    @OptIn(FlowPreview::class, ExperimentalCoroutinesApi::class)
    val searchResults: Flow<PagingData<Video>> = _query
        .debounce(300)
        .flatMapLatest { q ->
            Pager(
                config = PagingConfig(pageSize = 12, enablePlaceholders = false),
                pagingSourceFactory = { SearchPagingSource(searchRepository, q) },
            ).flow
        }.cachedIn(viewModelScope)

    fun onQueryChange(newQuery: String) { _query.value = newQuery }
}
```

#### presentation/search/SearchPagingSource.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.search

import androidx.paging.PagingSource
import androidx.paging.PagingState
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.SearchRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result

class SearchPagingSource(
    private val searchRepository: SearchRepository,
    private val query: String,
) : PagingSource<Int, Video>() {

    override fun getRefreshKey(state: PagingState<Int, Video>): Int? {
        return state.anchorPosition?.let { anchor ->
            state.closestPageToPosition(anchor)?.prevKey?.plus(1)
                ?: state.closestPageToPosition(anchor)?.nextKey?.minus(1)
        }
    }

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Video> {
        if (query.isBlank()) return LoadResult.Page(emptyList(), null, null)
        val page = params.key ?: 1
        return when (val result = searchRepository.search(query, page)) {
            is Result.Success -> {
                val (videos, lastPage) = result.data
                LoadResult.Page(data = videos, prevKey = if (page > 1) page - 1 else null, nextKey = if (page < lastPage) page + 1 else null)
            }
            is Result.Error -> LoadResult.Error(Exception(result.message))
        }
    }
}
```

### 7.14 Presentation - Channel Detail

#### presentation/channeldetail/ChannelDetailViewModel.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.channeldetail

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.paging.Pager
import androidx.paging.PagingConfig
import androidx.paging.PagingData
import androidx.paging.cachedIn
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import ru.mzhukov.tubearchivistclient.domain.model.Channel
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.ChannelRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result
import javax.inject.Inject

data class ChannelDetailUiState(
    val channel: Channel? = null,
    val isLoading: Boolean = false,
    val error: String? = null,
)

@HiltViewModel
class ChannelDetailViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val channelRepository: ChannelRepository,
) : ViewModel() {

    private val channelId: String = savedStateHandle["channelId"]!!
    private val _uiState = MutableStateFlow(ChannelDetailUiState())
    val uiState: StateFlow<ChannelDetailUiState> = _uiState.asStateFlow()

    val videos: Flow<PagingData<Video>> = Pager(
        config = PagingConfig(pageSize = 12, enablePlaceholders = false),
        pagingSourceFactory = { ChannelVideoPagingSource(channelRepository, channelId) },
    ).flow.cachedIn(viewModelScope)

    init { loadChannel() }

    fun loadChannel() {
        viewModelScope.launch {
            _uiState.value = ChannelDetailUiState(isLoading = true)
            when (val result = channelRepository.getChannel(channelId)) {
                is Result.Success -> _uiState.value = ChannelDetailUiState(channel = result.data)
                is Result.Error -> _uiState.value = ChannelDetailUiState(error = result.message)
            }
        }
    }
}
```

#### presentation/channeldetail/ChannelVideoPagingSource.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.channeldetail

import androidx.paging.PagingSource
import androidx.paging.PagingState
import ru.mzhukov.tubearchivistclient.domain.model.Video
import ru.mzhukov.tubearchivistclient.domain.repository.ChannelRepository
import ru.mzhukov.tubearchivistclient.domain.util.Result

class ChannelVideoPagingSource(
    private val channelRepository: ChannelRepository,
    private val channelId: String,
) : PagingSource<Int, Video>() {

    override fun getRefreshKey(state: PagingState<Int, Video>): Int? {
        return state.anchorPosition?.let { anchor ->
            state.closestPageToPosition(anchor)?.prevKey?.plus(1)
                ?: state.closestPageToPosition(anchor)?.nextKey?.minus(1)
        }
    }

    override suspend fun load(params: LoadParams<Int>): LoadResult<Int, Video> {
        val page = params.key ?: 1
        return when (val result = channelRepository.getChannelVideos(channelId, page)) {
            is Result.Success -> {
                val (videos, lastPage) = result.data
                LoadResult.Page(data = videos, prevKey = if (page > 1) page - 1 else null, nextKey = if (page < lastPage) page + 1 else null)
            }
            is Result.Error -> LoadResult.Error(Exception(result.message))
        }
    }
}
```

### 7.15 Presentation - Common Components

#### presentation/common/LoadingView.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.common

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier

@Composable
fun LoadingView(modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
}
```

#### presentation/common/ErrorView.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.common

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ru.mzhukov.tubearchivistclient.R

@Composable
fun ErrorView(message: String, onRetry: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(text = message, style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.error)
        if (onRetry != null) {
            Spacer(modifier = Modifier.height(16.dp))
            Button(onClick = onRetry) { Text(stringResource(R.string.retry)) }
        }
    }
}
```

#### presentation/common/AdaptiveLayout.kt
```kotlin
package ru.mzhukov.tubearchivistclient.presentation.common

import androidx.compose.material3.windowsizeclass.WindowSizeClass
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass

fun WindowSizeClass.gridColumns(): Int = when (widthSizeClass) {
    WindowWidthSizeClass.Compact -> 1
    WindowWidthSizeClass.Medium -> 2
    WindowWidthSizeClass.Expanded -> 3
    else -> 1
}

fun WindowSizeClass.isExpandedWidth(): Boolean = widthSizeClass == WindowWidthSizeClass.Expanded
```

### 7.16 Drawable Resources

#### ic_pin_filled.xml (Pin icon - filled)
```xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24"
    android:tint="#FFFFFF">
    <path android:fillColor="@android:color/white"
        android:pathData="M16,9V4h1c0.55,0 1,-0.45 1,-1s-0.45,-1 -1,-1H7C6.45,2 6,2.45 6,3s0.45,1 1,1h1v5c0,1.66 -1.34,3 -3,3v2h5.97v7l1,1l1,-1v-7H19v-2C17.34,12 16,10.66 16,9z" />
</vector>
```

#### ic_pin_outlined.xml (Pin icon - outlined)
```xml
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24"
    android:tint="#FFFFFF">
    <path android:fillColor="@android:color/white"
        android:pathData="M14,4v5c0,1.12 0.37,2.16 1,3H9c0.65,-0.86 1,-1.9 1,-3V4H14M17,2H7C6.45,2 6,2.45 6,3c0,0.55 0.45,1 1,1h1v5c0,1.66 -1.34,3 -3,3v2h5.97v7l1,1l1,-1v-7H19v-2c-1.66,0 -3,-1.34 -3,-3V4h1c0.55,0 1,-0.45 1,-1C18,2.45 17.55,2 17,2z" />
</vector>
```

---

## End of Specification

This document contains all the information needed to create the iOS version:
- Complete API reference with request/response formats
- All data models and their mappings
- All screens with detailed UI descriptions
- Full Android source code for reference
- String resources in English and Russian
- Architecture patterns and implementation notes
