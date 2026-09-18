/// Модели локального кабинета: список, прогресс по сериям, загрузки.
///
/// Всё живёт в телефоне — ни аккаунта, ни сервера.
library;

import 'dart:convert';

import '../anime/catalog.dart';

/// Статус тайтла в личном списке.
enum WatchStatus {
  watching('watching', 'Смотрю'),
  planned('planned', 'В планах'),
  completed('completed', 'Просмотрено'),
  onHold('on_hold', 'Отложено'),
  dropped('dropped', 'Брошено');

  const WatchStatus(this.value, this.title);

  final String value;
  final String title;

  static WatchStatus fromValue(String? value) {
    return WatchStatus.values.firstWhere(
      (status) => status.value == value,
      orElse: () => WatchStatus.watching,
    );
  }
}

/// Тайтл в личном списке.
class WatchlistEntry {
  const WatchlistEntry({
    required this.source,
    required this.animeId,
    required this.title,
    required this.status,
    this.posterUrl,
    this.rating,
    this.episodesTotal,
    this.lastEpisode = 0,
    this.note,
    required this.updatedAt,
  });

  final String source;
  final String animeId;
  final String title;
  final String? posterUrl;
  final WatchStatus status;

  /// Личная оценка 1..10.
  final int? rating;
  final int? episodesTotal;

  /// Номер последней досмотренной серии.
  final int lastEpisode;
  final String? note;
  final DateTime updatedAt;

  AnimeCard toCard() => AnimeCard(
        id: animeId,
        title: title,
        source: source,
        poster: posterUrl,
      );

