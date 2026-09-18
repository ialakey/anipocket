/// Плеер VK Video (vk.com / vkvideo.ru / vk.ru).
///
/// Страница `video_ext.php` кладёт в `window.cur` объект `apiPrefetchCache` —
/// предзагруженные ответы внутреннего API. Нужен ответ метода `video.get`: в нём
/// `files` со ссылками (`mp4_144` … `mp4_2160`, `hls_ondemand`, `dash_ondemand`),
/// название, длительность и обложка.
///
/// Старый формат (`var playerParams = {...}` с ключами `url720`) тоже поддержан —
/// он ещё попадается на зеркалах и мобильных страницах.
library;

import 'dart:convert';

import '../../core/errors.dart';
import '../../core/utils.dart';
import '../models.dart';
import 'base.dart';

const String _prefetchKey = '"apiPrefetchCache"';
final RegExp _playerParams = RegExp(r'var\s+playerParams\s*=\s*(\{.*?\})\s*;', dotAll: true);
final RegExp _mp4Key = RegExp(r'^(?:mp4_|url)(\d{3,4})$');
const List<String> _hlsKeys = [
  'hls_ondemand',
  'hls',
  'hls_fmp4',
  'hls_live_playback',
  'live_playback_hls',
];
const List<String> _dashKeys = [
  'dash_ondemand',
  'dash_sep',
  'dash_webm',
  'dash',
  'dash_live_playback',
];

/// `video-123_456`, `video-123_456_ab12cd`, `-123_456`
final RegExp _videoId = RegExp(r'(?:video)?(-?\d+)_(\d+)(?:_([0-9a-f]+))?', caseSensitive: false);

class VkPlayer extends BasePlayer {
  VkPlayer(super.client);

  static const String embedBase = 'https://vk.com/video_ext.php';

  @override
  String get name => 'vk';

  @override
  String get title => 'VK Video';

  @override
  List<RegExp> get urlPatterns => [
        RegExp(r'video_ext\.php'),
        RegExp(r'/video-?\d+_\d+'),
        RegExp(r'^-?\d+_\d+(?:_[0-9a-f]+)?$'),
      ];

  @override
  Map<String, String> get playbackHeaders => const {
        'Referer': 'https://vk.com/',
        'Origin': 'https://vk.com',
      };

  static String embedUrl(Object ownerId, Object videoId, {String? accessKey, int hd = 2}) {
    final url = '$embedBase?oid=$ownerId&id=$videoId&hd=$hd';
    return accessKey == null ? url : '$url&hash=$accessKey';
  }

  /// `(owner_id, video_id, access_key)` из ссылки любого вида.
  static (String, String, String?) videoIds(String url) {
    final value = url.trim();
    if (value.contains('video_ext.php')) {
      final owner = queryParam(value, 'oid');
      final video = queryParam(value, 'id');
      if (owner != null && video != null) {
        return (owner, video, queryParam(value, 'hash'));
      }
    }
    final match = _videoId.firstMatch(value);
    if (match == null) {
      throw ExtractionError(
        'Не разобрать ссылку VK: $url. Ожидается video_ext.php?oid=&id=, '
        'ссылка /video-123_456 или строка «-123_456».',
      );
    }
    return (match.group(1)!, match.group(2)!, match.group(3));
  }

  @override
  Future<PlayerResult> extract(
    String url, [
    ExtractOptions options = const ExtractOptions(),
  ]) async {
    final embed = _normalize(url);
    final page = await client.get(
      embed,
      headers: {'Referer': options.referer ?? 'https://vk.com/'},
    );
    final result = _buildResult(page.raiseForStatus().text, embed);
    if (options.resolveQualities) {
      final master = result.master();
      if (master != null) {
        result.streams.addAll(await expandMaster(master));
      }
    }
    return result;
  }

  String _normalize(String url) {
    var value = url.trim();
    if (value.startsWith('//')) value = 'https:$value';
    if (value.contains('video_ext.php')) return value;
    final (owner, video, accessKey) = videoIds(value);
    return embedUrl(owner, video, accessKey: accessKey);
  }

