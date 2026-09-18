/// Плеер Aniboom (aniboom.one) — им AnimeGO отдаёт видео по умолчанию.
///
/// Страница embed несёт тег `<video id="video" data-parameters="...">`, в
/// атрибуте которого лежит экранированный json со ссылками на MPD и M3U8,
/// постером, длительностью и максимальным качеством.
library;

import 'dart:convert';

import '../../core/errors.dart';
import '../../core/utils.dart';
import '../models.dart';
import 'base.dart';

final RegExp _videoTag = RegExp(
  r'<video[^>]*\bdata-parameters="([^"]+)"',
  caseSensitive: false,
);
final RegExp _idFromUrl = RegExp(r'/embed/([A-Za-z0-9_-]+)');

class AniboomPlayer extends BasePlayer {
  AniboomPlayer(super.client);

  @override
  String get name => 'aniboom';

  @override
  String get title => 'Aniboom';

  @override
  List<RegExp> get urlPatterns => [RegExp(r'aniboom\.[a-z]+/embed/')];

  @override
  Map<String, String> get playbackHeaders => const {
        'Referer': 'https://aniboom.one/',
        'Origin': 'https://aniboom.one',
      };

  static const String embedBase = 'https://aniboom.one/embed/';

  /// Без этого Referer aniboom отдаёт заглушку.
  static const String defaultReferer = 'https://animego.org/';

  static String embedUrl(String videoId, {int? episode, int? translation}) {
    final params = <String>[
      if (episode != null) 'episode=$episode',
      if (translation != null) 'translation=$translation',
    ];
    return '$embedBase$videoId${params.isEmpty ? '' : '?${params.join('&')}'}';
  }

  static String? videoId(String url) => searchOrNull(_idFromUrl, url);

  @override
  Future<PlayerResult> extract(
    String url, [
    ExtractOptions options = const ExtractOptions(),
  ]) async {
    final target = _normalize(url);
    final response = await client.get(
      target,
      headers: {'Referer': options.referer ?? defaultReferer},
    );
    final data = _parsePage(response.text, response.status, target);
    final result = _buildResult(target, data);
    if (options.resolveQualities) {
      final master = result.master();
      if (master != null) {
        result.streams.addAll(await expandMaster(master));
      }
    }
    return result;
  }

  String _normalize(String url) {
    if (!url.contains('/')) return embedUrl(url);
    return ensureMatches(url);
  }

  Map<String, dynamic> _parsePage(String text, int status, String url) {
    if (status >= 400) {
      throw ServiceError('Aniboom ответил $status', status: status, url: url);
    }
    final raw = searchOrNull(_videoTag, text);
    if (raw == null) {
      // «не доступно» — формулировка самого Aniboom на заблокированной странице
      if (text.contains('не доступно') || text.contains('video-error')) {
        throw ContentBlockedError(
          'Aniboom не отдаёт это видео: гео-блокировка или ролик удалён.',
        );
      }
      throw ExtractionError(
        'На странице Aniboom нет тега <video data-parameters=...>: вёрстка плеера изменилась.',
      );
    }
    return jsonFromAttribute(raw);
  }

  /// Значения hls/dash приходят строкой с json внутри: `{"src": "...", ...}`.
  static String? _src(Object? value) {
    if (value == null) return null;
    if (value is String) {
      if (value.isEmpty) return null;
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return decoded['src'] as String?;
      } catch (_) {
        return value.startsWith('http') ? value : null;
      }
      return null;
    }
    if (value is Map) return value['src'] as String?;
    return null;
  }

  PlayerResult _buildResult(String url, Map<String, dynamic> data) {
    final headers = buildHeaders();
    final streams = <VideoStream>[];
    const sources = <String, StreamKind>{
      'hls': StreamKind.hls,
      'dash': StreamKind.dash,
      'fallbackHls': StreamKind.hls,
      'fallbackDash': StreamKind.dash,
    };
    sources.forEach((key, kind) {
      final src = _src(data[key]);
      if (src != null && src.isNotEmpty) {
        streams.add(
          VideoStream(
            url: src,
            kind: kind,
            headers: headers,
            label: key.startsWith('fallback') ? 'fallback' : 'master',
            extra: {'source': key},
          ),
        );
      }
    });

    if (streams.isEmpty) {
      throw NoStreamsFoundError('Aniboom не вернул ни hls, ни dash для $url');
    }

    return PlayerResult(
      player: name,
      sourceUrl: url,
      streams: streams,
      poster: data['poster'] as String?,
      duration: toInt(data['duration']),
      extra: {
        'video_id': data['id'],
        'max_quality': toInt(data['qualityVideo']),
        'thumbnails': data['thumbnails'],
        'rating': data['rating'],
      },
    );
  }
}
