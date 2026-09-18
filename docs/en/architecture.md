# Architecture

[English](../en/architecture.md) · [Русский](../ru/architecture.md)

The app is a single Flutter process with no backend of its own. It talks directly
to two catalog sites and to seven video players, and keeps everything else in
SQLite on the device.

---

## The one design decision everything follows from

The website this project comes from needs a server-side video proxy. Two reasons:

1. The CDN returns `403` unless the request carries a `Referer` header, and a
   browser will not attach that header to a `<video src>`.
2. The signed link the player hands out is bound to the IP that asked for it — on
   a website that is the server, not the viewer.

On a phone neither is a problem. Headers go straight into ExoPlayer through
`VideoPlayerController.networkUrl(url, httpHeaders: ...)`, and the device that
resolves the link is the device that plays it. That removes the server from the
picture entirely — and it is why the download queue can reuse exactly the same
headers the player got.

```
                    ┌──────────────────────────────────────────┐
                    │                  UI                      │
                    │  home · search · title · player ·        │
                    │  library · downloads · settings          │
                    └───────┬──────────────┬───────────────────┘
                            │              │
            ┌───────────────▼──┐        ┌──▼──────────────────┐
            │     Catalog      │        │  LibraryStore       │
            │  (facade + TTL)  │        │  DownloadManager    │
            └───┬──────────┬───┘        │  SettingsStore      │
                │          │            └──────────┬──────────┘
        ┌───────▼───┐  ┌───▼──────────┐            │
        │  sources  │  │ PlayerRegistry│           │
        │ animego   │  │ aniboom kodik │    ┌──────▼───────┐
        │ animedia  │  │ cvh sibnet …  │    │ sqflite +    │
        └───────┬───┘  └───┬───────────┘    │ SharedPrefs  │
                │          │                └──────────────┘
            ┌───▼──────────▼───┐
            │ AnimeHttpClient  │  dio · UA · proxy · timeouts
            └──────────────────┘
```

---

## Layers

### `lib/core` — plumbing

| File | Responsibility |
|---|---|
| `http.dart` | `AnimeHttpClient`: one dio instance, shared User-Agent, optional HTTP proxy, timeouts, redirect resolution, ranged streaming downloads. `HttpResponse` is what every parser consumes. |
| `errors.dart` | The error hierarchy, ported from the Python library. Every error carries a message meant for a human — screens print `error.toString()` as-is. |
| `utils.dart` | Regex helpers with readable failures, HTML entity unescaping, JSON from HTML attributes, HLS master-playlist parsing, and the Kodik Caesar/base64 cipher. |

Error types: `UnsupportedUrlError`, `NetworkError`, `ServiceError`,
`ExtractionError`, `NoStreamsFoundError`, `DecryptionError`,
`ContentBlockedError`, `NotFoundError` — all extending `AnimeError`.

### `lib/anime` — the anime-dl-core port

**`models.dart`**

* `VideoStream` — one video URL: `kind` (`hls` / `dash` / `mp4`), `quality`,
  `headers`, `extra`. `isMaster` marks an adaptive HLS playlist;
  `isDownloadable` is false for DASH and for anything with a separate audio track.
* `PlayerResult` — what a player returns: streams, title, poster, duration,
  translation, skip segments. `best()` picks the highest quality, breaking ties by
  container (mp4 > hls > dash).
* `SkipSegment` — an opening or ending the player told us about, in seconds.

**`registry.dart`** — `PlayerRegistry` holds one instance of each player, matches
a URL against their patterns, and delegates. `normalizeName()` maps the name the
catalog site uses onto our player key.

**`players/`** — one file per player, each a `BasePlayer` with `urlPatterns`,
`playbackHeaders` and `extract()`:

| Player | How it is parsed |
|---|---|
| **Aniboom** | `<video data-parameters="...">` holds escaped JSON with MPD and M3U8 links, poster, duration |
| **Kodik** | Page gives signed `urlParams`; the `/ftor` endpoint path is hidden in `app.player.*.js` or `app.serial.*.js`; the POST response is base64 with a Caesar shift, brute-forced |
| **CVH** | Numeric `cvh_id` from the iframe path; an open API returns a playlist of every episode and dub, then the tracks for one `vkId` |
| **Sibnet** | `shell.php?videoid=` embeds a relative mp4 path; the file needs `Referer` and redirects to a signed CDN address |
| **Animedia** | One `new Playerjs({file: ...})` line — a master playlist, a `[720]url1,[360]url2` record, or a JSON playlist |
| **AniLibria** | Not an embed at all: an open API returns HLS links at 480/720/1080 plus opening and ending timecodes. No token |
| **VK Video** | `video_ext.php` puts `apiPrefetchCache` into `window.cur`; the `video.get` entry has `mp4_144`…`mp4_2160`, `hls_ondemand`, `dash_ondemand`. The old `playerParams` format is handled too |

