/// Плеер Sibnet (video.sibnet.ru).
///
/// Страница `shell.php?videoid=<id>` несёт относительную ссылку на mp4 внутри js
/// плеера (`player.src([{src: "/v/<hash>/<id>.mp4"}])`). Файл отдаётся только с
/// заголовком `Referer: https://video.sibnet.ru/`, а сама ссылка редиректит на
/// подписанный адрес CDN.
library;

import '../../core/errors.dart';
import '../../core/utils.dart';
import '../models.dart';
import 'base.dart';

final RegExp _srcRe = RegExp(
  r"""player\.src\(\s*\[\s*\{\s*src\s*:\s*["']([^"']+)["']""",
  caseSensitive: false,
);
final RegExp _fallbackSrcRe = RegExp(
  r"""["'](/v/[^"']+\.(?:mp4|m3u8))["']""",
  caseSensitive: false,
);
final RegExp _titleRe = RegExp(
  r"""<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)""",
  caseSensitive: false,
);
final RegExp _posterRe = RegExp(
  r"""<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)""",
  caseSensitive: false,
);
final RegExp _idRe = RegExp(r'(?:videoid=|/video)(\d+)', caseSensitive: false);

class SibnetPlayer extends BasePlayer {
  SibnetPlayer(super.client);

  static const String baseUrl = 'https://video.sibnet.ru';

  @override
  String get name => 'sibnet';

  @override
  String get title => 'Sibnet';

  @override
  List<RegExp> get urlPatterns => [RegExp(r'sibnet\.ru/(?:shell\.php|video)')];

  @override
  Map<String, String> get playbackHeaders => const {'Referer': '$baseUrl/'};

  static String embedUrl(Object videoId) => '$baseUrl/shell.php?videoid=$videoId';

  static String? videoId(String url) => searchOrNull(_idRe, url);

  @override
  Future<PlayerResult> extract(
    String url, [
    ExtractOptions options = const ExtractOptions(),
  ]) async {
    final target = _normalize(url);
    final page = await client.get(target, headers: {'Referer': '$baseUrl/'});
    final result = _buildResult(page.raiseForStatus().text, target);
    if (options.resolveRedirect) {
      for (var index = 0; index < result.streams.length; index++) {
        final stream = result.streams[index];
        final direct = await client.resolveRedirect(stream.url, headers: stream.headers);
        result.streams[index] = stream.copyWith(
          url: direct,
          extra: {...stream.extra, 'original_url': stream.url},
        );
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
    final src = searchOrNull(_srcRe, text) ?? searchOrNull(_fallbackSrcRe, text);
    if (src == null) {
      throw NoStreamsFoundError(
        'На странице Sibnet нет ссылки на видео ($url) — ролик удалён или заблокирован.',
      );
    }

    final headers = buildHeaders();
    final direct = absoluteUrl('$baseUrl/', src);
    final kind = direct.endsWith('.m3u8') ? StreamKind.hls : StreamKind.mp4;

    return PlayerResult(
      player: name,
      sourceUrl: url,
      streams: [
        VideoStream(url: direct, kind: kind, headers: headers, label: 'original'),
      ],
      title: searchOrNull(_titleRe, text),
      poster: searchOrNull(_posterRe, text),
      extra: {'video_id': videoId(url)},
    );
  }
}
