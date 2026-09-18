/// Фасад каталога: один вход для поиска, серий, плееров и прямых ссылок.
///
/// Кэширует ответы источника (они меняются редко) и отдельно — прямые ссылки на
/// видео (они, наоборот, живут минуты). Ошибки библиотеки переводит в понятные
/// человеку сообщения: экран показывает их как есть.
library;

import '../core/errors.dart';
import '../core/http.dart';
import 'models.dart';
import 'registry.dart';
import 'sources/animedia_site.dart';
import 'sources/animego.dart';
import 'sources/source.dart';

export 'sources/source.dart';

/// Значение с временем жизни.
class _Entry<T> {
  _Entry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;

  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

class _TtlCache<T> {
  _TtlCache(this.ttl);

  final Duration ttl;
  final Map<String, _Entry<T>> _entries = {};
  final Map<String, Future<T>> _inFlight = {};

  /// Один и тот же ключ не запрашивается дважды одновременно.
  Future<T> getOrSet(String key, Future<T> Function() build) {
    final cached = _entries[key];
    if (cached != null && cached.isFresh) return Future.value(cached.value);
    final running = _inFlight[key];
    if (running != null) return running;

    final future = build().then((value) {
      _entries[key] = _Entry(value, DateTime.now().add(ttl));
      return value;
    }).whenComplete(() {
      // тело блоком обязательно: `=> _inFlight.remove(key)` вернуло бы сам этот
      // future, и whenComplete стал бы ждать его завершения — то есть себя
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  void clear() {
    _entries.clear();
  }
}

/// Настройки, от которых зависит каталог.
class CatalogConfig {
  const CatalogConfig({
    this.source = 'animego',
    this.animegoMirror = '',
    this.animediaBaseUrl = 'https://amd.online',
    this.proxy = '',
    this.timeoutSeconds = 25,
    this.maxQuality = 1080,
  });

  final String source;
  final String animegoMirror;
  final String animediaBaseUrl;
  final String proxy;
  final int timeoutSeconds;
  final int maxQuality;

  bool sameNetwork(CatalogConfig other) =>
      source == other.source &&
      animegoMirror == other.animegoMirror &&
      animediaBaseUrl == other.animediaBaseUrl &&
      proxy == other.proxy &&
      timeoutSeconds == other.timeoutSeconds;
}

/// Всё, что нужно плееру для одной серии.
class EpisodeSource {
  const EpisodeSource({
    required this.animeId,
    required this.animeTitle,
    required this.episode,
    required this.option,
    required this.streams,
    required this.skipSegments,
    this.poster,
    this.duration,
  });

  final String animeId;
  final String animeTitle;
  final int episode;
  final PlayerOption option;

  /// Дорожки в порядке «что включать»: master-плейлист, дальше по убыванию.
  final List<VideoStream> streams;
  final List<SkipSegment> skipSegments;
  final String? poster;
  final int? duration;

  VideoStream get preferred => streams.first;

  /// Лучшая дорожка, которую можно сохранить одним файлом.
  VideoStream? get downloadable {
    final candidates = streams.where((stream) => stream.isDownloadable).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final byQuality = (a.quality ?? 0).compareTo(b.quality ?? 0);
      if (byQuality != 0) return byQuality;
      return a.kind.downloadRank.compareTo(b.kind.downloadRank);
    });
    return candidates.last;
  }
}

class Catalog {
  Catalog(CatalogConfig config) : _config = config {
    _rebuild();
  }

  CatalogConfig _config;
  late AnimeHttpClient _client;
  late CatalogSource _source;
  late PlayerRegistry _registry;

  final _TtlCache<List<AnimeCard>> _searchCache = _TtlCache(const Duration(minutes: 10));
  final _TtlCache<List<int>> _episodesCache = _TtlCache(const Duration(minutes: 10));
  final _TtlCache<List<PlayerOption>> _playersCache = _TtlCache(const Duration(minutes: 10));
  final _TtlCache<AnimeCard> _cardCache = _TtlCache(const Duration(minutes: 30));
  final _TtlCache<PlayerResult> _streamCache = _TtlCache(const Duration(minutes: 4));

  CatalogConfig get config => _config;

  String get sourceName => _source.name;

  AnimeHttpClient get client => _client;

  /// Пересобирает клиента и источник, когда поменялись настройки сети.
  void updateConfig(CatalogConfig config) {
    final needsRebuild = !_config.sameNetwork(config);
    _config = config;
    if (needsRebuild) {
      _client.close();
      _rebuild();
      clearCaches();
    }
  }

  void _rebuild() {
    _client = AnimeHttpClient(
      timeout: Duration(seconds: _config.timeoutSeconds),
      proxy: _config.proxy,
    );
    _source = _config.source == 'animedia'
        ? AnimediaSource(_client, baseUrl: _config.animediaBaseUrl)
        : AnimeGoSource(_client, mirror: _config.animegoMirror);
    _registry = PlayerRegistry(_client);
  }

  void clearCaches() {
    _searchCache.clear();
    _episodesCache.clear();
    _playersCache.clear();
    _cardCache.clear();
    _streamCache.clear();
  }

  Future<List<AnimeCard>> search(String query, {int limit = 24}) {
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      throw const NotFoundError('Запрос слишком короткий — введите хотя бы 2 символа.');
    }
    return _guard(
      () => _searchCache.getOrSet(
        '$sourceName|search|${trimmed.toLowerCase()}|$limit',
        () => _source.search(trimmed, limit: limit),
      ),
    );
  }