**`sources/`** — `AnimeGoSource` and `AnimediaSource` behind one `CatalogSource`
interface: `search()`, `card()`, `episodes()`, `players()`. Both return the same
`AnimeCard` / `PlayerOption`, so nothing above them cares which site answered.
Parsing is regex-based on purpose, exactly as in the Python library — no HTML
library is pulled in.

**`catalog.dart`** — the single entry point for the UI:

* TTL caches, with in-flight de-duplication so the same key is never fetched twice
  at once: search and episode lists 10 min, cards 30 min, resolved video links
  4 min (they expire fast).
* `details()` assembles a whole title page in one call.
* `pickPlayer()` falls back gracefully: exact key, then the same dub on another
  player, then whatever is first.
* `buildSource()` produces an `EpisodeSource` — the ordered stream list for
  playback (adaptive master first, then descending quality) plus `downloadable`,
  the best track that can actually be written to a single file.
* `_guard()` turns raw service errors into one sentence a user can act on.

### `lib/data` — local state

`AppDatabase` opens `mobile_anime.db` (schema version 1) with three tables:

```sql
watchlist(source, anime_id, title, poster_url, status, rating,
          episodes_total, last_episode, note, updated_at,
          PRIMARY KEY (source, anime_id))

progress(source, anime_id, episode, position, duration, completed,
         translation, player_key, updated_at,
         PRIMARY KEY (source, anime_id, episode))

downloads(id, source, anime_id, anime_title, poster_url, episode,
          translation, player_key, file_path, status, quality, kind,
          url, headers, received_bytes, total_bytes,
          segments_done, segments_total, error, created_at, updated_at,
          UNIQUE (source, anime_id, episode, translation))
```

* `LibraryStore` (a `ChangeNotifier`) — the port of the site's `tracking.py`, with
  "me" instead of a user id. Statuses, ratings, per-episode progress, and the
  "continue watching" query.
* `SettingsStore` — SharedPreferences, and the producer of `CatalogConfig`.

### `lib/services` — downloading

`EpisodeDownloader` writes an episode to one file without ffmpeg:

* **mp4** — streamed with `Range` so an interrupted file resumes where it stopped.
* **HLS** — the playlist is split into segments, fetched in order and appended to
  one file. Concatenated TS segments give a playable `.ts`; for fMP4 the
  `#EXT-X-MAP` initialisation segment is written first.
* It deliberately refuses `#EXT-X-KEY` encrypted playlists and split-audio
  variants, because neither can be assembled without re-encoding.

`DownloadManager` (a `ChangeNotifier`) is the queue: one task at a time, state in
SQLite. Because direct links expire in minutes, a task stores *what* to download
(title, episode, dub) rather than the URL — the link is re-resolved before every
start and every resume. On launch, anything left as `running` becomes `paused`,
since the process that was running it is gone.

### `lib/ui` — screens

`RootShell` is an `IndexedStack` of the four tabs, so tab state survives
switching. `provider` supplies `SettingsStore`, `LibraryStore`, `DownloadManager`
and `Catalog`; settings changes rebuild the catalog and hand the new instance to
the download manager.

The theme is seeded from `#7C5CFF`, Material 3, dark-first.

---

## Data flow: from a query to a playing video

```
SearchScreen
  └─ Catalog.search(query)              → source.search()      → AnimeCard[]
AnimeScreen
  └─ Catalog.details(id, episode)
       ├─ source.episodes(id)           → [1, 2, 3, …]
       ├─ source.players(id, episode)   → PlayerOption[]  (dub × player)
       └─ source.card(id)               → poster, genres, description
PlayerScreen
  └─ Catalog.buildSource(id, episode, playerKey)
       ├─ pickPlayer()                  → PlayerOption
       ├─ PlayerRegistry.extract(embed) → PlayerResult (streams + headers)
       └─ ordered streams               → VideoStream
  └─ VideoPlayerController.networkUrl(stream.url, httpHeaders: stream.headers)
```

Downloading takes the same path and then picks `EpisodeSource.downloadable`
instead of `preferred` — which is why an Aniboom episode is quietly fetched from
Kodik, CVH or Sibnet instead.

---

## Dependencies

| Package | Why |
|---|---|
| `dio` | Headers, proxy support, streamed responses for downloads |
| `html_unescape` | HTML entities inside site responses |
| `provider` | State distribution |
| `sqflite`, `path`, `path_provider` | Local database and file paths |
| `shared_preferences` | Settings |
| `video_player` | ExoPlayer with custom headers |
| `wakelock_plus` | Keep the screen on while watching |
| `cached_network_image` | Posters |

No HTML parser, no ffmpeg, no background-service plugin — each of those was left
out deliberately, and the limitations section of the README says what that costs.
