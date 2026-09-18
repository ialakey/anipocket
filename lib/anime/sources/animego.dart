/// Источник AnimeGO: поиск, карточка тайтла, серии и список плееров.
///
/// Порт `anime_dl_core/sources/animego.py` плюс разбор страницы тайтла, который
/// на сайте живёт в отдельном слое. Вёрстка сайта время от времени меняется —
/// когда поиск перестанет работать, чинить надо регулярки в этом файле.
library;

import '../../core/errors.dart';
import '../../core/http.dart';
import '../../core/utils.dart';
import 'source.dart';

final RegExp _itemSplit = RegExp(r'class="ani-grid__item ');
final RegExp _itemLink = RegExp(r'href="(/anime/([a-z0-9\-]+)-(\d+))"', caseSensitive: false);
final RegExp _itemTitle = RegExp(r'<a\s+title="([^"]+)"\s+href="/anime/[^"]+"');
final RegExp _itemImage = RegExp(r'<img[^>]+src="([^"]+)"');
final RegExp _itemRating = RegExp(r'class="rating-badge[^"]*">\s*([\d.]+)\s*<');
final RegExp _itemOriginal = RegExp(r'text-line-clamp"[^>]*>\s*([^<>]{2,120}?)\s*</div>');
final RegExp _button = RegExp(r'<button\b[^>]*>', caseSensitive: false);
final RegExp _attr = RegExp(r'([a-zA-Z0-9\-]+)="([^"]*)"');
final RegExp _episode = RegExp(
  r'data-episode="(\d+)"[^>]*data-episode-number="(\d+)"',
  caseSensitive: false,
);
final RegExp _episodeReversed = RegExp(
  r'data-episode-number="(\d+)"[^>]*data-episode="(\d+)"',
  caseSensitive: false,
);

final RegExp _ogTitle = RegExp(
  r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"',
  caseSensitive: false,
);
final RegExp _ogImage = RegExp(
  r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"',
  caseSensitive: false,
);
final RegExp _ogDescription = RegExp(
  r'<meta[^>]+property="og:description"[^>]+content="([^"]*)"',
  caseSensitive: false,
);
final RegExp _h1 = RegExp(r'<h1[^>]*>\s*([^<]+?)\s*</h1>', caseSensitive: false);

/// og:title у AnimeGO выглядит как «Название (2 сезон) смотреть онлайн — Аниме».
final RegExp _titleTail = RegExp(
  r'\s*(?:\(\d+\s+сезон\))?\s+смотреть\s+онлайн.*$',
  caseSensitive: false,
);
final RegExp _genreLink = RegExp(r'href="/anime/genre/[^"]*"[^>]*>\s*([^<]{2,40}?)\s*</a>');

/// Идентификатор AnimeGO — «слаг-номер»: номер нужен плеерам, слаг — странице.
final RegExp _numeric = RegExp(r'(\d+)$');

