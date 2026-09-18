/// Плеер AniLibria / AniLiberty (anilibria.top).
///
/// Строго говоря, это не embed-плеер, а открытый API: по алиасу релиза он отдаёт
/// список серий с готовыми HLS-ссылками 480/720/1080 и таймкодами опенинга и
/// эндинга. Токен не нужен.
library;

import '../../core/errors.dart';
import '../../core/utils.dart';
import '../models.dart';
import 'base.dart';

final RegExp _releaseRe = RegExp(r'/release/([A-Za-z0-9_-]+)', caseSensitive: false);
final RegExp _episodeRe = RegExp(r'/episodes?/(\d+)', caseSensitive: false);
final RegExp _hlsKeyRe = RegExp(r'^hls_(\d{3,4})$');

class AnilibriaPlayer extends BasePlayer {
  AnilibriaPlayer(super.client, {String? apiBase})
      : apiBase = (apiBase ?? 'https://anilibria.top/api/v1').replaceAll(RegExp(r'/$'), '');

  final String apiBase;

  static const String siteBase = 'https://anilibria.top';

  @override
  String get name => 'anilibria';

  @override
  String get title => 'AniLibria (AniLiberty)';

  @override
  List<RegExp> get urlPatterns =>
      [RegExp(r'anilib(?:ria|erty)\.[a-z]+/anime/releases/release/')];

  /// Полные данные релиза по алиасу или id.
  Future<Map<String, dynamic>> release(String alias) async {
    final response = await client.get(
      '$apiBase/anime/releases/$alias',
      headers: {'Accept': 'application/json'},
    );
    return _checkRelease(response.raiseForStatus().jsonMap(), alias);
  }

  /// Поиск релизов по названию — так находится алиас.
  Future<List<Map<String, dynamic>>> search(String query, {int limit = 10}) async {
    final response = await client.get(
      '$apiBase/app/search/releases',
      params: {'query': query, 'limit': limit},
      headers: {'Accept': 'application/json'},
    );
    final data = response.raiseForStatus().data;
    final items = data is Map ? data['data'] : data;
    if (items is! List) return const [];
    return [
      for (final item in items.take(limit))
        if (item is Map<String, dynamic>) item,
    ];
  }

  @override
  Future<PlayerResult> extract(
    String url, [
    ExtractOptions options = const ExtractOptions(),
  ]) async {
    final parsed = _parse(url, options.episode);
    final data = await release(parsed.alias);
    return _buildResult(data, parsed.alias, parsed.episode, url);
  }

  static _AliasEpisode _parse(String url, int? episode) {
    final value = url.trim();
    if (value.startsWith('http')) {
      final alias = searchOrNull(_releaseRe, value);
      if (alias == null) {
        throw NotFoundError('В ссылке $url нет алиаса релиза AniLibria');
      }
      final fromUrl = searchOrNull(_episodeRe, value);
      return _AliasEpisode(alias, episode ?? (fromUrl == null ? null : int.tryParse(fromUrl)));
    }
    if (value.contains('/')) {
      final parts = value.split('/');
      final tail = parts.length > 1 ? parts[1].trim() : '';
      return _AliasEpisode(parts.first, episode ?? int.tryParse(tail));
    }
    return _AliasEpisode(value, episode);
  }

  static Map<String, dynamic> _checkRelease(Map<String, dynamic> data, String alias) {
    if (data['id'] == null) {
      throw NotFoundError('Релиз «$alias» на AniLibria не найден');
    }
    if (data['is_blocked_by_geo'] == true) {
      throw ContentBlockedError(
        'Релиз «$alias» заблокирован в вашем регионе — нужен прокси.',
      );
    }
    return data;
  }

  static Map<String, dynamic> _selectEpisode(List<dynamic> episodes, int? number) {
    if (episodes.isEmpty) throw const NotFoundError('У релиза нет ни одной серии');
    if (number == null) return episodes.first as Map<String, dynamic>;
    for (final item in episodes) {
      if (item is Map<String, dynamic> && (toInt(item['ordinal']) ?? 0) == number) {
        return item;
      }
    }
    throw NotFoundError('Серия $number не найдена (всего ${episodes.length})');
  }

  PlayerResult _buildResult(
    Map<String, dynamic> release,
    String alias,
    int? number,
    String sourceUrl,
  ) {
    final episode = _selectEpisode(release['episodes'] as List<dynamic>? ?? const [], number);
    final headers = {'User-Agent': client.userAgent};

    final streams = <VideoStream>[];
    episode.forEach((key, value) {
      final match = _hlsKeyRe.firstMatch(key);
      if (match != null && value is String && value.startsWith('http')) {
        final quality = int.parse(match.group(1)!);
        streams.add(
          VideoStream(
            url: value,
            kind: StreamKind.hls,
            quality: quality,
            headers: headers,
            label: '${quality}p',
          ),
        );
      }
    });
    streams.sort((a, b) => (a.quality ?? 0).compareTo(b.quality ?? 0));

    if (streams.isEmpty) {
      throw NoStreamsFoundError(
        'AniLibria не вернула ссылок для серии $number релиза «$alias»',
      );
    }

    final skip = <SkipSegment>[];
    for (final kind in const ['opening', 'ending']) {
      final block = episode[kind];
      if (block is Map) {
        final start = toInt(block['start']);
        final stop = toInt(block['stop']);
        if (start != null && stop != null) skip.add(SkipSegment(start, stop, kind));
      }
    }

    final names = release['name'];
    var title = (names is Map ? (names['main'] ?? names['english']) : null) as String? ?? alias;
    final ordinal = toInt(episode['ordinal']);
    if (ordinal != null) title = '$title — серия $ordinal';
    final episodeName = episode['name'];
    if (episodeName is String && episodeName.isNotEmpty) title = '$title: $episodeName';

    var poster = (release['poster'] is Map ? release['poster']['src'] : null) as String?;
    if (poster != null && poster.startsWith('/')) poster = '$siteBase$poster';

    return PlayerResult(
      player: name,
      sourceUrl: sourceUrl,
      streams: streams,
      title: title,
      poster: poster,
      duration: toInt(episode['duration'] ?? release['average_duration_of_episode']),
      skipSegments: skip,
      extra: {
        'alias': release['alias'] ?? alias,
        'release_id': release['id'],
        'ordinal': ordinal,
        'episodes_total': release['episodes_total'],
        'is_ongoing': release['is_ongoing'],
      },
    );
  }
}

class _AliasEpisode {
  const _AliasEpisode(this.alias, this.episode);

  final String alias;
  final int? episode;
}
