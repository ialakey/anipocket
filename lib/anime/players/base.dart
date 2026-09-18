/// Общий контракт плеера: сопоставление ссылки и разбор.
library;

import '../../core/errors.dart';
import '../../core/http.dart';
import '../../core/utils.dart';
import '../models.dart';

/// Всё, что плееру можно уточнить сверх самой ссылки.
class ExtractOptions {
  const ExtractOptions({
    this.season,
    this.episode,
    this.studio,
    this.referer,
    this.resolveQualities = true,
    this.includeMp4 = true,
    this.resolveRedirect = false,
    this.maxQuality,
  });

  /// Сезон — для ссылок Kodik `/serial/...` и плейлистов CVH.
  final int? season;

  /// Номер серии для тех же ссылок.
  final int? episode;

  /// Название озвучки (CVH подбирает нестрого).
  final String? studio;

  /// Сайт, с которого «открыт» плеер.
  final String? referer;

  /// Развернуть master-плейлист в отдельные качества (+1 запрос).
  final bool resolveQualities;

  /// Добавлять прямые mp4 к ссылкам Kodik.
  final bool includeMp4;

  /// Sibnet: сразу пойти по редиректу на подписанный адрес CDN.
  final bool resolveRedirect;

  /// Потолок качества — выше него дорожки не нужны.
  final int? maxQuality;

  ExtractOptions copyWith({int? episode, int? season, String? studio}) {
    return ExtractOptions(
      season: season ?? this.season,
      episode: episode ?? this.episode,
      studio: studio ?? this.studio,
      referer: referer,
      resolveQualities: resolveQualities,
      includeMp4: includeMp4,
      resolveRedirect: resolveRedirect,
      maxQuality: maxQuality,
    );
  }
}

abstract class BasePlayer {
  BasePlayer(this.client);

  final AnimeHttpClient client;

  /// Имя плеера в порте (`aniboom`, `kodik`, ...).
  String get name;

  /// Как плеер называется у людей.
  String get title;

  /// По этим шаблонам ссылка отдаётся именно этому плееру.
  List<RegExp> get urlPatterns;

  /// Заголовки, без которых CDN не отдаст видео.
  Map<String, String> get playbackHeaders => const {};

  bool matches(String url) => urlPatterns.any((pattern) => pattern.hasMatch(url));

  String ensureMatches(String url) {
    if (!matches(url)) {
      throw UnsupportedUrlError('Ссылка $url не похожа на плеер $title');
    }
    return url;
  }

  /// Заголовки воспроизведения плюс общий User-Agent.
  Map<String, String> buildHeaders() => {
        ...playbackHeaders,
        'User-Agent': client.userAgent,
      };

  Future<PlayerResult> extract(String url, [ExtractOptions options = const ExtractOptions()]);

  /// Разворачивает master-плейлист в отдельные качества.
  Future<List<VideoStream>> expandMaster(VideoStream master) async {
    final content = await client.get(master.url, headers: master.headers);
    if (!content.ok || !content.text.contains('#EXT-X-STREAM-INF')) {
      return const <VideoStream>[];
    }
    return parseVariants(content.text, master);
  }
}

/// Общий для нескольких плееров разбор master-плейлиста в дорожки.
List<VideoStream> parseVariants(String masterContent, VideoStream master) {
  final variants = parseMasterPlaylist(masterContent, master.url);
  return [
    for (final variant in variants)
      VideoStream(
        url: variant.url,
        kind: StreamKind.hls,
        quality: variant.height,
        headers: master.headers,
        label: variant.height != null ? '${variant.height}p' : null,
        extra: {
          'bandwidth': variant.bandwidth,
          'codecs': variant.codecs,
          if (variant.audioUrl != null) 'audio_url': variant.audioUrl,
        },
      ),
  ];
}