class AnimeGoSource implements CatalogSource {
  AnimeGoSource(this.client, {String? mirror})
      : baseUrl = mirror != null && mirror.trim().isNotEmpty
            ? 'https://${mirror.trim().replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/$'), '')}'
            : 'https://animego.org';

  final AnimeHttpClient client;
  final String baseUrl;

  final Map<String, Map<int, String>> _episodesCache = {};

  @override
  String get name => 'animego';

  /// `naruto-uragannye-hroniki-103` -> `103`.
  static String animeNumber(String animeId) {
    final match = _numeric.firstMatch(animeId.trim());
    if (match == null) {
      throw NotFoundError('Некорректный идентификатор аниме: $animeId');
    }
    return match.group(1)!;
  }

  @override
  Future<List<AnimeCard>> search(String query, {int limit = 20}) async {
    final response = await client.get(
      '$baseUrl/search/anime?q=${Uri.encodeQueryComponent(query)}',
    );
    if (response.status == 403 || response.status == 503) {
      throw ServiceError(
        'AnimeGO ответил ${response.status} — похоже, сработала защита Cloudflare. '
        'Помогает зеркало или прокси в настройках.',
        status: response.status,
        url: response.url,
      );
    }
    response.raiseForStatus();

    final items = <AnimeCard>[];
    final chunks = response.text.split(_itemSplit).skip(1);
    for (final chunk in chunks) {
      final link = _itemLink.firstMatch(chunk);
      final title = _itemTitle.firstMatch(chunk);
      if (link == null || title == null) continue;
      final original = _itemOriginal.firstMatch(chunk);
      final image = _itemImage.firstMatch(chunk);
      final rating = _itemRating.firstMatch(chunk);
      items.add(
        AnimeCard(
          // слаг оставляем в идентификаторе: по нему открывается страница тайтла
          id: '${link.group(2)}-${link.group(3)}',
          title: unescapeHtml(title.group(1)!),
          source: name,
          url: baseUrl + link.group(1)!,
          originalTitle: original == null ? null : unescapeHtml(original.group(1)!),
          poster: image?.group(1),
          rating: rating?.group(1),
        ),
      );
      if (items.length >= limit) break;
    }

    if (items.isEmpty) {
      if (response.text.toLowerCase().contains('ничего не найдено')) {
        throw NotFoundError('По запросу «$query» ничего не нашлось');
      }
      throw const NotFoundError(
        'AnimeGO не отдал ни одной карточки. Так бывает, когда сайт фильтрует '
        'запрос или снова сменил вёрстку.',
      );
    }
    return items;
  }

  @override
  Future<AnimeCard> card(String animeId) async {
    final number = animeNumber(animeId);
    if (animeId == number) {
      throw const NotFoundError(
        'Ссылка без слага — название по ней не определить. Откройте аниме из поиска.',
      );
    }
    final url = '$baseUrl/anime/$animeId';
    final response = await client.get(url);
    if (response.status != 200) {
      throw NotFoundError('Аниме $animeId не найдено в каталоге');
    }
    final page = response.text;

    // <h1> точнее og:title: в og-теге к названию приклеен рекламный хвост
    final rawTitle = _h1.firstMatch(page)?.group(1) ?? _ogTitle.firstMatch(page)?.group(1);
    final title = rawTitle == null
        ? null
        : unescapeHtml(rawTitle).replaceAll(_titleTail, '').trim();
    final description = _ogDescription.firstMatch(page)?.group(1);
    final genres = _genreLink
        .allMatches(page)
        .map((match) => unescapeHtml(match.group(1)!).trim())
        .where((genre) => genre.isNotEmpty)
        .toSet()
        .take(8)
        .toList();

    return AnimeCard(
      id: animeId,
      title: title == null || title.isEmpty ? 'Аниме #$number' : title,
      source: name,
      url: response.url.isEmpty ? url : response.url,
      poster: _ogImage.firstMatch(page)?.group(1),
      description: description == null || description.isEmpty
          ? null
          : unescapeHtml(description).trim(),
      genres: genres,
    );
  }

  /// `{номер серии: ссылка на плеер этой серии}`.
  Future<Map<int, String>> episodeLinks(String animeId) async {
    final number = animeNumber(animeId);
    final cached = _episodesCache[number];
    if (cached != null) return cached;

    final content = await _playerHtml('$baseUrl/player/$number');
    final episodes = <int, String>{};
    for (final match in _episode.allMatches(content)) {
      episodes[int.parse(match.group(2)!)] = '$baseUrl/player/videos/${match.group(1)}';
    }
    for (final match in _episodeReversed.allMatches(content)) {
      episodes.putIfAbsent(
        int.parse(match.group(1)!),
        () => '$baseUrl/player/videos/${match.group(2)}',
      );
    }
    _episodesCache[number] = episodes;
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
    final number = animeNumber(animeId);
    String url;
    if (episode == 1) {
      url = '$baseUrl/player/$number';
    } else {
      final links = await episodeLinks(animeId);
      final link = links[episode];
      if (link == null) {
        throw NotFoundError('У этого тайтла нет серии $episode');
      }
      url = link;
    }

    final content = await _playerHtml(url);
    final options = <PlayerOption>[];
    for (final tag in _button.allMatches(content)) {
      final attrs = <String, String>{};
      for (final attr in _attr.allMatches(tag.group(0)!)) {
        attrs[attr.group(1)!] = attr.group(2)!;
      }
      var embed = attrs['data-player'];
      final label = attrs['data-translation-title'];
      if (embed == null || label == null || embed.isEmpty || label.isEmpty) continue;
      if (embed.startsWith('//')) embed = 'https:$embed';
      final player = attrs['data-provider-title'] ?? 'unknown';
      // « (ошибка)» — пометка AnimeGO у сломанного плеера
      final cleanLabel = unescapeHtml(label).replaceAll(' (ошибка)', '').trim();
      options.add(
        PlayerOption(
          key: PlayerOption.buildKey(player, cleanLabel),
          player: player,
          label: cleanLabel,
          embed: unescapeHtml(embed),
          episode: episode,
        ),
      );
    }

    if (options.isEmpty) {
      throw NotFoundError(
        'AnimeGO не отдал ни одного плеера для серии $episode',
      );
    }
    return options;
  }

  Future<String> _playerHtml(String url) async {
    final response = await client.get(
      url,
      headers: {'X-Requested-With': 'XMLHttpRequest', 'Referer': '$baseUrl/'},
    );
    if (response.status == 403 || response.status == 503) {
      throw ServiceError(
        'AnimeGO ответил ${response.status} на запрос плеера — вероятно, Cloudflare.',
        status: response.status,
        url: url,
      );
    }
    if (response.status == 404) {
      throw NotFoundError('Плеер не найден: $url');
    }
    response.raiseForStatus();

    final data = response.data;
    if (data is! Map) {
      throw ExtractionError('Ответ плеера AnimeGO — не json ($url)');
    }
    final content = (data['data'] is Map ? data['data']['content'] : null) as String?;
    if (content == null || content.isEmpty) {
      throw ExtractionError('В ответе плеера AnimeGO нет html: $url');
    }
    return unescapeHtml(content);
  }
}
