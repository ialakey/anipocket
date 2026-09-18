/// Живая проверка порта: поиск -> серии -> плееры -> прямые ссылки.
///
/// Ходит в настоящие сайты, поэтому в `flutter test` не входит. Запуск:
///
///     dart run tool/smoke.dart "Магическая битва"
///     dart run tool/smoke.dart "Боруто" --source animedia
///
/// Когда что-то отваливается, видно ровно где: у источника или у плеера.
library;

import 'dart:io';

import 'package:anipocket/anime/catalog.dart';
import 'package:anipocket/anime/models.dart';
import 'package:anipocket/core/errors.dart';

Future<void> main(List<String> args) async {
  final query = args.isNotEmpty && !args.first.startsWith('--')
      ? args.first
      : 'Магическая битва';
  final source = _flag(args, '--source') ?? 'animego';
  final mirror = _flag(args, '--mirror') ?? '';
  final proxy = _flag(args, '--proxy') ?? '';

  final catalog = Catalog(
    CatalogConfig(source: source, animegoMirror: mirror, proxy: proxy),
  );

  try {
    stdout.writeln('Источник: ${catalog.sourceName}');
    stdout.writeln('Поиск: «$query»');
    final results = await catalog.search(query, limit: 5);
    for (final card in results.take(5)) {
      stdout.writeln('  • ${card.title}  [${card.id}]'
          '${card.rating != null ? '  ★ ${card.rating}' : ''}');
    }

    final anime = results.first;
    stdout.writeln('\nБерём: ${anime.title}');

    final episodes = await catalog.episodes(anime.id);
    stdout.writeln('Серий: ${episodes.length} '
        '(${episodes.first}..${episodes.last})');

    final players = await catalog.players(anime.id, episodes.first);
    stdout.writeln('Плееры серии ${episodes.first}:');
    for (final option in players) {
      stdout.writeln('  • ${option.player.padRight(10)} ${option.label}');
    }

    var ok = 0;
    for (final option in players.take(4)) {
      stdout.writeln('\n--- ${option.player} / ${option.label}');
      try {
        final result = await catalog.resolve(option);
        ok++;
        stdout.writeln('    качества: ${result.qualities}');
        if (result.skipSegments.isNotEmpty) {
          stdout.writeln('    таймкоды: ${result.skipSegments.map(
                (segment) => '${segment.kind} ${segment.start}-${segment.end}',
              ).join(', ')}');
        }
        final best = result.best();
        stdout.writeln('    лучшая:   $best');
        stdout.writeln('    заголовки: ${best.headers}');
        final downloadable = result.streams.where((s) => s.isDownloadable).toList();
        stdout.writeln('    скачиваемых дорожек: ${downloadable.length}');
        await _checkPlayable(catalog, best);
      } on AnimeError catch (error) {
        stdout.writeln('    ошибка: $error');
      }
    }

    stdout.writeln('\nПлееров отдали видео: $ok из ${players.take(4).length}');
    exitCode = ok > 0 ? 0 : 1;
  } on AnimeError catch (error) {
    stderr.writeln('Не получилось: $error');
    exitCode = 1;
  } finally {
    catalog.close();
  }
}

/// Дёргает первые байты дорожки: CDN либо отдаёт их с нашими заголовками, либо нет.
Future<void> _checkPlayable(Catalog catalog, VideoStream stream) async {
  try {
    final response = await catalog.client.openStream(stream.url, headers: stream.headers);
    await response.stream.take(1).drain<void>();
    stdout.writeln('    CDN отдаёт: HTTP ${response.status}');
  } on AnimeError catch (error) {
    stdout.writeln('    CDN отказал: $error');
  }
}

String? _flag(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
