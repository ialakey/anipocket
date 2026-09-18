/// Очередь загрузок: одна серия за раз, состояние переживает перезапуск.
///
/// Прямые ссылки живут минуты, поэтому перед каждой (до)качкой менеджер снова
/// спрашивает у каталога свежую ссылку — в задании хранится не она, а «что
/// качаем»: тайтл, серия, озвучка.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../anime/catalog.dart';
import '../anime/models.dart';
import '../core/errors.dart';
import '../data/database.dart';
import '../data/models.dart';
import '../data/settings_store.dart';
import 'downloader.dart';

class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.database,
    required this.catalog,
    required this.settings,
  });

  final AppDatabase database;

  /// Каталог пересобирается при смене настроек сети — поле не final.
  Catalog catalog;
  final SettingsStore settings;

  Database get _db => database.db;

  List<DownloadTask> _tasks = const [];
  DownloadHandle? _handle;
  bool _working = false;

  List<DownloadTask> get tasks => _tasks;

  List<DownloadTask> get active => _tasks.where((task) => task.isActive).toList();

  List<DownloadTask> get completed =>
      _tasks.where((task) => task.status == DownloadStatus.done).toList();

  /// Подменяет каталог на пересобранный после смены настроек.
  void attachCatalog(Catalog value) => catalog = value;

  Future<void> load() async {
    // после перезапуска «качается» превращается в «пауза»: процесса-то нет
    await _db.update(
      'downloads',
      {'status': DownloadStatus.paused.value},
      where: 'status = ?',
      whereArgs: [DownloadStatus.running.value],
    );
    await _reload();
  }

  DownloadTask? findFor(String source, String animeId, int episode, String translation) {
    for (final task in _tasks) {
      if (task.source == source &&
          task.animeId == animeId &&
          task.episode == episode &&
          task.translation == translation) {
        return task;
      }
    }
    return null;
  }

  /// Готовая серия на диске, если она скачана.
  DownloadTask? downloadedEpisode(String source, String animeId, int episode) {
    for (final task in _tasks) {
      if (task.source == source &&
          task.animeId == animeId &&
          task.episode == episode &&
          task.status == DownloadStatus.done) {
        return task;
      }
    }
    return null;
  }

  /// Ставит серию в очередь. Повторный вызов на ту же серию ничего не ломает.
  Future<DownloadTask> enqueue({
    required AnimeCard card,
    required int episode,
    required String translation,
    required String playerKey,
  }) async {
    final existing = findFor(card.source, card.id, episode, translation);
    if (existing != null && existing.status != DownloadStatus.failed) {
      if (existing.status == DownloadStatus.paused) return resume(existing);
      return existing;
    }

    final directory = await _episodeDirectory(card);
    final task = DownloadTask(
      id: existing?.id,
      source: card.source,
      animeId: card.id,
      animeTitle: card.title,
      posterUrl: card.poster,
      episode: episode,
      translation: translation,
      playerKey: playerKey,
      filePath: p.join(directory, _fileName(episode, translation, 'mp4')),
      status: DownloadStatus.queued,
      createdAt: existing?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final id = await _db.insert(
      'downloads',
      task.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _reload();
    unawaited(_pump());
    return task.copyWith(id: id);
  }

  Future<DownloadTask> resume(DownloadTask task) async {
    await _save(task.copyWith(status: DownloadStatus.queued, clearError: true));
    unawaited(_pump());
    return task.copyWith(status: DownloadStatus.queued);
  }

  Future<void> pause(DownloadTask task) async {
    if (task.status == DownloadStatus.running) _handle?.cancel();
    await _save(task.copyWith(status: DownloadStatus.paused));
  }

  /// Убирает задание и, если просят, сам файл.
  Future<void> remove(DownloadTask task, {bool deleteFile = true}) async {
    if (task.status == DownloadStatus.running) _handle?.cancel();
    if (deleteFile) {
      final file = File(task.filePath);
      if (await file.exists()) await file.delete();
    }
    if (task.id != null) {
      await _db.delete('downloads', where: 'id = ?', whereArgs: [task.id]);
    }
    await _reload();
  }

  /// Ставит в очередь сразу несколько серий одной озвучкой.
  Future<void> enqueueRange({
    required AnimeCard card,
    required List<int> episodes,
    required String translation,
    required String playerKey,
  }) async {
    for (final episode in episodes) {
      await enqueue(
        card: card,
        episode: episode,
        translation: translation,
        playerKey: playerKey,
      );
    }
  }

  // -- сама очередь -------------------------------------------------------

  Future<void> _pump() async {
    if (_working) return;
    _working = true;
    try {
      while (true) {
        final next = _tasks.where((task) => task.status == DownloadStatus.queued).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        if (next.isEmpty) break;
        await _run(next.first);
      }
    } finally {
      _working = false;
    }
  }

  Future<void> _run(DownloadTask task) async {
    final handle = DownloadHandle();
    _handle = handle;
    await _save(task.copyWith(status: DownloadStatus.running, clearError: true));

    try {
      final picked = await _pickStream(task);
      final extension = picked.stream.kind == StreamKind.mp4 ? 'mp4' : 'ts';
      final directory = p.dirname(task.filePath);
      final filePath = p.join(
        directory,
        _fileName(task.episode, task.translation, extension),
      );

      // сменился плеер или качество — старый огрызок файла уже не подходит
      final changedTarget = filePath != task.filePath ||
          (task.quality != null && task.quality != picked.stream.quality);
      if (changedTarget) {
        final old = File(task.filePath);
        if (await old.exists()) await old.delete();
      }

      var current = task.copyWith(
        url: picked.stream.url,
        headers: picked.stream.headers,
        quality: picked.stream.quality,
        kind: picked.stream.kind == StreamKind.mp4 ? 'mp4' : 'hls',
        segmentsDone: changedTarget ? 0 : task.segmentsDone,
        receivedBytes: changedTarget ? 0 : task.receivedBytes,
      );
      current = _withPath(current, filePath);
      await _save(current);

      final downloader = EpisodeDownloader(catalog.client);
      var lastSaved = DateTime.now();

      void report(DownloadProgress progress) {
        current = current.copyWith(
          receivedBytes: progress.receivedBytes,
          totalBytes: progress.totalBytes ?? current.totalBytes,
          segmentsDone: progress.segmentsDone,
          segmentsTotal: progress.segmentsTotal ?? current.segmentsTotal,
        );
        _replaceInMemory(current);
        // в базу пишем не чаще раза в секунду: прогресс идёт сплошным потоком
        if (DateTime.now().difference(lastSaved) > const Duration(seconds: 1)) {
          lastSaved = DateTime.now();
          unawaited(_db.update(
            'downloads',
            current.toRow(),
            where: 'id = ?',
            whereArgs: [current.id],
          ));
        }
      }

      if (picked.stream.kind == StreamKind.mp4) {
        await downloader.downloadFile(
          url: picked.stream.url,
          headers: picked.stream.headers,
          filePath: filePath,
          handle: handle,
          onProgress: report,
        );
      } else {
        await downloader.downloadHls(
          url: picked.stream.url,
          headers: picked.stream.headers,
          filePath: filePath,
          handle: handle,
          onProgress: report,
          startSegment: changedTarget ? 0 : task.segmentsDone,
        );
      }

      await _save(current.copyWith(status: DownloadStatus.done));
    } on DownloadPaused catch (paused) {
      final stored = _byId(task.id) ?? task;
      await _save(
        stored.copyWith(
          status: DownloadStatus.paused,
          segmentsDone: paused.segmentsDone > 0 ? paused.segmentsDone : stored.segmentsDone,
        ),
      );
    } on AnimeError catch (error) {
      final stored = _byId(task.id) ?? task;
      await _save(stored.copyWith(status: DownloadStatus.failed, error: error.message));
    } catch (error) {
      final stored = _byId(task.id) ?? task;
      await _save(stored.copyWith(status: DownloadStatus.failed, error: '$error'));
    } finally {
      if (identical(_handle, handle)) _handle = null;
    }
  }

  /// Ищет дорожку, которую можно сохранить одним файлом.
  ///
  /// Сначала пробуем плеер, который выбрал зритель; если у него звук отдельным
  /// потоком (Aniboom) — идём по остальным плеерам этой серии.
  Future<_PickedStream> _pickStream(DownloadTask task) async {
    final options = await catalog.players(task.animeId, task.episode);
    if (options.isEmpty) {
      throw const NotFoundError('Для этой серии не нашлось ни одного плеера.');
    }

    final ordered = <PlayerOption>[
      ...options.where((option) => option.key == task.playerKey),
      // та же озвучка у другого плеера — следующий по приоритету вариант
      ...options.where((option) =>
          option.key != task.playerKey &&
          option.label.toLowerCase() == task.translation.toLowerCase()),
      ...options.where((option) =>
          option.key != task.playerKey &&
          option.label.toLowerCase() != task.translation.toLowerCase()),
    ];

    AnimeError? lastError;
    for (final option in ordered) {
      try {
        final result = await catalog.resolve(option);
        final stream = _bestDownloadable(result);
        if (stream != null) return _PickedStream(option, stream);
      } on AnimeError catch (error) {
        lastError = error;
      }
    }
    throw lastError ??
        const NoStreamsFoundError(
          'Ни один плеер этой серии не отдал дорожку, которую можно сохранить файлом.',
        );
  }

  VideoStream? _bestDownloadable(PlayerResult result) {
    final wanted = settings.downloadQuality;
    final candidates = result.streams.where((stream) => stream.isDownloadable).toList();
    if (candidates.isEmpty) return null;

    // ближайшее качество снизу к желаемому, иначе — минимальное из доступных
    candidates.sort((a, b) => (a.quality ?? 0).compareTo(b.quality ?? 0));
    VideoStream? best;
    for (final stream in candidates) {
      if ((stream.quality ?? 0) <= wanted) best = stream;
    }
    return best ?? candidates.first;
  }

  Future<String> _episodeDirectory(AnimeCard card) async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(root.path, 'downloads', _safe(card.id)));
    await directory.create(recursive: true);
    return directory.path;
  }

  static String _fileName(int episode, String translation, String extension) {
    final suffix = translation.isEmpty ? '' : '_${_safe(translation)}';
    return 'ep${episode.toString().padLeft(3, '0')}$suffix.$extension';
  }

  static String _safe(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-zА-Яа-я0-9_\- ]'), '_').trim();
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  DownloadTask _withPath(DownloadTask task, String filePath) {
    return DownloadTask(
      id: task.id,
      source: task.source,
      animeId: task.animeId,
      animeTitle: task.animeTitle,
      posterUrl: task.posterUrl,
      episode: task.episode,
      translation: task.translation,
      playerKey: task.playerKey,
      filePath: filePath,
      status: task.status,
      quality: task.quality,
      kind: task.kind,
      url: task.url,
      headers: task.headers,
      receivedBytes: task.receivedBytes,
      totalBytes: task.totalBytes,
      segmentsDone: task.segmentsDone,
      segmentsTotal: task.segmentsTotal,
      error: task.error,
      createdAt: task.createdAt,
      updatedAt: DateTime.now(),
    );
  }

  DownloadTask? _byId(int? id) {
    if (id == null) return null;
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  void _replaceInMemory(DownloadTask task) {
    _tasks = [
      for (final item in _tasks)
        if (item.id == task.id) task else item,
    ];
    notifyListeners();
  }

  Future<void> _save(DownloadTask task) async {
    if (task.id == null) {
      await _db.insert('downloads', task.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await _db.update('downloads', task.toRow(), where: 'id = ?', whereArgs: [task.id]);
    }
    await _reload();
  }

  Future<void> _reload() async {
    final rows = await _db.query('downloads', orderBy: 'created_at DESC');
    _tasks = rows.map(DownloadTask.fromRow).toList();
    notifyListeners();
  }
}

class _PickedStream {
  const _PickedStream(this.option, this.stream);

  final PlayerOption option;
  final VideoStream stream;
}
