/// Модели, которые возвращает любой плеер порта.
///
/// `Stream` в Dart занят `dart:async`, поэтому дорожка называется [VideoStream].
library;

import '../core/errors.dart';

enum StreamKind {
  /// m3u8 — master-плейлист либо плейлист одного качества.
  hls('hls'),

  /// mpd — манифест MPEG-DASH.
  dash('dash'),

  /// Прямая ссылка на файл (mp4/webm).
  mp4('mp4');

  const StreamKind(this.value);

  final String value;

  static StreamKind fromValue(String value) {
    return StreamKind.values.firstWhere(
      (kind) => kind.value == value,
      orElse: () => StreamKind.mp4,
    );
  }

  /// Чем проще скачать, тем выше приоритет при равном качестве.
  int get downloadRank => switch (this) {
        StreamKind.mp4 => 2,
        StreamKind.hls => 1,
        StreamKind.dash => 0,
      };
}

/// Отрезок, который плеер предлагает пропустить (опенинг/эндинг), в секундах.
class SkipSegment {
  const SkipSegment(this.start, this.end, [this.kind]);

  final int start;
  final int end;

  /// `opening` | `ending` | null
  final String? kind;

  int get duration => end - start > 0 ? end - start : 0;

  String get title => switch (kind) {
        'opening' => 'Пропустить опенинг',
        'ending' => 'Пропустить эндинг',
        _ => 'Пропустить',
      };

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'kind': kind};

  static SkipSegment fromJson(Map<String, dynamic> json) => SkipSegment(
        json['start'] as int,
        json['end'] as int,
        json['kind'] as String?,
      );
}

/// Одна ссылка на видео.
class VideoStream {
  const VideoStream({
    required this.url,
    required this.kind,
    this.quality,
    this.headers = const {},
    this.label,
    this.extra = const {},
  });

  final String url;
  final StreamKind kind;

  /// Высота картинки в пикселях; `null` у master-плейлиста.
  final int? quality;

  /// Заголовки, без которых CDN отвечает 403. Едут и в плеер, и в загрузчик.
  final Map<String, String> headers;
  final String? label;
  final Map<String, dynamic> extra;

  /// Master-плейлист HLS: качество плеер подбирает сам.
  bool get isMaster => kind == StreamKind.hls && quality == null;

  /// Отдельная звуковая дорожка video-only варианта HLS.
  String? get audioUrl {
    final value = extra['audio_url'];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Можно ли сохранить дорожку в один файл без перекодирования.
  ///
  /// mp4 — просто файл; HLS склеивается из сегментов. А вот вариант, у которого
  /// звук лежит отдельной дорожкой, без ремукса в один файл не собрать.
  bool get isDownloadable => kind != StreamKind.dash && audioUrl == null;

  String get qualityLabel => quality != null ? '${quality}p' : (label ?? 'авто');

  VideoStream copyWith({String? url, Map<String, dynamic>? extra}) => VideoStream(
        url: url ?? this.url,
        kind: kind,
        quality: quality,
        headers: headers,
        label: label,
        extra: extra ?? this.extra,
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'kind': kind.value,
        'quality': quality,
        'headers': headers,
        'label': label,
        'extra': extra,
      };

  static VideoStream fromJson(Map<String, dynamic> json) => VideoStream(
        url: json['url'] as String,
        kind: StreamKind.fromValue(json['kind'] as String),
        quality: json['quality'] as int?,
        headers: Map<String, String>.from(json['headers'] as Map? ?? const {}),
        label: json['label'] as String?,
        extra: Map<String, dynamic>.from(json['extra'] as Map? ?? const {}),
      );

  @override
  String toString() => '[${kind.value} $qualityLabel] $url';
}

/// Результат разбора плеера.
class PlayerResult {
  PlayerResult({
    required this.player,
    required this.sourceUrl,
    List<VideoStream>? streams,
    this.title,
    this.poster,
    this.duration,
    this.translation,
    List<SkipSegment>? skipSegments,
    Map<String, dynamic>? extra,
  })  : streams = streams ?? <VideoStream>[],
        skipSegments = skipSegments ?? const <SkipSegment>[],
        extra = extra ?? const <String, dynamic>{};

  final String player;
  final String sourceUrl;
  final List<VideoStream> streams;
  final String? title;
  final String? poster;

  /// Длительность в секундах.
  final int? duration;
  final String? translation;
  final List<SkipSegment> skipSegments;
  final Map<String, dynamic> extra;

  bool get isEmpty => streams.isEmpty;

  /// Отсортированный список доступных качеств.
  List<int> get qualities {
    final values = streams.map((s) => s.quality).whereType<int>().toSet().toList()..sort();
    return values;
  }

  List<VideoStream> filter({
    StreamKind? kind,
    int? quality,
    int? maxQuality,
  }) {
    return streams.where((stream) {
      if (kind != null && stream.kind != kind) return false;
      if (quality != null && stream.quality != quality) return false;
      if (maxQuality != null && stream.quality != null && stream.quality! > maxQuality) {
        return false;
      }
      return true;
    }).toList();
  }

  /// Лучшая дорожка: выше качество, при равенстве mp4 > hls > dash.
  ///
  /// Дорожки неизвестного качества (master-плейлисты) идут последними.
  VideoStream best({StreamKind? kind, int? maxQuality, bool allowMaster = true}) {
    var candidates = filter(kind: kind, maxQuality: maxQuality);
    if (!allowMaster) {
      candidates = candidates.where((stream) => !stream.isMaster).toList();
    }
    if (candidates.isEmpty) {
      throw NoStreamsFoundError(
        'Подходящих дорожек нет (плеер: $player).',
      );
    }
    candidates.sort((a, b) {
      final known = (a.quality != null ? 1 : 0).compareTo(b.quality != null ? 1 : 0);
      if (known != 0) return known;
      final byQuality = (a.quality ?? 0).compareTo(b.quality ?? 0);
      if (byQuality != 0) return byQuality;
      return a.kind.downloadRank.compareTo(b.kind.downloadRank);
    });
    return candidates.last;
  }

  /// Master-плейлист HLS, если он есть.
  VideoStream? master() {
    for (final stream in streams) {
      if (stream.isMaster) return stream;
    }
    return null;
  }
}
