/// Источник Animedia (amd.online) — страховка на случай блокировки AnimeGO.
///
/// Сайт отдаёт два плеера: собственный `aser.pro/vod/<id>` и iframe Kodik.
/// Идентификатор тайтла — упакованный в base64 адрес страницы, поэтому источник
/// не хранит состояние между запросами.
library;

import 'dart:convert';

import '../../core/errors.dart';
import '../../core/http.dart';
import '../../core/utils.dart';
import 'source.dart';

final RegExp _searchLink = RegExp(
  r'href="(https://[^"]+/(\d+)-[a-z0-9\-]+\.html)"',
  caseSensitive: false,
);
final RegExp _titleRe = RegExp(r'<h1[^>]*>([^<]+)</h1>', caseSensitive: false);
final RegExp _episodeLink = RegExp(
  r'data-vid="(\d+)"\s+data-vlnk="([^"]+)"',
  caseSensitive: false,
);
final RegExp _kodikIframe = RegExp(
  r'(?:src|data-src)="((?://|https://)kodik[^"]+)"',
  caseSensitive: false,
);
final RegExp _posterRe = RegExp(
  r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"',
  caseSensitive: false,
);
final RegExp _slugRe = RegExp(r'/\d+-([a-z0-9\-]+)\.html');

class AnimediaSource implements CatalogSource {
  AnimediaSource(this.client, {String baseUrl = 'https://amd.online'})
      : baseUrl = baseUrl.replaceAll(RegExp(r'/$'), '');

  final AnimeHttpClient client;
  final String baseUrl;

  final Map<String, Map<int, String>> _episodesCache = {};

  @override
  String get name => 'animedia';

  /// Адрес страницы -> компактный идентификатор, пригодный для хранения.
  static String encodeId(String url) =>
      base64Url.encode(utf8.encode(url)).replaceAll('=', '');

  static String decodeId(String value) {
    final padded = value + '=' * ((4 - value.length % 4) % 4);
    try {
      return utf8.decode(base64Url.decode(padded));
    } catch (_) {
      throw NotFoundError('Некорректный идентификатор аниме: $value');
    }
  }

  @override
  Future<List<AnimeCard>> search(String query, {int limit = 20}) async {
    final response = await client.get(
      '$baseUrl/index.php',
      params: {'do': 'search', 'subaction': 'search', 'story': query},
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.status == 403 || response.status == 503) {
      throw ServiceError(
        'Animedia ответила ${response.status} — возможно, защита от ботов.',
        status: response.status,
        url: response.url,
      );
    }
    response.raiseForStatus();

    final items = <AnimeCard>[];
    final seen = <String>{};
    for (final match in _searchLink.allMatches(response.text)) {
      final url = match.group(1)!;
      final id = match.group(2)!;
      if (!seen.add(id)) continue;
      items.add(
        AnimeCard(
          id: encodeId(url),
          title: _titleFromUrl(url),
          source: name,
          url: url,
        ),
      );
      if (items.length >= limit) break;
    }
    if (items.isEmpty) {
      throw NotFoundError('По запросу «$query» на Animedia ничего не нашлось');
    }
    return items;
  }

  @override
  Future<AnimeCard> card(String animeId) async {
    final pageUrl = decodeId(animeId);
    final text = await _page(pageUrl);
    final title = _titleRe.firstMatch(text)?.group(1);
    return AnimeCard(
      id: animeId,
      title: title == null ? _titleFromUrl(pageUrl) : unescapeHtml(title).trim(),
      source: name,
      url: pageUrl,
      poster: _posterRe.firstMatch(text)?.group(1),
    );
  }

  /// `{номер серии: ссылка на плеер aser.pro}`.
  Future<Map<int, String>> episodeLinks(String animeId) async {
    final cached = _episodesCache[animeId];
    if (cached != null) return cached;

    final text = await _page(decodeId(animeId));
    final episodes = <int, String>{};
    for (final match in _episodeLink.allMatches(text)) {
      var link = match.group(2)!;
      if (link.startsWith('//')) link = 'https:$link';
      episodes.putIfAbsent(int.parse(match.group(1)!), () => unescapeHtml(link));
    }
    if (episodes.isEmpty) {
      throw NotFoundError('На странице тайтла не нашлось ни одной серии');
    }
    _episodesCache[animeId] = episodes;
    return episodes;
  }

  @override
  Future<List<int>> episodes(String animeId) async {
    final links = await episodeLinks(animeId);
    final numbers = links.keys.toList()..sort();
    return numbers.isEmpty ? [1] : numbers;
  }

  @override
  Future<List<PlayerOption>> players(String animeId, int episode) async {
    final links = await episodeLinks(animeId);
    final link = links[episode];
    if (link == null) {
      throw NotFoundError('У этого тайтла нет серии $episode');
    }
    final options = <PlayerOption>[
      PlayerOption(
        key: PlayerOption.buildKey('animedia', 'Animedia'),
        player: 'Animedia',
        label: 'Animedia',
        embed: link,
        episode: episode,
      ),
    ];

    // Kodik на странице тайтла один на весь тайтл — номер серии передаётся ему
    // отдельно при разборе, поэтому для первой серии он тоже подходит.
    final text = await _page(decodeId(animeId));
    for (final match in _kodikIframe.allMatches(text)) {
      var kodik = match.group(1)!;
      if (kodik.startsWith('//')) kodik = 'https:$kodik';
      options.add(
        PlayerOption(
          key: PlayerOption.buildKey('kodik', 'Kodik'),
          player: 'Kodik',
          label: 'Kodik',
          embed: kodik,
          episode: episode,
        ),
      );
      break;
    }
    return options;
  }

  Future<String> _page(String url) async {
    final response = await client.get(url, headers: {'Referer': '$baseUrl/'});
    if (response.status == 404) {
      throw NotFoundError('Страница не найдена: $url');
    }
    return response.raiseForStatus().text;
  }

  /// Запасное название из слага, когда h1 недоступен.
  static String _titleFromUrl(String url) {
    final match = _slugRe.firstMatch(url);
    if (match == null) return url;
    final words = match.group(1)!.replaceAll('-', ' ');
    return words.isEmpty ? url : '${words[0].toUpperCase()}${words.substring(1)}';
  }
}
