/// Плеер CVH — CdnVideoHub (plapi.cdnvideohub.com), на AnimeGO значится как «CVH».
///
/// У тайтла есть числовой `cvh_id`, который сайт подставляет в iframe
/// (`/cdn-iframe/<cvh_id>/<studio>/<season>/<episode>`). По этому id открытый API
/// отдаёт плейлист всех серий и озвучек, а по `vkId` одной серии — её дорожки.
/// Видео раздаёт CDN Одноклассников, поэтому кроме HLS/DASH есть прямые mp4.
library;

import '../../core/errors.dart';
import '../../core/utils.dart';
import '../models.dart';
import 'base.dart';

final RegExp _iframeRe = RegExp(
  r'/cdn-iframe/(\d+)(?:/([^/?#]+))?(?:/(\d+))?(?:/(\d+))?',
  caseSensitive: false,
);
final RegExp _videoRe = RegExp(r'/player/sv/video/(\d+)', caseSensitive: false);

/// Ключи ответа CVH (именование Одноклассников) -> высота картинки.
const Map<String, int> cvhQualityKeys = {
  'mpegMobileUrl': 144,
  'mpegTinyUrl': 144,
  'mpegLowestUrl': 240,
  'mpegLowUrl': 360,
  'mpegMediumUrl': 480,
  'mpegHighUrl': 720,
  'mpegFullHdUrl': 1080,
  'mpegQhdUrl': 1440,
  'mpeg2kUrl': 2048,
  'mpeg4kUrl': 2160,
};

/// Одна запись плейлиста CVH: серия в конкретной озвучке.
class CvhEpisode {
  const CvhEpisode({
    required this.cvhId,
    required this.videoId,
    required this.season,
    required this.episode,
    this.studio,
    this.voiceType,
  });

  final String cvhId;
  final String videoId;
  final String? studio;
  final String? voiceType;
  final int season;
  final int episode;

  static CvhEpisode fromApi(Map<String, dynamic> item) => CvhEpisode(
        cvhId: '${item['cvhId'] ?? ''}',
        videoId: '${item['vkId'] ?? ''}',
        studio: item['voiceStudio'] as String?,
        voiceType: item['voiceType'] as String?,
        season: toInt(item['season']) ?? 1,
        episode: toInt(item['episode']) ?? 1,
      );
}

class CvhPlayer extends BasePlayer {
  CvhPlayer(super.client, {this.pub = '747', this.aggr = 'mali'});

  /// Идентификаторы издателя и агрегатора — по умолчанию те, что у animego.org.
  final String pub;
  final String aggr;

  static const String apiBase = 'https://plapi.cdnvideohub.com/api/v1/player/sv';
  static const String defaultReferer = 'https://animego.org/';

  @override
  String get name => 'cvh';

  @override
  String get title => 'CVH (CdnVideoHub)';

  @override
  List<RegExp> get urlPatterns => [RegExp(r'/cdn-iframe/\d+')];

  /// Разбирает iframe-ссылку, голый числовой id или `/player/sv/video/<vkId>`.
  static Map<String, Object?> parseUrl(String url) {
    final value = url.trim();
    if (RegExp(r'^\d+$').hasMatch(value)) return {'cvh_id': value};
    final video = _videoRe.firstMatch(value);
    if (video != null) return {'video_id': video.group(1)};
    final match = _iframeRe.firstMatch(value);
    if (match == null) {
      throw ExtractionError(
        'Не разобрать ссылку CVH: $url. Ожидается '
        '/cdn-iframe/<id>/<studio>/<season>/<episode> или числовой id.',
      );
    }
    final studio = match.group(2);
    return {
      'cvh_id': match.group(1),
      'studio': studio?.replaceAll('%20', ' '),
      'season': match.group(3) == null ? null : int.tryParse(match.group(3)!),
      'episode': match.group(4) == null ? null : int.tryParse(match.group(4)!),
    };
  }

  /// Все серии и озвучки тайтла.
  Future<List<CvhEpisode>> playlist(String cvhId) async {
    final response = await client.get(
      '$apiBase/playlist?pub=$pub&aggr=$aggr&id=$cvhId',
      headers: _apiHeaders(),
    );
    final data = response.raiseForStatus().jsonMap();
    final items = data['items'];
    if (items is! List || items.isEmpty) {
      throw NotFoundError('CVH вернул пустой плейлист для id=$cvhId');
    }
    return [
      for (final item in items)
        if (item is Map<String, dynamic>) CvhEpisode.fromApi(item),
    ];
  }

