/// Загрузчик серий: mp4 с докачкой и склейка HLS-сегментов.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anipocket/core/errors.dart';
import 'package:anipocket/services/downloader.dart';

import 'fake_http.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('anipocket_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  String path(String name) => '${temp.path}${Platform.pathSeparator}$name';

  group('mp4', () {
    test('скачивается целиком и сообщает прогресс', () async {
      final http = FakeHttp({'/video.mp4': 'СЕРИЯ-ЦЕЛИКОМ'});
      final file = path('ep1.mp4');
      final progress = <int>[];

      await EpisodeDownloader(http.client).downloadFile(
        url: 'https://cdn.example/video.mp4',
        headers: const {'Referer': 'https://player/'},
        filePath: file,
        handle: DownloadHandle(),
        onProgress: (value) => progress.add(value.receivedBytes),
      );

      expect(File(file).readAsStringSync(), 'СЕРИЯ-ЦЕЛИКОМ');
      expect(progress, isNotEmpty);
      expect(progress.last, File(file).lengthSync());
      // заголовки CDN обязательны — проверяем, что они уехали
      expect(http.calls.last.headers['Referer'], 'https://player/');
    });

    test('докачивает с середины, когда сервер понимает Range', () async {
      final file = File(path('ep2.mp4'))..writeAsStringSync('НАЧАЛО');
      final http = FakeHttp({
        '/video.mp4': const FakeRoute('-ХВОСТ', status: 206),
      });

      await EpisodeDownloader(http.client).downloadFile(
        url: 'https://cdn.example/video.mp4',
        headers: const {},
        filePath: file.path,
        handle: DownloadHandle(),
        onProgress: (_) {},
      );

      expect(file.readAsStringSync(), 'НАЧАЛО-ХВОСТ');
      expect(http.calls.last.headers['Range'], startsWith('bytes='));
    });

    test('сервер без Range — файл пишется заново', () async {
      final file = File(path('ep3.mp4'))..writeAsStringSync('ОГРЫЗОК');
      final http = FakeHttp({'/video.mp4': 'ПОЛНАЯ-СЕРИЯ'});

      await EpisodeDownloader(http.client).downloadFile(
        url: 'https://cdn.example/video.mp4',
        headers: const {},
        filePath: file.path,
        handle: DownloadHandle(),
        onProgress: (_) {},
      );

      expect(file.readAsStringSync(), 'ПОЛНАЯ-СЕРИЯ');
    });

    test('пауза останавливает загрузку', () async {
      final http = FakeHttp({'/video.mp4': 'ДАННЫЕ'});
      final handle = DownloadHandle()..cancel();

      expect(
        () => EpisodeDownloader(http.client).downloadFile(
          url: 'https://cdn.example/video.mp4',
          headers: const {},
          filePath: path('ep4.mp4'),
          handle: handle,
          onProgress: (_) {},
        ),
        throwsA(isA<DownloadPaused>()),
      );
    });
  });

  group('HLS', () {
    const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
seg1.ts
#EXTINF:10.0,
seg2.ts
#EXT-X-ENDLIST
''';

    test('сегменты склеиваются в один файл', () async {
      final http = FakeHttp({
        'index.m3u8': media,
        'seg1.ts': 'ПЕРВЫЙ|',
        'seg2.ts': 'ВТОРОЙ',
      });
      final file = path('ep5.ts');
      DownloadProgress? last;

      await EpisodeDownloader(http.client).downloadHls(
        url: 'https://cdn.example/hls/index.m3u8',
        headers: const {},
        filePath: file,
        handle: DownloadHandle(),
        onProgress: (value) => last = value,
      );

      expect(File(file).readAsStringSync(), 'ПЕРВЫЙ|ВТОРОЙ');
      expect(last?.segmentsDone, 2);
      expect(last?.segmentsTotal, 2);
    });

    test('из master-плейлиста берётся лучшее качество', () async {
      const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080
1080/index.m3u8
''';
      final http = FakeHttp({
        'master.m3u8': master,
        '1080/index.m3u8': media,
        'seg1.ts': 'A',
        'seg2.ts': 'B',
      });
      final file = path('ep6.ts');

      await EpisodeDownloader(http.client).downloadHls(
        url: 'https://cdn.example/hls/master.m3u8',
        headers: const {},
        filePath: file,
        handle: DownloadHandle(),
        onProgress: (_) {},
      );

      expect(File(file).readAsStringSync(), 'AB');
      expect(http.calls.any((call) => call.url.contains('1080/index.m3u8')), isTrue);
    });

    test('продолжает с сохранённого сегмента', () async {
      final file = File(path('ep7.ts'))..writeAsStringSync('ПЕРВЫЙ|');
      final http = FakeHttp({
        'index.m3u8': media,
        'seg1.ts': 'ПЕРВЫЙ|',
        'seg2.ts': 'ВТОРОЙ',
      });

      await EpisodeDownloader(http.client).downloadHls(
        url: 'https://cdn.example/hls/index.m3u8',
        headers: const {},
        filePath: file.path,
        handle: DownloadHandle(),
        onProgress: (_) {},
        startSegment: 1,
      );

      expect(file.readAsStringSync(), 'ПЕРВЫЙ|ВТОРОЙ');
      // первый сегмент повторно не качался
      expect(http.calls.any((call) => call.url.endsWith('seg1.ts')), isFalse);
    });

    test('инициализация fMP4 попадает в начало файла', () async {
      const fmp4 = '''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:10.0,
seg1.m4s
#EXT-X-ENDLIST
''';
      final http = FakeHttp({
        'index.m3u8': fmp4,
        'init.mp4': 'INIT',
        'seg1.m4s': 'DATA',
      });
      final file = path('ep8.mp4');

      await EpisodeDownloader(http.client).downloadHls(
        url: 'https://cdn.example/hls/index.m3u8',
        headers: const {},
        filePath: file,
        handle: DownloadHandle(),
        onProgress: (_) {},
      );

      expect(File(file).readAsStringSync(), 'INITDATA');
    });

    test('зашифрованные сегменты честно отклоняются', () async {
      const encrypted = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:10.0,
seg1.ts
#EXT-X-ENDLIST
''';
      final http = FakeHttp({'index.m3u8': encrypted});

      expect(
        () => EpisodeDownloader(http.client).downloadHls(
          url: 'https://cdn.example/hls/index.m3u8',
          headers: const {},
          filePath: path('ep9.ts'),
          handle: DownloadHandle(),
          onProgress: (_) {},
        ),
        throwsA(isA<NoStreamsFoundError>()),
      );
    });

    test('дорожка с отдельным звуком отклоняется с объяснением', () async {
      const master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="ru",DEFAULT=YES,URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,AUDIO="audio"
1080/index.m3u8
''';
      final http = FakeHttp({'master.m3u8': master});

      await expectLater(
        EpisodeDownloader(http.client).downloadHls(
          url: 'https://cdn.example/hls/master.m3u8',
          headers: const {},
          filePath: path('ep10.ts'),
          handle: DownloadHandle(),
          onProgress: (_) {},
        ),
        throwsA(
          isA<NoStreamsFoundError>().having(
            (error) => error.message,
            'сообщение',
            contains('другую озвучку'),
          ),
        ),
      );
    });
  });
}
