/// Плеер Kodik (kodikplayer.com, kodik.info).
///
/// Как он работает:
/// 1. Страница embed отдаёт `urlParams` — json с подписями (`d_sign`, `pd_sign`,
///    `ref_sign`), привязанными к домену и моменту времени, и `vInfo` с
///    id/hash/type видео.
/// 2. Скрипт плеера прячет адрес эндпоинта (`url:atob("L2Z0b3I=")` -> `/ftor`).
/// 3. POST с подписями возвращает ссылки по качествам, зашифрованные base64 со
///    сдвигом Цезаря — сдвиг перебирается.
///
/// Подписи одноразовые и живут недолго, поэтому загрузка страницы и POST идут
/// подряд, а ссылки нужно использовать сразу.
library;

import 'dart:convert';

import '../../core/errors.dart';
import '../../core/http.dart';
import '../../core/utils.dart';
import '../models.dart';
import 'base.dart';

final RegExp _urlParams = RegExp(r"urlParams\s*=\s*'(\{.*?\})'", dotAll: true);
final RegExp _urlParamsDq = RegExp(r'urlParams\s*=\s*"(\{.*?\})"', dotAll: true);
final RegExp _vInfo = RegExp(r"""\.(type|hash|id)\s*=\s*['"]([^'"]+)['"]""");
final RegExp _assetScript = RegExp(r"""["'](/assets/js/[^"']+\.js)["']""");
final RegExp _ajaxUrl = RegExp(r"""url:\s*atob\(["']([^"']+)["']\)""");
final RegExp _skipButton = RegExp(r"""parseSkipButton\(\s*["']([^"']*)["']""");
final RegExp _translationTitle = RegExp(r'translationTitle\s*=\s*"([^"]*)"');
final RegExp _translationId = RegExp(r'translationId\s*=\s*(\d+)');

const String _manifestSuffix = ':hls:manifest.m3u8';

class KodikPlayer extends BasePlayer {
  KodikPlayer(super.client);

  /// Путь до эндпоинта кэшируется: он один на весь скрипт плеера.
  final Map<String, String> _postPathCache = {};
  int? _shift;

  @override
  String get name => 'kodik';

  @override
  String get title => 'Kodik';

  @override
  List<RegExp> get urlPatterns =>
      [RegExp(r'kodik[a-z]*\.[a-z]+/(?:seria|serial|video|episode)/')];

  @override
  Map<String, String> get playbackHeaders => const {'Referer': 'https://kodikplayer.com/'};

  static const String defaultReferer = 'https://animego.org/';

  @override
  Future<PlayerResult> extract(
    String url, [
    ExtractOptions options = const ExtractOptions(),
  ]) async {
    final target = _normalize(url, options);
    final page = await client.get(
      target,
      headers: {'Referer': options.referer ?? defaultReferer},
    );
    page.raiseForStatus();
    final info = _parsePage(page.text, target);

    final postPath = await _findPostPath(target, info.scriptPaths);

    final answer = await client.postForm(
      _absolute(target, postPath),
      data: _postParams(info),
      headers: _postHeaders(target),
    );
    return _buildResult(answer, target, info, options.includeMp4);
  }

  /// Ищет адрес эндпоинта в скриптах страницы.
  ///
  /// У ссылок `/seria/...` он лежит в `app.player.*.js`, у `/serial/...` — в
  /// `app.serial.*.js`, поэтому скрипты перебираются, а сработавший запоминается.
  Future<String> _findPostPath(String pageUrl, List<String> scriptPaths) async {
    final candidates = [...scriptPaths]..sort((a, b) {
        return _scriptRank(b, pageUrl).compareTo(_scriptRank(a, pageUrl));
      });

    Object? lastError;
    for (final path in candidates) {
      final scriptUrl = _absolute(pageUrl, path);
      final cached = _postPathCache[scriptUrl];
      if (cached != null) return cached;
      try {
        final script = await client.get(scriptUrl, headers: {'Referer': pageUrl});
        final postPath = _parsePostPath(script.raiseForStatus().text, scriptUrl);
        _postPathCache[scriptUrl] = postPath;
        return postPath;
      } on AnimeError catch (error) {
        lastError = error;
      }
    }
    throw lastError is AnimeError
        ? lastError
        : ExtractionError('На странице Kodik не нашлось скрипта плеера: $pageUrl');
  }

