# Contributing

The most valuable contribution to this project is almost always the same one:
**a site changed its markup and a parser needs a new regular expression.** That
is the failure mode this codebase is built around, so it is worth describing how
to fix one properly.

## Getting set up

```bash
flutter pub get
flutter test          # 53 tests, no network
flutter run
```

Requires Flutter 3.47+ and JDK 17. Full details in
[docs/en/development.md](docs/en/development.md).

## Fixing a broken parser

1. **Find out where it broke.** The live check walks the whole chain and says
   whether the source or a player gave up:

   ```bash
   dart run tool/smoke.dart "Наруто"
   dart run tool/smoke.dart "Боруто" --source animedia
   ```

2. **Save the response that no longer parses** into `test/fixtures/`. Real
   payloads only — every existing fixture is a genuine response, which is what
   makes the test suite worth anything.

3. **Write the failing test first** in `test/players_test.dart` or
   `test/sources_test.dart`. `test/fake_http.dart` swaps the HTTP client out, so
   a test is a fixture plus an expectation.

4. **Then fix the pattern**, in `lib/anime/players/*.dart` or
   `lib/anime/sources/*.dart`.

5. Paste the smoke output before and after into the pull request.

## Adding a player or a catalog source

Both are small, well-bounded jobs — the interfaces and the steps are written out
in [docs/en/development.md](docs/en/development.md#adding-a-player).

The one thing to get right: return `VideoStream`s carrying the headers the CDN
demands. Those headers go unchanged into ExoPlayer and into the downloader, and
if they are wrong nothing downstream works.

## House style

* `flutter analyze` clean and `flutter test` green — CI checks both.
  There is deliberately no `dart format` gate: the code is hand-wrapped to read
  side by side with the Python library, so please match the surrounding style
  rather than running the formatter over a file.
* Comments and user-facing strings are in Russian, matching the app's audience.
  Documentation is bilingual — English first.
* Parsing stays regex-based, mirroring
  [anime-dl-core](https://github.com/ialakey/anime-dl-core), so a fix can be read
  across both repositories at once. Please do not introduce an HTML parser.
* Every error that can reach the screen should be a sentence a person can act on.
  The UI prints `error.toString()` with no post-processing, so the message *is*
  the user interface.

## What this project will not do

It has no server and no accounts, deliberately — that is the whole reason the
mobile port exists. Watch-together rooms, cross-device sync and push
notifications all need a backend and belong in
[anime-watch-together](https://github.com/ialakey/anime-watch-together) instead.

Please also do not add features whose purpose is to redistribute video. The app
reads what third-party players already serve, the same way a browser does, and
stores nothing for anyone else.
