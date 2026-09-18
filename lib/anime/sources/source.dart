/// Общие типы каталога: карточка, вариант плеера, страница тайтла.
///
/// Оба источника (AnimeGO и Animedia) отдают наружу одно и то же, поэтому
/// остальному приложению всё равно, откуда данные.
library;

/// Карточка аниме в выдаче поиска и в личном списке.
class AnimeCard {
  const AnimeCard({
    required this.id,
    required this.title,
    required this.source,
    this.url = '',
    this.originalTitle,
    this.poster,
    this.rating,
    this.description,
    this.genres = const [],
  });

  /// Идентификатор внутри источника: у AnimeGO это `slug-номер`.
  final String id;
  final String title;

  /// `animego` | `animedia`
  final String source;
  final String url;
  final String? originalTitle;
  final String? poster;
  final String? rating;
  final String? description;
  final List<String> genres;

  AnimeCard copyWith({
    String? title,
    String? poster,
    String? description,
    List<String>? genres,
    String? rating,
    String? originalTitle,
    String? url,
  }) {
    return AnimeCard(
      id: id,
      title: title ?? this.title,
      source: source,
      url: url ?? this.url,
      originalTitle: originalTitle ?? this.originalTitle,
      poster: poster ?? this.poster,
      rating: rating ?? this.rating,
      description: description ?? this.description,
      genres: genres ?? this.genres,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'source': source,
        'url': url,
        'original_title': originalTitle,
        'poster': poster,
        'rating': rating,
      };

  static AnimeCard fromJson(Map<String, dynamic> json) => AnimeCard(
        id: json['id'] as String,
        title: json['title'] as String,
        source: json['source'] as String? ?? 'animego',
        url: json['url'] as String? ?? '',
        originalTitle: json['original_title'] as String?,
        poster: json['poster'] as String?,
        rating: json['rating'] as String?,
      );
}

/// Один плеер + одна озвучка для конкретной серии.
class PlayerOption {
  const PlayerOption({
    required this.key,
    required this.player,
    required this.label,
    required this.embed,
    required this.episode,
  });

  /// Стабильный ключ, по которому запоминается выбор зрителя.
  final String key;

  /// Название плеера так, как его пишет сайт: `AniBoom`, `CVH`, `Kodik`.
  final String player;

  /// Название озвучки.
  final String label;

  /// Ссылка, которую надо отдать в [PlayerRegistry.extract].
  final String embed;
  final int episode;

  static String buildKey(String player, String label) =>
      '${player.toLowerCase()}::${label.toLowerCase()}';
}

/// Страница тайтла: карточка, список серий и плееры выбранной серии.
class AnimeDetails {
  const AnimeDetails({
    required this.card,
    required this.episodes,
    required this.players,
    required this.episode,
  });

  final AnimeCard card;
  final List<int> episodes;
  final List<PlayerOption> players;
  final int episode;
}

/// Минимум, который должен уметь источник каталога.
abstract class CatalogSource {
  String get name;

  Future<List<AnimeCard>> search(String query, {int limit = 20});

  Future<AnimeCard> card(String animeId);

  Future<List<int>> episodes(String animeId);

  Future<List<PlayerOption>> players(String animeId, int episode);
}