  /// Скрипт, который скорее всего несёт эндпоинт для этой страницы, идёт первым.
  static int _scriptRank(String path, String pageUrl) {
    final isSerial = pageUrl.contains('/serial/');
    if (path.contains('app.serial')) return isSerial ? 3 : 1;
    if (path.contains('app.player')) return isSerial ? 2 : 3;
    return 0;
  }

  String _normalize(String url, ExtractOptions options) {
    var target = forceHttps(url.trim());
    if (!target.startsWith('http')) {
      target = 'https://${target.replaceFirst(RegExp(r'^/+'), '')}';
    }
    ensureMatches(target);
    if (options.season == null && options.episode == null) return target;
    final uri = Uri.parse(target);
    final query = Map<String, String>.from(uri.queryParameters);
    if (options.season != null) query['season'] = '${options.season}';
    if (options.episode != null) query['episode'] = '${options.episode}';
    return uri.replace(queryParameters: query).toString();
  }

  _KodikPageInfo _parsePage(String text, String url) {
    final raw = searchOrNull(_urlParams, text) ??
        searchGroup(_urlParamsDq, text, what: 'urlParams на странице Kodik');
    late final Map<String, dynamic> urlParams;
    try {
      urlParams = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException catch (error) {
      throw ExtractionError('urlParams Kodik не разбираются как json: ${error.message}');
    }

    final video = <String, String>{};
    for (final match in _vInfo.allMatches(text)) {
      video.putIfAbsent(match.group(1)!, () => match.group(2)!);
    }
    final missing = {'type', 'hash', 'id'}.difference(video.keys.toSet());
    if (missing.isNotEmpty) {
      throw ExtractionError(
        'На странице Kodik нет данных видео (${missing.join(', ')}): $url',
      );
    }

    final scriptPaths = _assetScript
        .allMatches(text)
        .map((match) => match.group(1)!)
        .toSet()
        .toList();
    if (scriptPaths.isEmpty) {
      throw ExtractionError('На странице Kodik нет скриптов плеера: $url');
    }

    return _KodikPageInfo(
      urlParams: urlParams,
      video: video,
      scriptPaths: scriptPaths,
      skip: _parseSkipButton(searchOrNull(_skipButton, text) ?? ''),
      translation: searchOrNull(_translationTitle, text),
      translationId: searchOrNull(_translationId, text),
    );
  }

  static String _parsePostPath(String script, String scriptUrl) {
    final encoded = searchOrNull(_ajaxUrl, script);
    if (encoded == null) {
      throw ExtractionError(
        'В скрипте плеера Kodik нет atob() с адресом эндпоинта: $scriptUrl',
      );
    }
    String path;
    try {
      path = utf8.decode(base64.decode(encoded));
    } catch (error) {
      throw ExtractionError('Адрес эндпоинта Kodik не декодируется из base64: $error');
    }
    if (!path.startsWith('/')) {
      throw ExtractionError('Адрес эндпоинта Kodik выглядит странно: $path');
    }
    return path;
  }

  static Map<String, String> _postParams(_KodikPageInfo info) {
    final params = info.urlParams;
    final missing =
        {'d', 'd_sign', 'pd', 'pd_sign', 'ref_sign'}.difference(params.keys.toSet());
    if (missing.isNotEmpty) {
      throw ExtractionError('В urlParams Kodik нет полей: ${missing.join(', ')}');
    }
    return {
      'hash': info.video['hash']!,
      'id': info.video['id']!,
      'type': info.video['type']!,
      'd': '${params['d']}',
      'd_sign': '${params['d_sign']}',
      'pd': '${params['pd']}',
      'pd_sign': '${params['pd_sign']}',
      // ref обязателен и должен быть раскодирован: с пустым сервер отвечает 500
      'ref': Uri.decodeComponent('${params['ref'] ?? ''}'),
      'ref_sign': '${params['ref_sign']}',
      'bad_user': 'true',
      'cdn_is_working': 'true',
    };
  }

  Map<String, String> _postHeaders(String url) {
    final uri = Uri.parse(url);
    return {
      'Referer': url,
      'Origin': '${uri.scheme}://${uri.host}',
      'X-Requested-With': 'XMLHttpRequest',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
    };
  }

  static String _absolute(String baseUrl, String path) {
    final uri = Uri.parse(baseUrl);
    return '${uri.scheme}://${uri.host}$path';
  }

  PlayerResult _buildResult(
    HttpResponse answer,
    String url,
    _KodikPageInfo info,
    bool includeMp4,
  ) {
    if (!answer.ok) {
      throw ServiceError(
        'Kodik ответил ${answer.status} на запрос ссылок — подписи протухли '
        'или IP заблокирован.',
        status: answer.status,
        url: answer.url,
      );
    }
    final data = answer.jsonMap();
    if (data['error'] != null) {
      throw ServiceError('Kodik вернул ошибку: ${data['error']}');
    }

    final links = data['links'];
    if (links is! Map || links.isEmpty) {
      throw NoStreamsFoundError('Kodik не вернул ссылок для $url');
    }

    final headers = buildHeaders();
    final streams = <VideoStream>[];
    final keys = links.keys.map((key) => '$key').toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));

