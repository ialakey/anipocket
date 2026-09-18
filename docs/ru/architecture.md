# Архитектура

[English](../en/architecture.md) · [Русский](../ru/architecture.md)

Приложение — один процесс Flutter без собственного бэкенда. Оно напрямую ходит в
два сайта-каталога и к семи плеерам, а всё остальное держит в sqlite на телефоне.

---

## Решение, из которого следует всё остальное

Сайту, с которого сделан этот порт, нужен серверный видеопрокси. Причины две:

1. CDN отвечает `403`, если в запросе нет `Referer`, а браузер такой заголовок из
   `<video src>` не пошлёт.
2. Подписанная ссылка привязана к IP того, кто её запросил, — на сайте это сервер,
   а не зритель.

На телефоне ни того, ни другого нет. Заголовки уходят прямо в ExoPlayer через
`VideoPlayerController.networkUrl(url, httpHeaders: ...)`, а получает и
использует ссылку одно и то же устройство. Это убирает сервер целиком — и заодно
позволяет очереди загрузок брать ровно те же заголовки, что получил плеер.

```
                    ┌──────────────────────────────────────────┐
                    │                интерфейс                 │
                    │  главная · поиск · тайтл · плеер ·       │
                    │  список · загрузки · настройки           │
                    └───────┬──────────────┬───────────────────┘
                            │              │
            ┌───────────────▼──┐        ┌──▼──────────────────┐
            │     Catalog      │        │  LibraryStore       │
            │  (фасад + TTL)   │        │  DownloadManager    │
            └───┬──────────┬───┘        │  SettingsStore      │
                │          │            └──────────┬──────────┘
        ┌───────▼───┐  ┌───▼───────────┐           │
        │ источники │  │ PlayerRegistry│    ┌──────▼───────┐
        │ animego   │  │ aniboom kodik │    │ sqflite +    │
        │ animedia  │  │ cvh sibnet …  │    │ SharedPrefs  │
        └───────┬───┘  └───┬───────────┘    └──────────────┘
                │          │
            ┌───▼──────────▼───┐
            │ AnimeHttpClient  │  dio · UA · прокси · таймауты
            └──────────────────┘
```

---

## Слои

### `lib/core` — обвязка

| Файл | За что отвечает |
|---|---|
| `http.dart` | `AnimeHttpClient`: один dio, общий User-Agent, опциональный HTTP-прокси, таймауты, разворачивание редиректов, потоковая загрузка с `Range`. `HttpResponse` — то, что получают все парсеры |
| `errors.dart` | Иерархия ошибок, порт из python-библиотеки. В каждой — текст для человека: экраны печатают `error.toString()` как есть |
| `utils.dart` | Регулярки с понятными отказами, html-сущности, json из атрибутов, разбор master-плейлиста HLS и шифр Kodik (base64 + сдвиг Цезаря) |

Типы ошибок: `UnsupportedUrlError`, `NetworkError`, `ServiceError`,
`ExtractionError`, `NoStreamsFoundError`, `DecryptionError`,
`ContentBlockedError`, `NotFoundError` — все наследуют `AnimeError`.

### `lib/anime` — порт anime-dl-core

**`models.dart`**

* `VideoStream` — одна ссылка на видео: `kind` (`hls` / `dash` / `mp4`),
  `quality`, `headers`, `extra`. `isMaster` помечает адаптивный плейлист HLS,
  `isDownloadable` — false для DASH и для всего, где звук отдельной дорожкой.
* `PlayerResult` — то, что возвращает плеер: дорожки, название, постер,
  длительность, озвучка, отрезки для пропуска. `best()` берёт высшее качество, при
  равенстве — по контейнеру (mp4 > hls > dash).
* `SkipSegment` — опенинг или эндинг, о котором сообщил плеер, в секундах.

**`registry.dart`** — `PlayerRegistry` держит по одному экземпляру каждого плеера,
сопоставляет ссылку с их шаблонами и делегирует. `normalizeName()` переводит
название, которым плеер зовётся на сайте, в наш ключ.

**`players/`** — по файлу на плеер, каждый наследует `BasePlayer` и реализует
`urlPatterns`, `playbackHeaders` и `extract()`:

| Плеер | Как разбирается |
|---|---|
| **Aniboom** | В `<video data-parameters="...">` лежит экранированный json со ссылками на MPD и M3U8, постером и длительностью |
| **Kodik** | Страница отдаёт подписанные `urlParams`; адрес `/ftor` спрятан в `app.player.*.js` или `app.serial.*.js`; ответ POST — base64 со сдвигом Цезаря, сдвиг перебирается |
| **CVH** | Числовой `cvh_id` из пути iframe; открытый API отдаёт плейлист всех серий и озвучек, затем дорожки по `vkId` одной серии |
| **Sibnet** | `shell.php?videoid=` несёт относительный путь к mp4; файл отдаётся только с `Referer` и редиректит на подписанный адрес CDN |
| **Animedia** | Одна строка `new Playerjs({file: ...})` — master-плейлист, запись `[720]url1,[360]url2` или json-плейлист |
| **AniLibria** | Вообще не embed: открытый API отдаёт HLS 480/720/1080 плюс таймкоды опенинга и эндинга. Токен не нужен |
| **VK Video** | `video_ext.php` кладёт `apiPrefetchCache` в `window.cur`; в ответе `video.get` есть `mp4_144`…`mp4_2160`, `hls_ondemand`, `dash_ondemand`. Старый формат `playerParams` тоже поддержан |