  Future<AnimeCard> card(String animeId) {
    return _guard(
      () => _cardCache.getOrSet(
        '$sourceName|card|$animeId',
        () => _source.card(animeId),
      ),
    );
  }

  Future<List<int>> episodes(String animeId) {
    return _guard(
      () => _episodesCache.getOrSet(
        '$sourceName|episodes|$animeId',
        () => _source.episodes(animeId),
      ),
    );
  }

  Future<List<PlayerOption>> players(String animeId, int episode) {
    return _guard(
      () => _playersCache.getOrSet(
        '$sourceName|players|$animeId|$episode',
        () => _source.players(animeId, episode),
      ),
    );
  }

  /// Страница тайтла целиком.
  Future<AnimeDetails> details(String animeId, {int episode = 1, AnimeCard? card}) async {
    final list = await episodes(animeId);
    final number = list.contains(episode) ? episode : list.first;
    final options = await players(animeId, number);
    final info = card ?? await _cardOrStub(animeId, options);
    return AnimeDetails(
      card: info,
      episodes: list,
      players: options,
      episode: number,
    );
  }

  Future<AnimeCard> _cardOrStub(String animeId, List<PlayerOption> options) async {
    try {
      return await card(animeId);
    } on AnimeError {
      return AnimeCard(
        id: animeId,
        title: options.isNotEmpty ? options.first.label : 'Аниме $animeId',
        source: sourceName,
      );
    }
  }

  /// Выбирает плеер: запрошенный, либо ту же озвучку, либо первый доступный.
  Future<PlayerOption> pickPlayer(String animeId, int episode, {String? playerKey}) async {
    final options = await players(animeId, episode);
    if (options.isEmpty) {
      throw const NotFoundError('Для этой серии не нашлось ни одного плеера.');
    }
    if (playerKey != null && playerKey.isNotEmpty) {
      for (final option in options) {
        if (option.key == playerKey) return option;
      }
      // та же озвучка могла переехать на другой плеер — ищем по названию
      final wantedLabel = playerKey.split('::').last;
      for (final option in options) {
        if (option.label.toLowerCase() == wantedLabel) return option;
      }
    }
    return options.first;
  }

  /// Прямые ссылки на видео. Кэш короткий: ссылки протухают.
  Future<PlayerResult> resolve(PlayerOption option) {
    return _streamCache.getOrSet(
      '${option.embed}|${option.episode}',
      () => _extract(option),
    );
  }

  Future<PlayerResult> _extract(PlayerOption option) async {
    // у Kodik-ссылок вида /serial/... номер серии передаётся отдельно
    final needsEpisode = option.embed.contains('kodik') && option.embed.contains('/serial/');
    final options = ExtractOptions(
      episode: needsEpisode ? option.episode : null,
      maxQuality: _config.maxQuality,
    );
    try {
      final result = await _registry.extract(option.embed, options);
      if (result.isEmpty) {
        throw const NoStreamsFoundError('Плеер не отдал ни одной дорожки.');
      }
      return result;
    } on UnsupportedUrlError {
      throw NotFoundError('Плеер ${option.player} пока не поддерживается.');
    } on ServiceError catch (error) {
      throw ServiceError(
        'Плеер ${option.player} временно недоступен (${error.message}). '
        'Попробуйте другую озвучку.',
        status: error.status,
        url: error.url,
      );
    }
  }

  /// Готовит серию к просмотру: выбирает плеер, достаёт и сортирует дорожки.
  Future<EpisodeSource> buildSource(
    String animeId,
    int episode, {
    String? playerKey,
    AnimeCard? card,
  }) async {
    final option = await pickPlayer(animeId, episode, playerKey: playerKey);
    final result = await resolve(option);
    final info = card ?? await _cardOrStub(animeId, [option]);
    return EpisodeSource(
      animeId: animeId,
      animeTitle: info.title.isNotEmpty ? info.title : (result.title ?? 'Аниме'),
      episode: episode,
      option: option,
      streams: _streamsForPlayer(result),
      skipSegments: result.skipSegments,
      poster: info.poster ?? result.poster,
      duration: result.duration,
    );
  }

  /// Отбирает дорожки: сперва то, что стоит включать по умолчанию.
  ///
  /// Master-плейлист HLS идёт первым — плеер сам подберёт качество под связь;
  /// дальше по убыванию качества.
  List<VideoStream> _streamsForPlayer(PlayerResult result) {
    var candidates = result.streams
        .where((stream) => stream.quality == null || stream.quality! <= _config.maxQuality)
        .toList();
    if (candidates.isEmpty) {
      candidates = [...result.streams]
        ..sort((a, b) => (a.quality ?? 0).compareTo(b.quality ?? 0));
      candidates = candidates.take(1).toList();
    }
    if (candidates.isEmpty) {
      throw const NoStreamsFoundError('Плеер не отдал ни одной дорожки.');
    }
    candidates.sort((a, b) {
      final byMaster = (a.isMaster ? 1 : 0).compareTo(b.isMaster ? 1 : 0);
      if (byMaster != 0) return byMaster;
      final byQuality = (a.quality ?? 0).compareTo(b.quality ?? 0);
      if (byQuality != 0) return byQuality;
      return a.kind.downloadRank.compareTo(b.kind.downloadRank);
    });
    return candidates.reversed.toList();
  }

  Future<T> _guard<T>(Future<T> Function() build) async {
    try {
      return await build();
    } on ServiceError {
      throw const ServiceError(
        'Источник ответил ошибкой — скорее всего, сработала защита от ботов. '
        'Помогает зеркало, прокси или другой источник в настройках.',
      );
    }
  }

  void close() => _client.close();
}
