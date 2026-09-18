/// Плеер Animedia — `aser.pro/vod/<id>` (сайт amd.online, бывший animedia.tv).
///
/// Страница плеера почти пустая, всё полезное — в одной строке:
///
///     var player = new Playerjs({file: "https://aser.pro/content/stream/.../index.m3u8"});
///
/// `file` — либо ссылка на master-плейлист, либо запись Playerjs с несколькими
/// качествами (`[720]url1,[360]url2`), либо json-плейлист. Поддержаны все три.
library;

import 'dart:convert';

import '../../core/errors.dart';
import '../../core/utils.dart';
import '../models.dart';
import 'base.dart';

final RegExp _playerjsFile = RegExp(r"""file\s*:\s*(['"])(.*?)\1""", dotAll: true);
final RegExp _vodId = RegExp(r'/vod/(\d+)');
final RegExp _streamPath = RegExp(
  r'/content/stream/([^/]+)/(\d+)_(\d+)/',
  caseSensitive: false,
);

/// Запись Playerjs с несколькими качествами: `[720]https://...,[360]https://...`
final RegExp _labelled = RegExp(r'\[([^\]]+)\]([^,]+)');

class AnimediaPlayer extends BasePlayer {
  AnimediaPlayer(super.client);

  static const String baseUrl = 'https://aser.pro';
  static const String siteUrl = 'https://amd.online';

  @override
  String get name => 'animedia';

  @override
  String get title => 'Animedia (aser.pro)';

  @override
  List<RegExp> get urlPatterns => [
        RegExp(r'aser\.pro/vod/\d+'),
        RegExp(r'animedia\.[a-z]+/embed/'),
      ];

  @override
  Map<String, String> get playbackHeaders => const {'Referer': '$baseUrl/'};

  static String embedUrl(Object vodId) => '$baseUrl/vod/$vodId';

  static String? vodId(String url) => searchOrNull(_vodId, url);

  @override
  Future<PlayerResult> extract(
    String url, [
    ExtractOptions options = const ExtractOptions(),
  ]) async {
    final target = _normalize(url);
    final page = await client.get(
      target,
      headers: {'Referer': options.referer ?? '$siteUrl/'},
    );
    final result = _buildResult(page.raiseForStatus().text, target);
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
    if (RegExp(r'^\d+$').hasMatch(value)) return embedUrl(value);
    if (value.startsWith('//')) value = 'https:$value';
    return ensureMatches(value);
  }

  PlayerResult _buildResult(String text, String url) {
    final raw = _playerjsFile.firstMatch(text)?.group(2);
    if (raw == null || raw.isEmpty) {
      throw NoStreamsFoundError(
        'На странице Animedia нет параметра file у плеера ($url). '
        'Рабочая ссылка выглядит как https://aser.pro/vod/<id>.',
      );
    }

    final headers = buildHeaders();
    final streams = _streamsFromPlayerjs(raw.replaceAll(r'\/', '/'), url, headers);
    if (streams.isEmpty) {
      throw NoStreamsFoundError('Playerjs на странице Animedia не отдал ни одной ссылки: $url');
    }

    final path = _streamPath.firstMatch(streams.first.url);
    return PlayerResult(
      player: name,
      sourceUrl: url,
      streams: streams,
      extra: {
        'vod_id': vodId(url),
        'slug': path?.group(1),
        'episode': path == null ? null : int.tryParse(path.group(2)!),
      },
    );
  }

  /// Разбирает значение `file` во всех форматах, которые понимает Playerjs.
  List<VideoStream> _streamsFromPlayerjs(
    String value,
    String baseUrl,
    Map<String, String> headers,
  ) {
    final trimmed = value.trim();

    // 1. json-плейлист: [{"title": "1 серия", "file": "..."}, ...]
    if (trimmed.startsWith('[')) {
      Object? items;
      try {
        items = jsonDecode(trimmed);
      } catch (_) {
        items = null;
      }
      if (items is List) {
        final streams = <VideoStream>[];
        for (final item in items) {
          if (item is Map && item['file'] != null) {
            streams.addAll(_streamsFromPlayerjs('${item['file']}', baseUrl, headers));
          }
        }
        if (streams.isNotEmpty) return streams;
      }
    }

    // 2. несколько качеств: [720]url1,[360]url2
    final labelled = _labelled.allMatches(trimmed).toList();
    if (labelled.isNotEmpty) {
      final streams = <VideoStream>[
        for (final match in labelled)
          () {
            final link = absoluteUrl(baseUrl, match.group(2)!.trim());
            return VideoStream(
              url: link,
              kind: _kind(link),
              quality: qualityFromLabel(match.group(1)),
              headers: headers,
              label: match.group(1)!.trim(),
            );
          }(),
      ];
      streams.sort((a, b) => (a.quality ?? 0).compareTo(b.quality ?? 0));
      return streams;
    }

    // 3. просто ссылка
    final link = absoluteUrl(baseUrl, trimmed);
    if (!link.startsWith('http')) return const <VideoStream>[];
    return [
      VideoStream(
        url: link,
        kind: _kind(link),
        headers: headers,
        label: link.endsWith('.m3u8') ? 'master' : null,
      ),
    ];
  }

  static StreamKind _kind(String url) {
    if (url.contains('.m3u8')) return StreamKind.hls;
    if (url.contains('.mpd')) return StreamKind.dash;
    return StreamKind.mp4;
  }
}
