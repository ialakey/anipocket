# Разработка

[English](../en/development.md) · [Русский](../ru/development.md)

## Что нужно

| Инструмент | Версия |
|---|---|
| Flutter | 3.47 или новее (stable) |
| Dart | 3.13 (идёт с этим Flutter) |
| Android SDK | compileSdk / targetSdk берутся из Flutter Gradle Plugin |
| JDK | 17 (`sourceCompatibility` и `jvmTarget` прибиты к 17) |

`flutter doctor` должен быть чистым по Android-тулчейну. iOS не покрыт: папка
`ios/` сгенерирована, но ни разу не собиралась и не проверялась.

## Запуск

```bash
flutter pub get
flutter devices            # найти id устройства или эмулятора
flutter run -d <device>
```

Запустить на эмуляторе Android с нуля:

```bash
flutter emulators                                # список доступных AVD
flutter emulators --launch <emulator_id>
flutter run -d emulator-5554
```

## Структура проекта

```
lib/
├── main.dart              точка входа: хранилища, каталог, очередь, провайдеры
├── app.dart               MaterialApp и оболочка с четырьмя вкладками
├── core/
│   ├── http.dart          AnimeHttpClient (dio), HttpResponse
│   ├── errors.dart        иерархия AnimeError
│   └── utils.dart         регулярки, разбор HLS, шифр Kodik
├── anime/
│   ├── models.dart        VideoStream, PlayerResult, SkipSegment
│   ├── registry.dart      PlayerRegistry
│   ├── catalog.dart       фасад Catalog, CatalogConfig, EpisodeSource
│   ├── players/           по файлу на плеер
│   └── sources/           animego.dart, animedia_site.dart, source.dart
├── data/
│   ├── database.dart      схема sqflite
│   ├── models.dart        WatchlistEntry, EpisodeProgress, DownloadTask
│   ├── library_store.dart список и прогресс
│   └── settings_store.dart
├── services/
│   ├── downloader.dart    EpisodeDownloader (докачка mp4, склейка HLS)
│   └── download_manager.dart  очередь
└── ui/                    по файлу на экран, плюс theme.dart и widgets/
test/
├── fixtures/              настоящие сохранённые ответы всех плееров
├── players_test.dart      разбор, по плеерам
├── sources_test.dart      разбор AnimeGO и Animedia
├── downloader_test.dart   докачка mp4, склейка HLS, отказы
├── utils_test.dart        помощники и выбор дорожки
└── fake_http.dart         AnimeHttpClient, который не ходит в сеть
tool/
└── smoke.dart             живая сквозная проверка по настоящим сайтам
```

## Тесты

```bash
flutter test
```

53 теста, сеть не трогается. Разбор плееров гоняется на тех же сохранённых
ответах, что и в python-библиотеке: в `test/fixtures/` лежат настоящие ответы
Aniboom, Kodik, CVH, Sibnet, AniLibria, VK и Animedia, включая зашифрованный ответ
Kodik. Загрузчик проверен отдельно: докачка mp4, склейка HLS, инициализация fMP4 и
намеренные отказы на зашифрованных сегментах и раздельном звуке.

`fake_http.dart` подменяет HTTP-клиент, поэтому тест — это фикстура плюс
ожидание: добавить случай для отвалившегося сайта значит сохранить его ответ и
написать проверку.

### Живая проверка

Не входит в `flutter test`, потому что ходит в настоящие сайты:

```bash
dart run tool/smoke.dart "Магическая битва"
dart run tool/smoke.dart "Боруто" --source animedia
dart run tool/smoke.dart "Наруто" --mirror animego.me
dart run tool/smoke.dart "Наруто" --proxy 127.0.0.1:8080
```

Скрипт проходит поиск → серии → плееры → прямые ссылки и дёргает первые байты у
CDN: видно, приняты ли заголовки и отдаётся ли файл. Когда что-то сломалось,
сразу понятно где — у источника или у плеера.

## Линтер

```bash
flutter analyze
```

`analysis_options.yaml` построен на `flutter_lints`.

## Сборка

```bash
flutter build apk --debug           # чтобы гонять на эмуляторе
flutter build apk --release         # один APK, ~54 МБ, все ABI
flutter build apk --split-per-abi   # ~18 МБ на архитектуру
flutter build appbundle             # AAB для Play Store
```

Релизная сборка сейчас подписывается debug-ключом
(`android/app/build.gradle.kts`), чтобы работал `flutter run --release`. Перед
распространением `signingConfig` надо заменить.

Идентификатор приложения — `io.github.ialakey.anipocket`.

## Управление приложением на эмуляторе

Пригождается, когда снимаешь скриншоты или воспроизводишь баг:

```bash
adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n io.github.ialakey.anipocket/.MainActivity
adb exec-out screencap -p > shot.png
adb shell cmd uimode night yes          # тёмная тема
adb shell input tap <x> <y>
adb shell input text "Naruto"
adb logcat -s flutter                   # логи приложения
```

Скриншоты в `docs/screenshots/` сняты ровно так — на эмуляторе Android 16
(API 36) с разрешением 1080×2400, а в репозитории уменьшены до 1600 px
по длинной стороне.

## Релизы

Релиз выпускается тегом на коммите. Дальше всё делает
[`.github/workflows/release.yml`](../../.github/workflows/release.yml):

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

Workflow гоняет тесты, собирает универсальный APK и по одному на каждую ABI,
подписывает их релизным ключом проекта, проверяет через `apksigner`, что подпись
именно релизная, а не отладочная запасная, пишет `SHA256SUMS.txt`, прикладывает
provenance-аттестацию Sigstore и публикует релиз на GitHub.

Аттестация — главное здесь с точки зрения безопасности: она привязывает каждый
APK к конкретному коммиту, файлу workflow и раннеру, из которых он собран, и
подписана через Sigstore, а не человеком. Никто — включая того, у кого есть токен
репозитория, — не сможет подложить в релиз собранный руками APK так, чтобы
проверка прошла:

```bash
gh attestation verify anipocket-1.0.0-arm64-v8a.apk -R ialakey/anipocket
sha256sum -c SHA256SUMS.txt --ignore-missing
```

### Настроить подпись, один раз

```bash
bash tool/make-keystore.sh
```

Скрипт создаёт `android/release.jks` и `android/key.properties` — оба в
gitignore, ключ никуда не уезжает с вашей машины — и печатает четыре секрета,
которые надо завести в репозитории:

| Секрет | Значение |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 android/release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Пароль хранилища |
| `ANDROID_KEY_PASSWORD` | Пароль ключа |

Сохраните `.jks` в надёжном месте. Потеряете — Android будет считать любое
следующее обновление другим приложением, и восстановить это никак нельзя.

Пока секретов нет, release-workflow сразу останавливается и называет, каких
именно не хватает, вместо того чтобы молча выпустить APK с отладочной подписью.
Локальный `flutter build apk --release` на свежем клоне при этом работает — он
откатывается на отладочный ключ и пишет об этом в лог сборки.

## Иконка приложения

Иконка не рисуется руками, а генерируется:

```bash
python tool/make-icon.py
```

`tool/make-icon.py` один раз описывает знак — карман с вырезанным треугольником
play — и из этой же геометрии выпускает все файлы: legacy- и round-PNG, пару
слоёв adaptive-иконки, монохромный слой для Android 13, все пятнадцать размеров
для iOS и `docs/icon.png`.

Что важно знать, если будете менять: слои adaptive-иконки — 108dp, но лаунчер
обрезает до **центральных 72dp** и маскирует именно их. Рисунок, подогнанный под
все 108dp, отлично смотрится в превью и обрезается на настоящем рабочем столе,
поэтому `foreground()` считает размер знака от тех самых 72dp. Проверять удобно
через `adaptive_preview()` — он обрезает так же, как лаунчер.

## Как добавить плеер

1. Создайте `lib/anime/players/<name>.dart`, наследующий `BasePlayer`;
   реализуйте `name`, `title`, `urlPatterns`, `playbackHeaders` и `extract()`.
2. Зарегистрируйте его в списке конструктора `PlayerRegistry` (порядок важен:
   срабатывает первый подходящий шаблон).
3. Научите `PlayerRegistry.normalizeName()` названию, которым его зовёт сайт.
4. Сохраните настоящий ответ в `test/fixtures/` и добавьте случай в
   `players_test.dart`.

Возвращайте `VideoStream` с теми заголовками, которых требует CDN: они без
изменений уезжают в ExoPlayer и в загрузчик, так что именно от них зависит, будет
ли всё остальное работать.

## Как добавить источник каталога

Реализуйте `CatalogSource` (`search`, `card`, `episodes`, `players`) в
`lib/anime/sources/`, подключите в `Catalog._rebuild()`, добавьте вариант в
`SettingsScreen` и покройте разбор в `sources_test.dart`.

## Договорённости

* Комментарии и строки интерфейса — на русском, под аудиторию приложения.
* Разбор — регулярками, как в python-библиотеке, чтобы правку можно было читать по
  обоим репозиториям сразу.
* Любая ошибка, доходящая до интерфейса, — фраза, с которой человеку понятно, что
  делать; экраны печатают `error.toString()` без обработки.
