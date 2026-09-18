/// Разбор плееров на сохранённых ответах — тех же, что в python-библиотеке.
///
/// Сеть не трогается: каждый запрос обслуживает заглушка из `fake_http.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:anipocket/anime/models.dart';
import 'package:anipocket/anime/players/anilibria.dart';
import 'package:anipocket/anime/players/animedia.dart';
import 'package:anipocket/anime/players/aniboom.dart';
import 'package:anipocket/anime/players/base.dart';
import 'package:anipocket/anime/players/cvh.dart';
import 'package:anipocket/anime/players/kodik.dart';
import 'package:anipocket/anime/players/sibnet.dart';
import 'package:anipocket/anime/players/vk.dart';
import 'package:anipocket/core/errors.dart';

import 'fake_http.dart';

const String aniboomEmbed =
    'https://aniboom.one/embed/9G1MJ6NMV8z?episode=1&translation=30';
const String kodikEmbed =
    'https://kodikplayer.com/seria/1304528/932d5da818729ec5ccc9be7968ee3717/720p';
const String sibnetEmbed = 'https://video.sibnet.ru/shell.php?videoid=2589828';
const String vkEmbed = 'https://vk.com/video_ext.php?oid=-33905270&id=456239024';

void main() {
  group('Aniboom', () {
    test('достаёт hls и dash из data-parameters', () async {
      final http = FakeHttp({'aniboom.one/embed': fixture('aniboom_embed.html')});
      final result = await AniboomPlayer(http.client)
          .extract(aniboomEmbed, const ExtractOptions(resolveQualities: false));

      expect(result.player, 'aniboom');
      expect(result.master(), isNotNull);
      expect(result.master()!.url, endsWith('master.m3u8'));
      expect(result.streams.where((s) => s.kind == StreamKind.dash).length, 1);
      expect(result.duration, 2971);
      expect(result.poster, startsWith('http'));
      expect(result.extra['max_quality'], 1080);
      // заголовки обязательны для скачивания
      expect(result.streams.first.headers['Referer'], 'https://aniboom.one/');
    });

    test('разворачивает master-плейлист в качества', () async {
      final http = FakeHttp({
        'aniboom.one/embed': fixture('aniboom_embed.html'),
        'master.m3u8': fixture('aniboom_master.m3u8'),
      });
      final result = await AniboomPlayer(http.client).extract(aniboomEmbed);

      expect(result.qualities, [360, 480, 720, 1080]);
      final best = result.best(kind: StreamKind.hls);
      expect(best.quality, 1080);
      expect(best.url, startsWith('https://'));
    });

    test('внятно жалуется на изменившуюся вёрстку', () async {
      final http = FakeHttp({'aniboom.one/embed': '<html><body>пусто</body></html>'});
      expect(
        () => AniboomPlayer(http.client).extract(aniboomEmbed),
        throwsA(isA<ExtractionError>()),
      );
    });

    test('собирает embed-ссылку', () {
      final url = AniboomPlayer.embedUrl('QK8d1LbNX6l', episode: 3, translation: 30);
      expect(url, 'https://aniboom.one/embed/QK8d1LbNX6l?episode=3&translation=30');
      expect(AniboomPlayer.videoId(url), 'QK8d1LbNX6l');
    });
  });

  group('CVH', () {
    Map<String, Object> routes() => {
          '/playlist': fixture('cvh_playlist.json'),
          '/video/': fixture('cvh_video.json'),
        };

    test('плейлист и дорожки', () async {
      final http = FakeHttp(routes());
      final player = CvhPlayer(http.client);
      final episodes = await player.playlist('51019');

      expect(episodes, isNotEmpty);
      expect(episodes.first.season, 1);
      expect(episodes.every((episode) => episode.videoId.isNotEmpty), isTrue);

      final result = await player
          .extract('https://animego.me/cdn-iframe/51019/AniDub%20Online/1/1');
      expect(result.player, 'cvh');
      expect(result.qualities, isNotEmpty);
      expect(result.master()!.kind, StreamKind.hls);
      expect(result.duration, 2966);
      expect(result.translation, 'AniDub Online');
    });

    test('разбирает iframe-ссылку', () {
      final parsed = CvhPlayer.parseUrl('https://animego.me/cdn-iframe/40748/Jam Club/2/13');
      expect(parsed['cvh_id'], '40748');
      expect(parsed['studio'], 'Jam Club');
      expect(parsed['season'], 2);
      expect(parsed['episode'], 13);
      expect(CvhPlayer.parseUrl('51019')['cvh_id'], '51019');
    });

    test('озвучка подбирается нестрого', () async {
      final http = FakeHttp(routes());
      final episodes = await CvhPlayer(http.client).playlist('51019');
      final studio = episodes.map((e) => e.studio).whereType<String>().first;

      expect(
        CvhPlayer.select(episodes, episode: 1, studio: studio.split(' ').first),
        isNotNull,
      );
      expect(
        () => CvhPlayer.select(episodes, episode: 1, studio: 'такой озвучки нет'),
        throwsA(isA<NotFoundError>()),
      );
    });

    test('серии нет — понятная ошибка', () async {
      final http = FakeHttp({'/playlist': fixture('cvh_playlist.json')});
      expect(
        () => CvhPlayer(http.client).extract('51019', const ExtractOptions(episode: 9999)),
        throwsA(isA<NotFoundError>()),
      );
    });
  });

  group('Kodik', () {
    Map<String, Object> routes() => {
          'kodikplayer.com/seria': fixture('kodik_embed.html'),
          '/assets/js/': fixture('kodik_player_script.js'),
          '/ftor': fixture('kodik_ftor.json'),
        };

    test('полный путь: страница, скрипт, расшифровка ссылок', () async {
      final http = FakeHttp(routes());
      final result = await KodikPlayer(http.client).extract(kodikEmbed);

      expect(result.player, 'kodik');
      expect(result.qualities, [360, 480, 720]);
      for (final stream in result.streams) {
        expect(stream.url, startsWith('https://'));
      }
      expect(result.best(kind: StreamKind.mp4).url, endsWith('720.mp4'));
      expect(result.best(kind: StreamKind.hls).url, endsWith(':hls:manifest.m3u8'));
      expect(result.translation, '2x2');
      expect(
        result.skipSegments.map((s) => [s.start, s.end, s.kind]).toList(),
        [
          [30, 110, 'opening'],
          [1375, 1445, 'ending'],
        ],
      );
    });

    test('ref уходит раскодированным — иначе сервер отвечает 500', () async {
      final http = FakeHttp(routes());
      await KodikPlayer(http.client).extract(kodikEmbed);

      final post = http.lastCall('POST')!;
      expect(post.url, endsWith('/ftor'));
      expect(post.form['ref'], 'https://animego.org/');
      expect(post.form['ref_sign'], isNotEmpty);
      expect(post.form['type'], 'seria');
      expect(post.form['hash'], isNotEmpty);
      expect(post.form['id'], isNotEmpty);
    });

    test('адрес эндпоинта берётся из кэша', () async {
      final http = FakeHttp(routes());
      final player = KodikPlayer(http.client);
      await player.extract(kodikEmbed);
      final first = http.calls.where((call) => call.url.contains('/assets/js/')).length;
      await player.extract(kodikEmbed);
      final second = http.calls.where((call) => call.url.contains('/assets/js/')).length;
      expect(second, first);
    });

    test('у /serial/ адрес эндпоинта ищется в app.serial.js', () async {
      // На страницах сериала app.player.js эндпоинта не несёт — он в app.serial.js,
      // поэтому скрипты перебираются, а не берётся первый попавшийся.
      final page = '${fixture('kodik_embed.html')}'
          '<script src="/assets/js/app.serial.deadbeef.js"></script>';
      final http = FakeHttp({
        'kodikplayer.com/serial': page,
        '/assets/js/app.player': 'var x = 1; // никакого atob тут нет',
        '/assets/js/app.serial': fixture('kodik_player_script.js'),
        '/ftor': fixture('kodik_ftor.json'),
      });

      final result = await KodikPlayer(http.client).extract(
        'https://kodikplayer.com/serial/3566/0bbd4431145327c55826f8a11f81b807/720p',
        const ExtractOptions(episode: 1),
      );

      expect(result.qualities, [360, 480, 720]);
      expect(http.lastCall('POST')!.url, endsWith('/ftor'));
    });

    test('ошибка сервиса при 500', () async {
      final http = FakeHttp({
        'kodikplayer.com/seria': fixture('kodik_embed.html'),
        '/assets/js/': fixture('kodik_player_script.js'),
        '/ftor': const FakeRoute('<html>Error</html>', status: 500),
      });
      expect(
        () => KodikPlayer(http.client).extract(kodikEmbed),
        throwsA(isA<ServiceError>()),
      );
    });
  });

  group('Sibnet', () {
    test('прямая mp4-ссылка с Referer', () async {
      final http = FakeHttp({'sibnet.ru/shell.php': fixture('sibnet_shell.html')});
      final result = await SibnetPlayer(http.client).extract(sibnetEmbed);

      final stream = result.best();
      expect(stream.kind, StreamKind.mp4);
      expect(stream.url, startsWith('https://video.sibnet.ru/v/'));
      expect(stream.headers['Referer'], 'https://video.sibnet.ru/');
      expect(result.title, isNotNull);
    });

    test('идёт по редиректу на CDN', () async {
      final http = FakeHttp({
        'sibnet.ru/shell.php': fixture('sibnet_shell.html'),
        'video.sibnet.ru/v/': const FakeRoute(
          '',
          status: 302,
          headers: {'Location': 'https://dv97.sibnet.ru/25/89/82/x.mp4'},
        ),
      });
      final result = await SibnetPlayer(http.client)
          .extract('2589828', const ExtractOptions(resolveRedirect: true));

      final stream = result.best();
      expect(stream.url, 'https://dv97.sibnet.ru/25/89/82/x.mp4');
      expect(stream.extra['original_url'], startsWith('https://video.sibnet.ru/v/'));
    });

    test('видео удалено', () async {
      final http = FakeHttp({'sibnet.ru/shell.php': '<html>видео удалено</html>'});
      expect(
        () => SibnetPlayer(http.client).extract(sibnetEmbed),
        throwsA(isA<NoStreamsFoundError>()),
      );
    });
  });

  group('AniLibria', () {
    test('серия с таймкодами', () async {
      final http = FakeHttp({'/anime/releases/': fixture('anilibria_release.json')});
      final result = await AnilibriaPlayer(http.client)
          .extract('bleach', const ExtractOptions(episode: 1));

      expect(result.qualities, [480, 720, 1080]);
      expect(result.title, startsWith('Блич'));
      expect(result.skipSegments.first.kind, 'opening');
      expect(result.extra['alias'], 'bleach');
    });

    test('номер серии берётся из ссылки', () async {
      final http = FakeHttp({'/anime/releases/': fixture('anilibria_release.json')});
      final result = await AnilibriaPlayer(http.client)
          .extract('https://anilibria.top/anime/releases/release/bleach/episodes/2');
      expect(result.extra['ordinal'], 2);
    });

    test('нет такой серии', () async {
      final http = FakeHttp({'/anime/releases/': fixture('anilibria_release.json')});
      expect(
        () => AnilibriaPlayer(http.client)
            .extract('bleach', const ExtractOptions(episode: 999)),
        throwsA(isA<NotFoundError>()),
      );
    });
  });

  group('VK Video', () {
    Map<String, Object> routes() => {
          'video_ext.php': fixture('vk_video_ext.html'),
          'okcdn.ru': fixture('vk_master.m3u8'),
        };

    test('разбирает apiPrefetchCache', () async {
      final http = FakeHttp(routes());
      final result = await VkPlayer(http.client)
          .extract(vkEmbed, const ExtractOptions(resolveQualities: false));

      expect(result.player, 'vk');
      expect(result.qualities, [144, 240, 360, 480, 720]);
      expect(result.duration, 1440);
      expect(result.title, contains('Гримгар'));
      expect(result.poster, startsWith('http'));
      expect(result.master(), isNotNull);
      expect(result.filter(kind: StreamKind.dash), isNotEmpty);
      expect(result.best(kind: StreamKind.mp4).quality, 720);
      expect(result.streams.first.headers['Referer'], 'https://vk.com/');
    });

    test('разворачивает master-плейлист', () async {
      final http = FakeHttp(routes());
      final result = await VkPlayer(http.client).extract(vkEmbed);

      final hls = result
          .filter(kind: StreamKind.hls)
          .map((stream) => stream.quality)
          .whereType<int>()
          .toList();
      expect(hls, isNotEmpty);
      expect(hls.reduce((a, b) => a > b ? a : b), greaterThanOrEqualTo(480));
    });

    test('поддерживает старый playerParams', () async {
      const page = '<html><script>var playerParams = {"params":[{'
          '"url240":"https://vk.com/240.mp4",'
          '"url720":"https://vk.com/720.mp4",'
          '"hls":"https://vk.com/index.m3u8",'
          '"dash_sep":"https://vk.com/index.mpd",'
          '"duration":1420,"md_title":"Серия 1"}]};</script></html>';
      final http = FakeHttp({'video_ext.php': page});
      final result = await VkPlayer(http.client).extract(
        'https://vk.com/video_ext.php?oid=-1&id=2',
        const ExtractOptions(resolveQualities: false),
      );

      expect(result.qualities, [240, 720]);
      expect(result.master()!.url, endsWith('.m3u8'));
      expect(result.filter(kind: StreamKind.dash), isNotEmpty);
      expect(result.title, 'Серия 1');
      expect(result.duration, 1420);
    });

    test('недоступное видео', () async {
      final http = FakeHttp({'video_ext.php': fixture('vk_unavailable.html')});
      expect(
        () => VkPlayer(http.client).extract('https://vk.com/video_ext.php?oid=-1&id=1'),
        throwsA(isA<ContentBlockedError>()),
      );
    });

    test('понимает любые формы ссылки', () {
      expect(VkPlayer.videoIds('-33905270_456239024').$1, '-33905270');
      expect(VkPlayer.videoIds('https://vkvideo.ru/video-33905270_456239024').$2,
          '456239024');
    });
  });

  group('Animedia', () {
    test('достаёт file из Playerjs', () async {
      final http = FakeHttp({'aser.pro/vod/': fixture('animedia_vod.html')});
      final result = await AnimediaPlayer(http.client)
          .extract('https://aser.pro/vod/20182', const ExtractOptions(resolveQualities: false));

      expect(result.player, 'animedia');
      expect(result.streams, isNotEmpty);
      expect(result.streams.first.headers['Referer'], 'https://aser.pro/');
    });
  });
}
