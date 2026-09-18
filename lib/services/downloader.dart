/// Скачивание серии в один файл — без ffmpeg.
///
/// Два случая:
///
/// * **mp4** — обычная загрузка потоком с докачкой через `Range`;
/// * **HLS** — плейлист разбирается на сегменты, они скачиваются подряд и
///   дописываются в один файл. Склейка TS-сегментов даёт рабочий `.ts`, а для
///   fMP4 в начало попадает `#EXT-X-MAP` — тоже рабочий файл.
///
/// Чего порт намеренно не делает: не собирает видео, у которого звук лежит
/// отдельной дорожкой (это Aniboom). Такое без ремукса в один файл не сложить,
/// поэтому для скачивания выбирается другой плеер — см. `VideoStream.isDownloadable`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/http.dart';
import '../core/utils.dart';

/// Ход загрузки: и байты, и сегменты — что применимо.
class DownloadProgress {
  const DownloadProgress({
    required this.receivedBytes,
    this.totalBytes,
    this.segmentsDone = 0,
    this.segmentsTotal,
  });

  final int receivedBytes;
  final int? totalBytes;
  final int segmentsDone;
  final int? segmentsTotal;
}

/// Отмена и пауза — один и тот же механизм: загрузчик просто перестаёт писать.
class DownloadHandle {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class EpisodeDownloader {
  EpisodeDownloader(this._client);

  final AnimeHttpClient _client;

  /// Скачивает mp4 в [filePath], продолжая с того места, где остановились.
  Future<void> downloadFile({
    required String url,
    required Map<String, String> headers,
    required String filePath,
    required DownloadHandle handle,
    required void Function(DownloadProgress progress) onProgress,
  }) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);

    var received = await file.exists() ? await file.length() : 0;
    final response = await _client.openStream(
      url,
      headers: headers,
      rangeFrom: received > 0 ? received : null,
    );

    // сервер проигнорировал Range — начинаем файл заново
    final append = received > 0 && response.acceptsRange;
    if (!append) received = 0;

    final total = response.contentLength == null ? null : response.contentLength! + received;
    final sink = file.openWrite(mode: append ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in response.stream) {
        if (handle.isCancelled) break;
        sink.add(chunk);
        received += chunk.length;
        onProgress(DownloadProgress(receivedBytes: received, totalBytes: total));
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (handle.isCancelled) {
      throw const DownloadPaused();
    }
  }

  /// Скачивает HLS-плейлист сегмент за сегментом в один файл.
  ///
  /// [startSegment] позволяет продолжить с места, где остановились: файл при
  /// этом дописывается, а не перезаписывается.
  Future<void> downloadHls({
    required String url,
    required Map<String, String> headers,
    required String filePath,
    required DownloadHandle handle,
    required void Function(DownloadProgress progress) onProgress,
    int startSegment = 0,
  }) async {
    final playlist = await _client.get(url, headers: headers);
    playlist.raiseForStatus();
    var content = playlist.text;
    var playlistUrl = url;

    // отдали master — берём из него лучший вариант и качаем уже его
    if (content.contains('#EXT-X-STREAM-INF')) {
      final variants = parseMasterPlaylist(content, playlistUrl);
      if (variants.isEmpty) {
        throw const NoStreamsFoundError('В master-плейлисте нет ни одного варианта.');
      }
      final best = variants.last;
      if (best.audioUrl != null) {
        throw const NoStreamsFoundError(
          'У этой дорожки звук отдельным потоком — в один файл без перекодирования '
          'её не собрать. Выберите другую озвучку или плеер.',
        );
      }
      playlistUrl = best.url;
      final inner = await _client.get(playlistUrl, headers: headers);
      content = inner.raiseForStatus().text;
    }

    if (content.contains('#EXT-X-KEY') &&
        !RegExp(r'#EXT-X-KEY:\s*METHOD=NONE', caseSensitive: false).hasMatch(content)) {
      throw const NoStreamsFoundError(
        'Сегменты этой дорожки зашифрованы — скачать их в файл не получится. '
        'Попробуйте другую озвучку или плеер.',
      );
    }

    final segments = _segmentUrls(content, playlistUrl);
    if (segments.isEmpty) {
      throw const NoStreamsFoundError('В плейлисте нет сегментов.');
    }

    final file = File(filePath);
    await file.parent.create(recursive: true);
    final resume = startSegment > 0 && await file.exists();
    final sink = file.openWrite(mode: resume ? FileMode.append : FileMode.write);
    var received = resume ? await file.length() : 0;
    var done = resume ? startSegment : 0;

    try {
      for (var index = done; index < segments.length; index++) {
        if (handle.isCancelled) break;
        final bytes = await _fetchSegment(segments[index], headers);
        sink.add(bytes);
        received += bytes.length;
        done = index + 1;
        onProgress(
          DownloadProgress(
            receivedBytes: received,
            segmentsDone: done,
            segmentsTotal: segments.length,
          ),
        );
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (handle.isCancelled) {
      throw DownloadPaused(segmentsDone: done);
    }
  }

  /// Сегменты падают чаще обычных запросов — три попытки с паузой.
  Future<Uint8List> _fetchSegment(String url, Map<String, String> headers) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _client.getBytes(url, headers: headers);
      } on AnimeError catch (error) {
        lastError = error;
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
    throw lastError is AnimeError
        ? lastError
        : NetworkError('Не удалось скачать сегмент $url');
  }

  /// Ссылки сегментов плюс `#EXT-X-MAP` (инициализация fMP4) первым файлом.
  static List<String> _segmentUrls(String playlist, String baseUrl) {
    final urls = <String>[];
    final map = searchOrNull(RegExp(r'#EXT-X-MAP:[^\n]*URI="([^"]+)"'), playlist);
    if (map != null) urls.add(absoluteUrl(baseUrl, map));
    for (final line in playlist.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      urls.add(absoluteUrl(baseUrl, trimmed));
    }
    return urls;
  }
}

/// Загрузку поставили на паузу или отменили — не ошибка, а состояние.
class DownloadPaused implements Exception {
  const DownloadPaused({this.segmentsDone = 0});

  final int segmentsDone;

  @override
  String toString() => 'Загрузка остановлена';
}
