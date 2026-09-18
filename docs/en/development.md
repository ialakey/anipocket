# Development

[English](../en/development.md) · [Русский](../ru/development.md)

## Requirements

| Tool | Version |
|---|---|
| Flutter | 3.47 or newer (stable) |
| Dart | 3.13 (ships with that Flutter) |
| Android SDK | compileSdk / targetSdk come from the Flutter Gradle plugin |
| JDK | 17 (`sourceCompatibility` / `jvmTarget` are pinned to 17) |

`flutter doctor` should be clean for the Android toolchain. iOS is not covered:
the `ios/` folder is generated but has never been built or tested.

## Getting started

```bash
flutter pub get
flutter devices            # find a device or emulator id
flutter run -d <device>
```

To run on an Android emulator from scratch:

```bash
flutter emulators                                # list available AVDs
flutter emulators --launch <emulator_id>
flutter run -d emulator-5554
```

## Project layout

```
lib/
├── main.dart              entry point: stores, catalog, download queue, providers
├── app.dart               MaterialApp and the four-tab shell
├── core/
│   ├── http.dart          AnimeHttpClient (dio), HttpResponse
│   ├── errors.dart        AnimeError hierarchy
│   └── utils.dart         regex helpers, HLS parsing, Kodik cipher
├── anime/
│   ├── models.dart        VideoStream, PlayerResult, SkipSegment
│   ├── registry.dart      PlayerRegistry
│   ├── catalog.dart       Catalog facade, CatalogConfig, EpisodeSource
│   ├── players/           one file per player
│   └── sources/           animego.dart, animedia_site.dart, source.dart
├── data/
│   ├── database.dart      sqflite schema
│   ├── models.dart        WatchlistEntry, EpisodeProgress, DownloadTask
│   ├── library_store.dart watchlist and progress
│   └── settings_store.dart
├── services/
│   ├── downloader.dart    EpisodeDownloader (mp4 resume, HLS concatenation)
│   └── download_manager.dart  the queue
└── ui/                    one file per screen, plus theme.dart and widgets/
test/
├── fixtures/              real saved responses from every player
├── players_test.dart      parsing, per player
├── sources_test.dart      AnimeGO and Animedia parsing
├── downloader_test.dart   mp4 resume, HLS concatenation, refusals
├── utils_test.dart        helpers and stream selection
└── fake_http.dart         an AnimeHttpClient that never touches the network
tool/
└── smoke.dart             live end-to-end check against the real sites
```

## Tests

```bash
flutter test
```

53 tests, none of which touch the network. Player parsing runs against the same
saved responses the Python library uses — `test/fixtures/` holds genuine Aniboom,
Kodik, CVH, Sibnet, AniLibria, VK and Animedia payloads, including an encrypted
Kodik response. The downloader is covered separately: mp4 resume, HLS
concatenation, fMP4 initialisation, and the deliberate refusals on encrypted
segments and split audio.

`fake_http.dart` substitutes the HTTP client, so a test is a fixture plus an
expectation — adding a case for a newly broken site means saving its response and
writing the assertion.

### Live smoke check

Kept out of `flutter test` because it hits the real sites:

```bash
dart run tool/smoke.dart "Магическая битва"
dart run tool/smoke.dart "Боруто" --source animedia
dart run tool/smoke.dart "Наруто" --mirror animego.me
dart run tool/smoke.dart "Наруто" --proxy 127.0.0.1:8080
```

It walks search → episodes → players → direct links and then pulls the first
bytes from the CDN, so you can see whether the headers were accepted and the file
is actually being served. When something is broken, the output shows exactly
where: at the source or at a player.

## Linting

```bash
flutter analyze
```

`analysis_options.yaml` builds on `flutter_lints`.

## Builds

```bash
flutter build apk --debug           # for driving on an emulator
flutter build apk --release         # one APK, ~54 MB, all ABIs
flutter build apk --split-per-abi   # ~18 MB per architecture
flutter build appbundle             # AAB for the Play Store
```

Release builds are currently signed with the debug keystore
(`android/app/build.gradle.kts`) so that `flutter run --release` works out of the
box. Replace `signingConfig` before distributing anything.

The application id is `com.mobileanime.mobile_anime`.

## Driving the app on an emulator

Useful when capturing screenshots or reproducing a report:

```bash
adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.mobileanime.mobile_anime/.MainActivity
adb exec-out screencap -p > shot.png
adb shell cmd uimode night yes          # dark theme
adb shell input tap <x> <y>
adb shell input text "Naruto"
adb logcat -s flutter                   # app logs
```

The screenshots in `docs/screenshots/` were captured exactly this way on an
Android 16 (API 36) emulator at 1080×2400, then downscaled to a 1600 px long
side for the repository.

## Releases

Releases are cut by tagging a commit. Everything after that is
[`.github/workflows/release.yml`](../../.github/workflows/release.yml):

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

The workflow runs the tests, builds a universal APK plus one per ABI, signs them
with the project release key, checks with `apksigner` that the signature really
is the release key and not the debug fallback, writes `SHA256SUMS.txt`, attaches
a Sigstore provenance attestation and publishes the GitHub release.

The attestation is the security property worth understanding: it binds each APK
to the exact commit, workflow file and runner that produced it, and it is signed
through Sigstore rather than by a human. Nobody — including whoever holds the
repository token — can attach a hand-built APK to a release and have it verify:

```bash
gh attestation verify anipocket-1.0.0-arm64-v8a.apk -R ialakey/anipocket
sha256sum -c SHA256SUMS.txt --ignore-missing
```

### Setting up signing, once

```bash
bash tool/make-keystore.sh
```

It generates `android/release.jks` and `android/key.properties` — both
gitignored, and the key never leaves your machine — then prints the four
repository secrets to create:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 android/release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | The keystore password |
| `ANDROID_KEY_ALIAS` | `anipocket` |
| `ANDROID_KEY_PASSWORD` | The key password |

Back the `.jks` up somewhere safe. Losing it means Android will refuse every
future update as a different app, and there is no way to recover from that.

Until those secrets exist the release workflow stops immediately with a message
naming the ones it is missing, rather than quietly shipping a debug-signed APK.
A local `flutter build apk --release` on a fresh clone still works — it falls
back to the debug key and says so in the build log.

## Adding a player

1. Create `lib/anime/players/<name>.dart` extending `BasePlayer`; implement
   `name`, `title`, `urlPatterns`, `playbackHeaders` and `extract()`.
2. Register it in `PlayerRegistry`'s constructor list (order matters — the first
   matching pattern wins).
3. Teach `PlayerRegistry.normalizeName()` how the catalog site spells it.
4. Save a real response into `test/fixtures/` and add a case to
   `players_test.dart`.

Return `VideoStream`s with the headers the CDN demands — they travel unchanged
into ExoPlayer and into the downloader, so getting them right here is what makes
playback work everywhere else.

## Adding a catalog source

Implement `CatalogSource` (`search`, `card`, `episodes`, `players`) in
`lib/anime/sources/`, wire it into `Catalog._rebuild()`, add the option to
`SettingsScreen`, and cover the parsing in `sources_test.dart`.

## Conventions

* Comments and user-facing strings are in Russian, matching the app's audience.
* Parsing is regex-based, mirroring the Python library, so a fix can be read
  across both repositories at once.
* Every error reaching the UI is a sentence a person can act on; screens print
  `error.toString()` without post-processing.
