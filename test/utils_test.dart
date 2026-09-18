/// Мелочи, на которых держится разбор плееров.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_anime/anime/models.dart';
import 'package:mobile_anime/core/errors.dart';
import 'package:mobile_anime/core/utils.dart';

void main() {
  group('Шифр Цезаря и ссылки Kodik', () {
    test('сдвиг обратим и сохраняет регистр', () {
      expect(caesarShift('AbcZ!', 3), 'DefC!');
      expect(caesarShift(caesarShift('Hello, World', 13), 13), 'Hello, World');
    });

    test('ссылка расшифровывается перебором сдвига', () {
      const url = '//cloud.kodik.biz/video/720.mp4:hls:manifest.m3u8';
      // так же, как это делает сам Kodik: base64 + сдвиг
      final encoded = caesarShift(base64OfUtf8(url), 13);

      final decoded = decodeKodikUrl(encoded);
      expect(decoded.url, url);
      expect(decoded.shift, 13);
      // найденный сдвиг переиспользуется
      expect(decodeKodikUrl(encoded, knownShift: 13).url, url);
    });

    test('мусор не расшифровывается', () {
      expect(() => decodeKodikUrl('!!!!'), throwsA(isA<DecryptionError>()));
    });
  });

  group('master-плейлист HLS', () {
    const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="ru",DEFAULT=YES,URI="audio/ru.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e"
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,CODECS="avc1.640028",AUDIO="audio"
1080/index.m3u8
''';

    test('варианты сортируются по качеству и знают про отдельный звук', () {
      final variants = parseMasterPlaylist(playlist, 'https://cdn.example/hls/master.m3u8');

      expect(variants, hasLength(2));
      expect(variants.first.height, 360);
      expect(variants.first.audioUrl, isNull);
      expect(variants.last.height, 1080);
      expect(variants.last.bandwidth, 3000000);
      expect(variants.last.url, 'https://cdn.example/hls/1080/index.m3u8');
      expect(variants.last.audioUrl, 'https://cdn.example/hls/audio/ru.m3u8');
    });
  });

  test('качество достаётся и из кириллической метки', () {
    expect(qualityFromLabel('720p'), 720);
    expect(qualityFromLabel('1080р'), 1080); // кириллическая «р»
    expect(qualityFromLabel('mpegHighUrl'), isNull);
    expect(qualityFromLabel('hd720'), 720);
  });

  test('таймкоды переводятся в секунды', () {
    expect(timecodeToSeconds('0:30'), 30);
    expect(timecodeToSeconds('22:55'), 1375);
    expect(timecodeToSeconds('1:02:03'), 3723);
    expect(timecodeToSeconds('не время'), isNull);
  });

  test('относительные ссылки разворачиваются', () {
    expect(absoluteUrl('https://a.b/c/d.m3u8', 'seg1.ts'), 'https://a.b/c/seg1.ts');
    expect(absoluteUrl('https://a.b/c/d.m3u8', '/x.ts'), 'https://a.b/x.ts');
    expect(absoluteUrl('https://a.b/c/', '//cdn.x/y.ts'), 'https://cdn.x/y.ts');
    expect(forceHttps('//host/file.mp4'), 'https://host/file.mp4');
  });

  group('Выбор дорожки', () {
    VideoStream stream(StreamKind kind, int? quality, {String? audioUrl}) => VideoStream(
          url: 'https://cdn/${kind.value}-$quality',
          kind: kind,
          quality: quality,
          extra: audioUrl == null ? const {} : {'audio_url': audioUrl},
        );

    test('best берёт высшее качество, при равенстве — mp4', () {
      final result = PlayerResult(
        player: 'test',
        sourceUrl: 'x',
        streams: [
          stream(StreamKind.hls, null),
          stream(StreamKind.hls, 720),
          stream(StreamKind.mp4, 720),
          stream(StreamKind.mp4, 480),
        ],
      );

      expect(result.qualities, [480, 720]);
      expect(result.best().kind, StreamKind.mp4);
      expect(result.best().quality, 720);
      expect(result.best(maxQuality: 480).quality, 480);
      expect(result.master(), isNotNull);
    });

    test('дорожка с отдельным звуком не считается скачиваемой', () {
      expect(stream(StreamKind.mp4, 720).isDownloadable, isTrue);
      expect(stream(StreamKind.hls, 720).isDownloadable, isTrue);
      expect(stream(StreamKind.dash, 720).isDownloadable, isFalse);
      expect(
        stream(StreamKind.hls, 1080, audioUrl: 'https://cdn/audio.m3u8').isDownloadable,
        isFalse,
      );
    });

    test('пустой результат сообщает об этом', () {
      final empty = PlayerResult(player: 'test', sourceUrl: 'x');
      expect(empty.isEmpty, isTrue);
      expect(() => empty.best(), throwsA(isA<NoStreamsFoundError>()));
    });
  });
}

/// base64 от utf-8 строки — так же, как это делает Kodik перед сдвигом.
String base64OfUtf8(String value) => base64.encode(utf8.encode(value));