  WatchlistEntry copyWith({
    String? title,
    String? posterUrl,
    WatchStatus? status,
    int? rating,
    bool clearRating = false,
    int? episodesTotal,
    int? lastEpisode,
    String? note,
  }) {
    return WatchlistEntry(
      source: source,
      animeId: animeId,
      title: title ?? this.title,
      posterUrl: posterUrl ?? this.posterUrl,
      status: status ?? this.status,
      rating: clearRating ? null : (rating ?? this.rating),
      episodesTotal: episodesTotal ?? this.episodesTotal,
      lastEpisode: lastEpisode ?? this.lastEpisode,
      note: note ?? this.note,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, Object?> toRow() => {
        'source': source,
        'anime_id': animeId,
        'title': title,
        'poster_url': posterUrl,
        'status': status.value,
        'rating': rating,
        'episodes_total': episodesTotal,
        'last_episode': lastEpisode,
        'note': note,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static WatchlistEntry fromRow(Map<String, Object?> row) => WatchlistEntry(
        source: row['source'] as String,
        animeId: row['anime_id'] as String,
        title: row['title'] as String,
        posterUrl: row['poster_url'] as String?,
        status: WatchStatus.fromValue(row['status'] as String?),
        rating: row['rating'] as int?,
        episodesTotal: row['episodes_total'] as int?,
        lastEpisode: (row['last_episode'] as int?) ?? 0,
        note: row['note'] as String?,
        updatedAt: DateTime.fromMillisecondsSinceEpoch((row['updated_at'] as int?) ?? 0),
      );
}

/// Прогресс по одной серии: сколько просмотрено и досмотрена ли она.
class EpisodeProgress {
  const EpisodeProgress({
    required this.source,
    required this.animeId,
    required this.episode,
    required this.position,
    this.duration,
    this.completed = false,
    this.translation,
    this.playerKey,
    required this.updatedAt,
  });

  final String source;
  final String animeId;
  final int episode;

  /// Позиция в секундах.
  final double position;
  final double? duration;
  final bool completed;
  final String? translation;
  final String? playerKey;
  final DateTime updatedAt;

  int get percent {
    if (duration == null || duration! <= 0) return completed ? 100 : 0;
    return (position / duration! * 100).round().clamp(0, 100);
  }

  Map<String, Object?> toRow() => {
        'source': source,
        'anime_id': animeId,
        'episode': episode,
        'position': position,
        'duration': duration,
        'completed': completed ? 1 : 0,
        'translation': translation,
        'player_key': playerKey,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static EpisodeProgress fromRow(Map<String, Object?> row) => EpisodeProgress(
        source: row['source'] as String,
        animeId: row['anime_id'] as String,
        episode: row['episode'] as int,
        position: (row['position'] as num?)?.toDouble() ?? 0,
        duration: (row['duration'] as num?)?.toDouble(),
        completed: (row['completed'] as int? ?? 0) == 1,
        translation: row['translation'] as String?,
        playerKey: row['player_key'] as String?,
        updatedAt: DateTime.fromMillisecondsSinceEpoch((row['updated_at'] as int?) ?? 0),
      );
}

/// Строка «продолжить просмотр» на главной.
class ContinueItem {
  const ContinueItem({required this.entry, required this.progress});

  final WatchlistEntry entry;
  final EpisodeProgress progress;
}

enum DownloadStatus {
  queued('queued', 'В очереди'),
  running('running', 'Скачивается'),
  paused('paused', 'Пауза'),
  done('done', 'Готово'),
  failed('failed', 'Ошибка');

  const DownloadStatus(this.value, this.title);

  final String value;
  final String title;

  static DownloadStatus fromValue(String? value) {
    return DownloadStatus.values.firstWhere(
      (status) => status.value == value,
      orElse: () => DownloadStatus.queued,
    );
  }
}

/// Задание на скачивание серии.
class DownloadTask {
  const DownloadTask({
    this.id,
    required this.source,
    required this.animeId,
    required this.animeTitle,
    required this.episode,
    required this.translation,
    required this.playerKey,
    required this.filePath,
    required this.status,
    this.posterUrl,
    this.quality,
    this.kind = 'mp4',
    this.url = '',
    this.headers = const {},
    this.receivedBytes = 0,
    this.totalBytes,
    this.segmentsDone = 0,
    this.segmentsTotal,
    this.error,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final String source;
  final String animeId;
  final String animeTitle;
  final String? posterUrl;
  final int episode;

  /// Название озвучки — чтобы отличать одну и ту же серию в разных дорожках.
  final String translation;
  final String playerKey;

  /// Куда сохраняем файл.
  final String filePath;
  final DownloadStatus status;
  final int? quality;

  /// `mp4` | `hls`
  final String kind;

  /// Прямая ссылка. Протухает, поэтому перед докачкой берётся заново.
  final String url;
  final Map<String, String> headers;
  final int receivedBytes;
  final int? totalBytes;

  /// Для HLS прогресс считается по сегментам, а не по байтам.
  final int segmentsDone;
  final int? segmentsTotal;
  final String? error;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isActive =>
      status == DownloadStatus.queued || status == DownloadStatus.running;

  double get progress {
    if (status == DownloadStatus.done) return 1;
    if (segmentsTotal != null && segmentsTotal! > 0) {
      return (segmentsDone / segmentsTotal!).clamp(0, 1);
    }
    if (totalBytes != null && totalBytes! > 0) {
      return (receivedBytes / totalBytes!).clamp(0, 1);
    }
    return 0;
  }

  String get label => '$animeTitle — серия $episode';

  AnimeCard toCard() => AnimeCard(
        id: animeId,
        title: animeTitle,
        source: source,
        poster: posterUrl,
      );

  DownloadTask copyWith({
    int? id,
    DownloadStatus? status,
    String? url,
    Map<String, String>? headers,
    int? receivedBytes,
    int? totalBytes,
    int? segmentsDone,
    int? segmentsTotal,
    String? error,
    bool clearError = false,
    int? quality,
    String? kind,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      source: source,
      animeId: animeId,
      animeTitle: animeTitle,
      posterUrl: posterUrl,
      episode: episode,
      translation: translation,
      playerKey: playerKey,
      filePath: filePath,
      status: status ?? this.status,
      quality: quality ?? this.quality,
      kind: kind ?? this.kind,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      segmentsDone: segmentsDone ?? this.segmentsDone,
      segmentsTotal: segmentsTotal ?? this.segmentsTotal,
      error: clearError ? null : (error ?? this.error),
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'source': source,
        'anime_id': animeId,
        'anime_title': animeTitle,
        'poster_url': posterUrl,
        'episode': episode,
        'translation': translation,
        'player_key': playerKey,
        'file_path': filePath,
        'status': status.value,
        'quality': quality,
        'kind': kind,
        'url': url,
        'headers': jsonEncode(headers),
        'received_bytes': receivedBytes,
        'total_bytes': totalBytes,
        'segments_done': segmentsDone,
        'segments_total': segmentsTotal,
        'error': error,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static DownloadTask fromRow(Map<String, Object?> row) {
    Map<String, String> headers = const {};
    final raw = row['headers'];
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) headers = Map<String, String>.from(decoded);
    }
    return DownloadTask(
      id: row['id'] as int?,
      source: row['source'] as String,
      animeId: row['anime_id'] as String,
      animeTitle: row['anime_title'] as String,
      posterUrl: row['poster_url'] as String?,
      episode: row['episode'] as int,
      translation: (row['translation'] as String?) ?? '',
      playerKey: (row['player_key'] as String?) ?? '',
      filePath: row['file_path'] as String,
      status: DownloadStatus.fromValue(row['status'] as String?),
      quality: row['quality'] as int?,
      kind: (row['kind'] as String?) ?? 'mp4',
      url: (row['url'] as String?) ?? '',
      headers: headers,
      receivedBytes: (row['received_bytes'] as int?) ?? 0,
      totalBytes: row['total_bytes'] as int?,
      segmentsDone: (row['segments_done'] as int?) ?? 0,
      segmentsTotal: row['segments_total'] as int?,
      error: row['error'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch((row['created_at'] as int?) ?? 0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch((row['updated_at'] as int?) ?? 0),
    );
  }
}