  @override
  Future<PlayerResult> extract(
    String url, [
    ExtractOptions options = const ExtractOptions(),
  ]) async {
    final parsed = parseUrl(url);
    final season = options.season ?? parsed['season'] as int?;
    final episode = options.episode ?? parsed['episode'] as int?;
    final studio = options.studio ?? parsed['studio'] as String?;

    final videoId = parsed['video_id'] as String?;
    if (videoId != null) {
      return extractVideo(videoId, sourceUrl: url);
    }

    final items = await playlist(parsed['cvh_id'] as String);
    final chosen = select(items, season: season, episode: episode, studio: studio);
    return extractVideo(chosen.videoId, sourceUrl: url, episode: chosen);
  }

  /// Дорожки по `vkId` конкретного видео.
  Future<PlayerResult> extractVideo(
    String videoId, {
    String? sourceUrl,
    CvhEpisode? episode,
  }) async {
    final response = await client.get('$apiBase/video/$videoId', headers: _apiHeaders());
    return _buildResult(response.raiseForStatus().jsonMap(), videoId, sourceUrl, episode);
  }

  /// Выбирает серию из плейлиста.
  static CvhEpisode select(
    List<CvhEpisode> items, {
    int? season,
    int? episode,
    String? studio,
  }) {
    if (items.isEmpty) throw const NotFoundError('Плейлист CVH пуст');

    final seasons = items.map((item) => item.season).toSet().toList()..sort();
    final wantedSeason = seasons.length == 1 ? seasons.first : (season ?? seasons.first);
    var pool = items.where((item) => item.season == wantedSeason).toList();
    if (pool.isEmpty) {
      throw NotFoundError('Сезон $wantedSeason не найден. Есть: ${seasons.join(', ')}');
    }

    final episodes = pool.map((item) => item.episode).toSet().toList()..sort();
    final wantedEpisode = episode ?? episodes.first;
    pool = pool.where((item) => item.episode == wantedEpisode).toList();
    if (pool.isEmpty) {
      throw NotFoundError(
        'Серия $wantedEpisode не найдена в сезоне $wantedSeason.',
      );
    }

    if (studio != null && studio.isNotEmpty) {
      final match = _matchStudio(studio, pool);
      if (match == null) {
        throw NotFoundError(
          'Озвучка «$studio» не найдена. Есть: '
          '${pool.map((item) => item.studio).whereType<String>().join(', ')}',
        );
      }
      return match;
    }
    return pool.first;
  }

  Map<String, String> _apiHeaders() => {
        'Referer': defaultReferer,
        'Accept': 'application/json',
      };

  PlayerResult _buildResult(
    Map<String, dynamic> data,
    String videoId,
    String? sourceUrl,
    CvhEpisode? episode,
  ) {
    final sources = data['sources'];
    final headers = {'User-Agent': client.userAgent};
    final streams = <VideoStream>[];

    if (sources is Map<String, dynamic>) {
      final hls = sources['hlsUrl'];
      if (hls is String && hls.isNotEmpty) {
        streams.add(
          VideoStream(url: hls, kind: StreamKind.hls, headers: headers, label: 'master'),
        );
      }
      final dash = sources['dashUrl'] ?? sources['dashManifestUrl'];
      if (dash is String && dash.isNotEmpty) {
        streams.add(
          VideoStream(url: dash, kind: StreamKind.dash, headers: headers, label: 'master'),
        );
      }
      sources.forEach((key, value) {
        if (value is! String || !value.startsWith('http')) return;
        if (key == 'hlsUrl' || key == 'dashUrl' || key == 'dashManifestUrl') return;
        final quality = cvhQualityKeys[key] ?? qualityFromLabel(key);
        streams.add(
          VideoStream(
            url: value,
            kind: StreamKind.mp4,
            quality: quality,
            headers: headers,
            label: quality != null ? '${quality}p' : key,
            extra: {'source_key': key},
          ),
        );
      });
    }

    if (streams.isEmpty) {
      throw NoStreamsFoundError('CVH не вернул ссылок для видео $videoId');
    }

    return PlayerResult(
      player: name,
      sourceUrl: sourceUrl ?? '$apiBase/video/$videoId',
      streams: streams,
      poster: data['thumbUrl'] as String?,
      duration: toInt(data['duration']),
      translation: episode?.studio,
      extra: {'video_id': videoId},
    );
  }
}

/// Нестрогое сопоставление названия озвучки: сначала точное, потом по вхождению.
CvhEpisode? _matchStudio(String name, List<CvhEpisode> items) {
  final wanted = name.trim().toLowerCase();
  for (final item in items) {
    if ((item.studio ?? '').trim().toLowerCase() == wanted) return item;
  }
  for (final item in items) {
    final studio = (item.studio ?? '').trim().toLowerCase();
    if (studio.isNotEmpty && (studio.contains(wanted) || wanted.contains(studio))) {
      return item;
    }
  }
  return null;
}