    for (final qualityKey in keys) {
      final variants = links[qualityKey];
      if (variants is! List) continue;
      for (final variant in variants) {
        final src = variant is Map ? variant['src'] : null;
        if (src is! String || src.isEmpty) continue;
        final decoded = _decode(src);
        _shift = decoded.shift;
        final link = forceHttps(decoded.url);
        final quality = int.tryParse(qualityKey) ?? 0;
        streams.add(
          VideoStream(
            url: link,
            kind: StreamKind.hls,
            quality: quality,
            headers: headers,
            label: '${quality}p',
            extra: {'type': variant is Map ? variant['type'] : null},
          ),
        );
        if (includeMp4 && link.endsWith(_manifestSuffix)) {
          streams.add(
            VideoStream(
              url: link.substring(0, link.length - _manifestSuffix.length),
              kind: StreamKind.mp4,
              quality: quality,
              headers: headers,
              label: '${quality}p',
            ),
          );
        }
        break; // Kodik всегда отдаёт ровно одну запись на качество
      }
    }

    if (streams.isEmpty) {
      throw NoStreamsFoundError('Kodik вернул пустой список ссылок для $url');
    }

    final warnings = <String>[
      if (streams.any((stream) => stream.url.contains('/s/m/')))
        'Пришла прокси-ссылка (/s/m/) — Kodik, скорее всего, ограничил ваш IP.',
    ];

    return PlayerResult(
      player: name,
      sourceUrl: url,
      streams: streams,
      translation: info.translation,
      skipSegments: info.skip,
      extra: {
        'video_id': info.video['id'],
        'translation_id': info.translationId,
        'default_quality': data['default'],
        'caesar_shift': _shift,
        'warnings': warnings,
      },
    );
  }

  KodikLink _decode(String src) {
    if (src.contains(_manifestSuffix) || src.startsWith('http') || src.startsWith('//')) {
      return KodikLink(src, _shift ?? 0);
    }
    return decodeKodikUrl(src, knownShift: _shift);
  }
}

class _KodikPageInfo {
  _KodikPageInfo({
    required this.urlParams,
    required this.video,
    required this.scriptPaths,
    required this.skip,
    required this.translation,
    required this.translationId,
  });

  final Map<String, dynamic> urlParams;
  final Map<String, String> video;
  final List<String> scriptPaths;
  final List<SkipSegment> skip;
  final String? translation;
  final String? translationId;
}

/// `"0:30-1:50,22:55-24:05"` -> отрезки в секундах.
List<SkipSegment> _parseSkipButton(String value) {
  final segments = <SkipSegment>[];
  final chunks = value.split(',').where((chunk) => chunk.isNotEmpty);
  var index = 0;
  for (final chunk in chunks) {
    if (!chunk.contains('-')) continue;
    final parts = chunk.split('-');
    final start = timecodeToSeconds(parts.first);
    final end = timecodeToSeconds(parts.length > 1 ? parts[1] : '');
    if (start == null || end == null) continue;
    segments.add(SkipSegment(start, end, index == 0 ? 'opening' : 'ending'));
    index++;
  }
  return segments;
}
