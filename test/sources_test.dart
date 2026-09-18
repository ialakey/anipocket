/// Источники каталога: AnimeGO и Animedia.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:anipocket/anime/sources/animedia_site.dart';
import 'package:anipocket/anime/sources/animego.dart';
import 'package:anipocket/core/errors.dart';

import 'fake_http.dart';

/// Ответ AnimeGO на запрос плеера: html завёрнут в json и экранирован.
String playerResponse(String html) => jsonEncode({
      'data': {'content': html},
    });

const String searchPage = '''
<div class="ani-grid">
  <div class="ani-grid__item some-class">
    <a title="Магическая битва" href="/anime/magicheskaya-bitva-1097"></a>
    <a href="/anime/magicheskaya-bitva-1097"></a>
    <img src="https://animego.org/poster.jpg">
    <div class="rating-badge rating-green">8.7</div>
    <div class="text-line-clamp">Jujutsu Kaisen</div>
  </div>
  <div class="ani-grid__item some-class">
    <a title="Наруто" href="/anime/naruto-70"></a>
    <a href="/anime/naruto-70"></a>
    <img src="https://animego.org/naruto.jpg">
  </div>
</div>
''';

const String playerHtml = '''
<div class="video-player">
  <button data-provider-title="AniBoom" data-translation-title="AniLibria"
          data-ptranslation="30"
          data-player="//aniboom.one/embed/9G1MJ6NMV8z?episode=1&amp;translation=30"></button>
  <button data-provider-title="Kodik" data-translation-title="2x2 (ошибка)"
          data-player="https://kodikplayer.com/seria/1304528/abc/720p"></button>
  <div data-episode="555001" data-episode-number="1"></div>
  <div data-episode="555002" data-episode-number="2"></div>
  <div data-episode="555003" data-episode-number="3"></div>
</div>
''';

void main() {
  group('AnimeGO', () {
    test('разбирает карточки поиска', () async {
      final http = FakeHttp({'/search/anime': searchPage});
      final items = await AnimeGoSource(http.client).search('битва');

      expect(items, hasLength(2));
      expect(items.first.id, 'magicheskaya-bitva-1097');
      expect(items.first.title, 'Магическая битва');
      expect(items.first.originalTitle, 'Jujutsu Kaisen');
      expect(items.first.rating, '8.7');
      expect(items.first.poster, 'https://animego.org/poster.jpg');
      expect(items.first.url, endsWith('/anime/magicheskaya-bitva-1097'));
    });

    test('пустая выдача — понятная ошибка', () async {
      final http = FakeHttp({'/search/anime': '<html>Ничего не найдено</html>'});
      expect(
        () => AnimeGoSource(http.client).search('абырвалг'),
        throwsA(isA<NotFoundError>()),
      );
    });

    test('Cloudflare распознаётся отдельно', () async {
      final http = FakeHttp({
        '/search/anime': const FakeRoute('<html>Just a moment...</html>', status: 403),
      });
      expect(
        () => AnimeGoSource(http.client).search('битва'),
        throwsA(isA<ServiceError>()),
      );
    });

    test('серии и плееры', () async {
      final http = FakeHttp({'/player/': playerResponse(playerHtml)});
      final source = AnimeGoSource(http.client);

      expect(await source.episodes('magicheskaya-bitva-1097'), [1, 2, 3]);

      final players = await source.players('magicheskaya-bitva-1097', 1);
      expect(players, hasLength(2));
      expect(players.first.player, 'AniBoom');
      expect(players.first.label, 'AniLibria');
      expect(players.first.embed, startsWith('https://aniboom.one/embed/'));
      // «&amp;» в атрибуте раскодирован, иначе плеер не поймёт параметры
      expect(players.first.embed, contains('&translation=30'));
      // пометку « (ошибка)» сайт дописывает сам — в названии озвучки её быть не должно
      expect(players[1].label, '2x2');
    });

    test('номер тайтла достаётся из идентификатора', () {
      expect(AnimeGoSource.animeNumber('naruto-uragannye-hroniki-103'), '103');
      expect(
        () => AnimeGoSource.animeNumber('без-номера'),
        throwsA(isA<NotFoundError>()),
      );
    });

    test('карточка тайтла: название, постер, описание', () async {
      const page = '''
        <html><head>
        <meta property="og:image" content="https://animego.org/cover.jpg">
        <meta property="og:description" content="Школьник глотает палец проклятия.">
        </head><body><h1>Магическая битва (2 сезон) смотреть онлайн</h1>
        <a href="/anime/genre/ekshen">Экшен</a>
        <a href="/anime/genre/fentezi">Фэнтези</a>
        </body></html>
      ''';
      final http = FakeHttp({'/anime/': page});
      final card = await AnimeGoSource(http.client).card('magicheskaya-bitva-1097');

      expect(card.title, 'Магическая битва');
      expect(card.poster, 'https://animego.org/cover.jpg');
      expect(card.description, 'Школьник глотает палец проклятия.');
      expect(card.genres, ['Экшен', 'Фэнтези']);
    });
  });

  group('Animedia', () {
    const titleUrl = 'https://amd.online/14-boruto-novoe-pokolenie-naruto.html';

    test('серии и карточка', () async {
      final http = FakeHttp({'amd.online/14-': fixture('animedia_title.html')});
      final source = AnimediaSource(http.client);
      final id = AnimediaSource.encodeId(titleUrl);

      expect(await source.episodes(id), [1, 2, 3, 4, 5]);

      final players = await source.players(id, 1);
      expect(players.first.embed, 'https://aser.pro/vod/1067');

      final card = await source.card(id);
      expect(card.title, startsWith('Боруто'));
      expect(card.poster, startsWith('https://'));
    });

    test('идентификатор — это упакованный адрес страницы', () {
      final id = AnimediaSource.encodeId(titleUrl);
      expect(AnimediaSource.decodeId(id), titleUrl);
      expect(id, isNot(contains('/')));
    });
  });
}
