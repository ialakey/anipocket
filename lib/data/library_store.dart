/// Личный кабинет: список тайтлов, оценки и прогресс по сериям.
///
/// Порт серверного `services/tracking.py` — только вместо БД на сервере всё
/// лежит в sqlite на телефоне, а вместо пользователя есть просто «я».
library;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../anime/catalog.dart';
import 'database.dart';
import 'models.dart';

class LibraryStore extends ChangeNotifier {
  LibraryStore(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  List<WatchlistEntry> _entries = const [];
  List<ContinueItem> _continue = const [];

  List<WatchlistEntry> get entries => _entries;

  /// Строка «продолжить просмотр» на главной.
  List<ContinueItem> get continueWatching => _continue;

  Future<void> load() async {
    await _reload();
  }

  List<WatchlistEntry> byStatus(WatchStatus? status) {
    if (status == null) return _entries;
    return _entries.where((entry) => entry.status == status).toList();
  }

  Map<WatchStatus, int> get counts {
    final result = {for (final status in WatchStatus.values) status: 0};
    for (final entry in _entries) {
      result[entry.status] = (result[entry.status] ?? 0) + 1;
    }
    return result;
  }

  WatchlistEntry? find(String source, String animeId) {
    for (final entry in _entries) {
      if (entry.source == source && entry.animeId == animeId) return entry;
    }
    return null;
  }

  /// Заводит запись в списке, если её ещё нет, и обновляет название с постером.
  Future<WatchlistEntry> ensureEntry(
    AnimeCard card, {
    WatchStatus? status,
    int? episodesTotal,
  }) async {
    final existing = find(card.source, card.id);
    final entry = existing == null
        ? WatchlistEntry(
            source: card.source,
            animeId: card.id,
            title: card.title,
            posterUrl: card.poster,
            status: status ?? WatchStatus.watching,
            episodesTotal: episodesTotal,
            updatedAt: DateTime.now(),
          )
        : existing.copyWith(
            title: card.title.isNotEmpty ? card.title : existing.title,
            posterUrl: card.poster ?? existing.posterUrl,
            status: status,
            episodesTotal: episodesTotal,
          );
    await _db.insert(
      'watchlist',
      entry.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _reload();
    return entry;
  }

  Future<void> setStatus(AnimeCard card, WatchStatus status) async {
    await ensureEntry(card, status: status);
  }

  Future<void> setRating(String source, String animeId, int? rating) async {
    final entry = find(source, animeId);
    if (entry == null) return;
    await _db.update(
      'watchlist',
      entry.copyWith(rating: rating, clearRating: rating == null).toRow(),
      where: 'source = ? AND anime_id = ?',
      whereArgs: [source, animeId],
    );
    await _reload();
  }

  Future<void> setNote(String source, String animeId, String? note) async {
    final entry = find(source, animeId);
    if (entry == null) return;
    await _db.update(
      'watchlist',
      entry.copyWith(note: note).toRow(),
      where: 'source = ? AND anime_id = ?',
      whereArgs: [source, animeId],
    );
    await _reload();
  }

  /// Убирает тайтл из списка вместе с прогрессом по сериям.
  Future<void> remove(String source, String animeId) async {
    await _db.delete(
      'watchlist',
      where: 'source = ? AND anime_id = ?',
      whereArgs: [source, animeId],
    );
    await _db.delete(
      'progress',
      where: 'source = ? AND anime_id = ?',
      whereArgs: [source, animeId],
    );
    await _reload();
  }

  /// Прогресс по всем сериям тайтла: `{номер серии: прогресс}`.
  Future<Map<int, EpisodeProgress>> progressFor(String source, String animeId) async {
    final rows = await _db.query(
      'progress',
      where: 'source = ? AND anime_id = ?',
      whereArgs: [source, animeId],
    );
    return {
      for (final row in rows)
        row['episode'] as int: EpisodeProgress.fromRow(row),
    };
  }

  Future<EpisodeProgress?> progressOf(String source, String animeId, int episode) async {
    final rows = await _db.query(
      'progress',
      where: 'source = ? AND anime_id = ? AND episode = ?',
      whereArgs: [source, animeId, episode],
      limit: 1,
    );
    return rows.isEmpty ? null : EpisodeProgress.fromRow(rows.first);
  }

  /// Сохраняет позицию в серии и двигает счётчики списка.
  ///
  /// Серия считается досмотренной после [completedRatio] длительности — ровно
  /// так же, как это делает сайт.
  Future<void> saveProgress({
    required AnimeCard card,
    required int episode,
    required double position,
    double? duration,
    String? translation,
    String? playerKey,
    int? episodesTotal,
    double completedRatio = 0.85,
  }) async {
    final wasCompleted = (await progressOf(card.source, card.id, episode))?.completed ?? false;
    final completed = wasCompleted ||
        (duration != null && duration > 0 && position / duration >= completedRatio);

    final progress = EpisodeProgress(
      source: card.source,
      animeId: card.id,
      episode: episode,
      position: position,
      duration: duration,
      completed: completed,
      translation: translation,
      playerKey: playerKey,
      updatedAt: DateTime.now(),
    );
    await _db.insert(
      'progress',
      progress.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    var entry = find(card.source, card.id);
    entry ??= await ensureEntry(card, episodesTotal: episodesTotal);

    var status = entry.status;
    // вернулись к отложенному или запланированному — значит снова смотрим
    if (status == WatchStatus.planned || status == WatchStatus.onHold) {
      status = WatchStatus.watching;
    }
    final lastEpisode = completed && episode > entry.lastEpisode ? episode : entry.lastEpisode;
    final total = episodesTotal ?? entry.episodesTotal;
    if (status == WatchStatus.watching && total != null && total > 0 && lastEpisode >= total) {
      status = WatchStatus.completed;
    }

    final updated = entry.copyWith(
      status: status,
      lastEpisode: lastEpisode,
      episodesTotal: total,
    );
    await _db.insert(
      'watchlist',
      updated.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _reload();
  }

  /// Сколько часов просмотрено — по завершённым сериям.
  Future<double> watchedHours() async {
    final rows = await _db.rawQuery(
      'SELECT SUM(COALESCE(duration, position)) AS total FROM progress WHERE completed = 1',
    );
    final total = (rows.first['total'] as num?)?.toDouble() ?? 0;
    return total / 3600;
  }

  Future<void> _reload() async {
    final entryRows = await _db.query('watchlist', orderBy: 'updated_at DESC');
    _entries = entryRows.map(WatchlistEntry.fromRow).toList();

    // «Продолжить просмотр»: последние недосмотренные серии активных тайтлов
    final progressRows = await _db.rawQuery('''
      SELECT p.* FROM progress p
      JOIN watchlist w ON w.source = p.source AND w.anime_id = p.anime_id
      WHERE p.completed = 0 AND w.status IN ('watching', 'planned', 'on_hold')
      ORDER BY p.updated_at DESC
      LIMIT 12
    ''');
    final items = <ContinueItem>[];
    for (final row in progressRows) {
      final progress = EpisodeProgress.fromRow(row);
      final entry = find(progress.source, progress.animeId);
      if (entry != null) items.add(ContinueItem(entry: entry, progress: progress));
    }
    _continue = items;
    notifyListeners();
  }
}
