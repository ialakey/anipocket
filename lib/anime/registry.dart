/// Реестр плееров: по ссылке понимает, кто её разберёт.
library;

import '../core/errors.dart';
import '../core/http.dart';
import 'models.dart';
import 'players/anilibria.dart';
import 'players/animedia.dart';
import 'players/aniboom.dart';
import 'players/base.dart';
import 'players/cvh.dart';
import 'players/kodik.dart';
import 'players/sibnet.dart';
import 'players/vk.dart';

export 'players/base.dart' show ExtractOptions;

/// Держит по одному экземпляру каждого плеера — HTTP-сессия переиспользуется.
class PlayerRegistry {
  PlayerRegistry(this.client)
      : players = [
          AniboomPlayer(client),
          KodikPlayer(client),
          CvhPlayer(client),
          SibnetPlayer(client),
          AnimediaPlayer(client),
          AnilibriaPlayer(client),
          VkPlayer(client),
        ];

  final AnimeHttpClient client;
  final List<BasePlayer> players;

  BasePlayer? find(String url) {
    for (final player in players) {
      if (player.matches(url)) return player;
    }
    return null;
  }

  /// Прямые ссылки на видео по embed-ссылке любого поддержанного плеера.
  Future<PlayerResult> extract(
    String url, [
    ExtractOptions options = const ExtractOptions(),
  ]) {
    final player = find(url.trim());
    if (player == null) {
      throw UnsupportedUrlError(
        'Этот плеер пока не поддерживается: $url',
      );
    }
    return player.extract(url, options);
  }

  /// Название плеера так, как его пишет сайт-агрегатор, -> наш ключ.
  static String normalizeName(String siteName) {
    final value = siteName.toLowerCase().replaceAll(' ', '');
    if (value.contains('aniboom')) return 'aniboom';
    if (value.contains('kodik')) return 'kodik';
    if (value.contains('cvh') || value.contains('cdnvideohub')) return 'cvh';
    if (value.contains('sibnet')) return 'sibnet';
    if (value.contains('animedia') || value.contains('aser')) return 'animedia';
    if (value.contains('anilib')) return 'anilibria';
    if (value.contains('vk')) return 'vk';
    return value;
  }
}
