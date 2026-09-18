# AniPocket

**Watch and download anime on your phone. No account, no server.**

[![CI](https://github.com/ialakey/anipocket/actions/workflows/ci.yml/badge.svg)](https://github.com/ialakey/anipocket/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ialakey/anipocket?sort=semver)](https://github.com/ialakey/anipocket/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/ialakey/anipocket/total)](https://github.com/ialakey/anipocket/releases)
[![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![License](https://img.shields.io/github/license/ialakey/anipocket)](LICENSE)

[English](README.md) · [Русский](README.ru.md)

A Flutter app that plays and downloads anime on your phone. **No sign-up, no
server, no accounts** — your list, ratings and watch progress live on the device
itself.

It is a mobile port of two Python projects:

* [anime-dl-core](https://github.com/ialakey/anime-dl-core) — a library that turns
  a player link into direct video URLs. **Rewritten in Dart**, it lives inside the
  app under [`lib/anime/`](lib/anime);
* [anime-watch-together](https://github.com/ialakey/anime-watch-together) — the
  website: catalog, personal list, episode tracking. The catalog, the list and
  the progress made it over; watch-together rooms did not — they need a server.

| Home | Search | Title page |
|---|---|---|
| ![Home](docs/screenshots/16-home-filled.jpg) | ![Search](docs/screenshots/03-search-results.jpg) | ![Title](docs/screenshots/04-anime-title.jpg) |

| Player | My list | Downloads |
|---|---|---|
| ![Player](docs/screenshots/11-player.png) | ![My list](docs/screenshots/15-library.png) | ![Downloads](docs/screenshots/14-downloads.png) |

> All screenshots are real captures from an Android 16 (API 36) emulator running
> against the live catalog — no mockups.

---

## Download

Grab the APK from the [latest release](https://github.com/ialakey/anipocket/releases/latest) —
`arm64-v8a` is the right build for essentially every phone made in the last decade.

There is no Play Store build: the app has no accounts, no server and nothing to
sell. Every APK is signed with the project release key and carries a Sigstore
provenance attestation binding it to the commit it was built from, so you can
check a download against this repository:

```bash
gh attestation verify anipocket-1.0.0-arm64-v8a.apk -R ialakey/anipocket
```

---

## Documentation

| Document | What is inside |
|---|---|
| [User guide](docs/en/user-guide.md) | Every screen, every control, with screenshots |
| [Architecture](docs/en/architecture.md) | Layers, data flow, players, database schema |
| [Development](docs/en/development.md) | Build, run, test, release, project layout |
| [Troubleshooting](docs/en/troubleshooting.md) | What breaks, why, and how to fix it |

Russian versions live in [`docs/ru/`](docs/ru). Every screenshot is listed in
[`docs/screenshots/INDEX.md`](docs/screenshots/INDEX.md).

---

## Why there is no server

The website needs a server-side video proxy, and not by choice: the CDN refuses
to serve a file without a `Referer` header, and a browser will not send that
header from a `<video src>`. On top of that, the link is bound to the IP that
requested it — that is, to the server.

A mobile app has neither limitation. `Referer` goes straight into ExoPlayer via
`VideoPlayerController.networkUrl(..., httpHeaders: ...)`, and the same phone
both requests and uses the link. So the app talks to the sites and the players
directly, and needs no infrastructure at all.

```
Phone ──► AnimeGO / Animedia ──► player links
  │
  ├──► Aniboom / Kodik / CVH / Sibnet / Animedia / AniLibria / VK ──► direct URLs
  │
  ├──► ExoPlayer (headers travel with the URL)
  └──► downloader (mp4 with resume, HLS by concatenating segments)
```

---

## What it does

**Watching**

* Catalog search: AnimeGO (default) or Animedia.
* Title page: poster, description, genres, episode list, dub and player picker.
* Full-screen player: ±10 s seeking, quality picker, dub switching on the fly,
  jump to the next episode, and a "skip the opening" button wherever the player
  exposes timecodes.
* Position is remembered; an episode is marked as watched past 85 % (configurable).

**Local library**

* Lists by status: watching, planned, completed, on hold, dropped.
* Personal ratings 1–10, an episode counter, "continue watching" on the home screen.
* Everything sits in SQLite on the phone. No auth, no sync.

**Downloads**

* Any episode to a file, one at a time, with pause and resume.
* A whole range of episodes with one button ("download several").
* Downloaded episodes play from the file and need no network.
* The queue survives an app restart.

---

## How the code is laid out

```
lib/
├── core/                HTTP client (dio), errors, html/m3u8 parsing, Kodik cipher
├── anime/               the anime-dl-core port
│   ├── models.dart      VideoStream, PlayerResult, SkipSegment
│   ├── registry.dart    picks the right player for a link
│   ├── players/         aniboom, kodik, cvh, sibnet, animedia, anilibria, vk
│   ├── sources/         AnimeGO and Animedia: search, episodes, player list
│   └── catalog.dart     facade with a TTL cache and stream selection
├── data/                SQLite, watchlist, progress, settings
├── services/            episode downloader and download queue
└── ui/                  screens: home, search, title, player, library, downloads
```

Class names and structure mirror the Python library, so a broken parser can be
fixed by reading both repositories side by side: when a player breaks, the fix is
a regular expression in the matching `lib/anime/players/*.dart`.

---

## Build

```bash
flutter pub get
flutter run                         # on a connected device or emulator
flutter build apk --release         # one APK, 54 MB (all ABIs in one file)
flutter build apk --split-per-abi   # one APK per architecture, ~18 MB each
```

Requires Flutter 3.47+ (Dart 3.13) and the Android SDK. The project builds for
Android; the `ios/` folder is generated but untested.

## Tests

```bash
flutter test
```

53 tests, no network involved: player parsing is checked against the same saved
responses the Python library uses (`test/fixtures/` holds real Aniboom, Kodik,
CVH, Sibnet, AniLibria, VK and Animedia responses, including an encrypted Kodik
payload). The downloader is covered separately: mp4 resume, HLS concatenation,
fMP4 initialisation, and the refusals on encrypted segments and split audio.

A live check (it hits the real sites, so it is kept out of `flutter test`):

```bash
dart run tool/smoke.dart "Магическая битва"
dart run tool/smoke.dart "Боруто" --source animedia
```

The script walks the whole chain — search, episodes, players, direct links — and
pulls the first bytes from the CDN, so you can see that the headers were accepted
and the file is being served.

---

## Limitations worth knowing about

* **Aniboom cannot be downloaded.** It serves fMP4 with audio on a separate track,
  and that cannot be merged into a single file without re-encoding. The app knows
  this: for downloading it picks the same episode from a different player (Kodik,
  CVH or Sibnet is almost always available next to it). Watching Aniboom still
  works — ExoPlayer handles split tracks on its own.
* **Encrypted HLS** (`#EXT-X-KEY`) cannot be downloaded, only watched.
* **Downloads run while the app is open.** No background service is started; the
  queue is saved and resumes on the next launch.
* **Files live in the app's internal folder** — no permissions needed, but
  uninstalling the app deletes the downloaded episodes too.
* **HTTP proxy only** (dio does not support SOCKS on Android).
* **Sites change their markup.** When search or a player breaks, the error will be
  specific ("could not find …"), and the fix is a regular expression in the
  matching file. An AnimeGO mirror or switching the source in settings often helps
  as well.
* Watch-together rooms, new-episode notifications and other users' profiles were
  not ported: all of that lives on a server.

### One difference from the Python library

In Kodik the endpoint path (`/ftor`) is hidden inside a page script. For
`/seria/...` links it is `app.player.*.js`, and for `/serial/...` it is
`app.serial.*.js`. The library grabs the first `app.player` it finds and therefore
breaks on series; here the scripts are tried in turn and the working one is
remembered ([`lib/anime/players/kodik.dart`](lib/anime/players/kodik.dart),
`_findPostPath`).

## Responsibility

The app stores nothing and serves nothing: it reads exactly what third-party
players have already published, the same way an ordinary browser does. What to do
with that is up to the owner of the phone.