  /// Ищет ответ `video.get` внутри `apiPrefetchCache`.
  static Map<String, dynamic>? _parsePrefetch(String text) {
    final index = text.indexOf(_prefetchKey);
    if (index < 0) return null;
    final start = text.indexOf('[', index);
    if (start < 0) return null;
    final raw = _sliceJson(text, start);
    if (raw == null) return null;
    Object? entries;
    try {
      entries = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (entries is! List) return null;
    for (final entry in entries) {
      if (entry is! Map) continue;
      if (entry['method'] != 'video.get') continue;
      final response = entry['response'];
      final items = response is Map ? response['items'] : null;
      if (items is List && items.isNotEmpty && items.first is Map) {
        return Map<String, dynamic>.from(items.first as Map);
      }
    }
    return null;
  }

  /// Аналог `json.JSONDecoder().raw_decode`: вырезает первый полный json-массив.
  static String? _sliceJson(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final char = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
      } else if (char == '[' || char == '{') {
        depth++;
      } else if (char == ']' || char == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  /// Старый формат страницы: `var playerParams = {...}`.
  static Map<String, dynamic>? _parsePlayerParams(String text) {
    final raw = _playerParams.firstMatch(text)?.group(1);
    if (raw == null) return null;
    Object? params;
    try {
      params = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (params is! Map) return null;
    final nested = params['params'];
    final source = (nested is List && nested.isNotEmpty ? nested.first : params);
    if (source is! Map) return null;

    // приводим к форме нового формата
    final files = <String, dynamic>{};
    source.forEach((key, value) {
      if (value is String) files['$key'] = value;
    });
    final image = source['jpg'] ?? source['thumb'];
    return {
      'files': files,
      'title': source['md_title'] ?? source['title'],
      'duration': source['duration'],
      'image': image == null ? [] : [
        {'url': image, 'width': 0},
      ],
      'owner_id': source['oid'],
      'id': source['vid'],
    };
  }

  PlayerResult _buildResult(String text, String url) {
    final item = _parsePrefetch(text) ?? _parsePlayerParams(text);
    if (item == null) {
      throw ContentBlockedError(
        'VK не отдал данные видео ($url). Обычно это значит, что ролик приватный, '
        'удалён, доступен только по ссылке (нужен параметр hash) или заблокирован '
        'в вашем регионе.',
      );
    }

    final files = item['files'];
    final headers = buildHeaders();
    final streams = <VideoStream>[];

    if (files is Map) {
      files.forEach((key, value) {
        if (value is! String || !value.startsWith('http')) return;
        final quality = _mp4Key.firstMatch('$key');
        if (quality != null) {
          final height = int.parse(quality.group(1)!);
          streams.add(
            VideoStream(
              url: value,
              kind: StreamKind.mp4,
              quality: height,
              headers: headers,
              label: '${height}p',
              extra: {'key': key},
            ),
          );
        } else if (_hlsKeys.contains(key)) {
          streams.add(
            VideoStream(
              url: value,
              kind: StreamKind.hls,
              headers: headers,
              label: 'master',
              extra: {'key': key},
            ),
          );
        } else if (_dashKeys.contains(key)) {
          streams.add(
            VideoStream(
              url: value,
              kind: StreamKind.dash,
              headers: headers,
              label: '$key',
              extra: {'key': key},
            ),
          );
        }
      });
    }
    streams.sort((a, b) => (a.quality ?? 0).compareTo(b.quality ?? 0));

    if (streams.isEmpty) {
      throw NoStreamsFoundError('VK описал видео, но ссылок на файлы не дал: $url');
    }

    String? poster;
    final images = item['image'];
    if (images is List) {
      final valid = images.whereType<Map>().where((image) => image['url'] != null).toList();
      if (valid.isNotEmpty) {
        valid.sort((a, b) => (toInt(a['width']) ?? 0).compareTo(toInt(b['width']) ?? 0));
        poster = valid.last['url'] as String?;
      }
    }

    return PlayerResult(
      player: name,
      sourceUrl: url,
      streams: streams,
      title: item['title'] as String?,
      poster: poster,
      duration: toInt(item['duration']),
      extra: {
        'owner_id': item['owner_id'],
        'video_id': item['id'],
        'is_live': item['live'] != null && item['live'] != false,
      },
    );
  }
}