**`sources/`** — `AnimeGoSource` и `AnimediaSource` за одним интерфейсом
`CatalogSource`: `search()`, `card()`, `episodes()`, `players()`. Оба отдают
одинаковые `AnimeCard` / `PlayerOption`, поэтому всему, что выше, безразлично,
какой сайт ответил. Разбор — регулярками, намеренно, как в python-библиотеке:
html-библиотека не подключается.

**`catalog.dart`** — единственная точка входа для интерфейса:

* TTL-кэши с дедупликацией параллельных запросов (один ключ не запрашивается
  дважды одновременно): поиск и списки серий — 10 минут, карточки — 30 минут,
  готовые ссылки на видео — 4 минуты (они быстро протухают).
* `details()` собирает страницу тайтла целиком за один вызов.
* `pickPlayer()` мягко откатывается: точный ключ → та же озвучка на другом плеере
  → первый доступный.
* `buildSource()` собирает `EpisodeSource` — упорядоченные дорожки для просмотра
  (сначала адаптивный master, дальше по убыванию качества) плюс `downloadable`:
  лучшую дорожку, которую реально можно записать в один файл.
* `_guard()` превращает сырые ошибки сервиса в одну фразу, с которой человеку
  понятно, что делать.

### `lib/data` — локальное состояние

`AppDatabase` открывает `mobile_anime.db` (версия схемы 1) с тремя таблицами:

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

* `LibraryStore` (`ChangeNotifier`) — порт серверного `tracking.py`, только вместо
  пользователя есть просто «я». Статусы, оценки, прогресс по сериям и выборка
  «продолжить просмотр».
* `SettingsStore` — SharedPreferences и источник `CatalogConfig`.

### `lib/services` — скачивание

`EpisodeDownloader` пишет серию в один файл без ffmpeg:

* **mp4** — потоком с `Range`, поэтому оборванный файл докачивается с того места,
  где остановился.
* **HLS** — плейлист разбирается на сегменты, они качаются подряд и дописываются в
  один файл. Склейка TS даёт рабочий `.ts`; для fMP4 в начало пишется
  инициализирующий сегмент `#EXT-X-MAP`.
* Намеренно отказывается от зашифрованных плейлистов (`#EXT-X-KEY`) и вариантов с
  раздельным звуком: ни то, ни другое не собрать без перекодирования.

`DownloadManager` (`ChangeNotifier`) — очередь: по одному заданию за раз,
состояние в sqlite. Прямые ссылки живут минуты, поэтому задание хранит *что*
качаем (тайтл, серия, озвучка), а не URL: ссылка берётся заново перед каждым
стартом и каждой докачкой. При запуске всё, что осталось в статусе `running`,
переводится в `paused` — процесса-то, который его вёл, уже нет.

### `lib/ui` — экраны

`RootShell` — `IndexedStack` из четырёх вкладок, поэтому состояние вкладки
переживает переключение. `provider` раздаёт `SettingsStore`, `LibraryStore`,
`DownloadManager` и `Catalog`; смена настроек пересобирает каталог и отдаёт новый
экземпляр менеджеру загрузок.

Тема строится от `#7C5CFF`, Material 3, с прицелом на тёмную.

---

## Поток данных: от запроса до играющего видео

```
SearchScreen
  └─ Catalog.search(query)              → source.search()      → AnimeCard[]
AnimeScreen
  └─ Catalog.details(id, episode)
       ├─ source.episodes(id)           → [1, 2, 3, …]
       ├─ source.players(id, episode)   → PlayerOption[]  (озвучка × плеер)
       └─ source.card(id)               → постер, жанры, описание
PlayerScreen
  └─ Catalog.buildSource(id, episode, playerKey)
       ├─ pickPlayer()                  → PlayerOption
       ├─ PlayerRegistry.extract(embed) → PlayerResult (дорожки + заголовки)
       └─ упорядоченные дорожки         → VideoStream
  └─ VideoPlayerController.networkUrl(stream.url, httpHeaders: stream.headers)
```

Скачивание идёт тем же путём, но берёт `EpisodeSource.downloadable` вместо
`preferred` — именно поэтому серия с Aniboom тихо докачивается с Kodik, CVH или
Sibnet.

---

## Зависимости

| Пакет | Зачем |
|---|---|
| `dio` | Заголовки, прокси, потоковые ответы для скачивания |
| `html_unescape` | html-сущности в ответах сайтов |
| `provider` | Раздача состояния |
| `sqflite`, `path`, `path_provider` | Локальная база и пути к файлам |
| `shared_preferences` | Настройки |
| `video_player` | ExoPlayer со своими заголовками |
| `wakelock_plus` | Не гасить экран во время просмотра |
| `cached_network_image` | Постеры |

Ни html-парсера, ни ffmpeg, ни плагина фоновой службы — каждое из этого не взято
намеренно, а чего это стоит, написано в разделе ограничений в README.
