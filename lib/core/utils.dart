/// Разбор html/js, m3u8 и дешифровка ссылок Kodik.
///
/// Порт `anime_dl_core/utils.py`: плееры парсятся регулярками, поэтому никаких
/// html-библиотек здесь нет и не нужно.
library;

import 'dart:convert';

import 'package:html_unescape/html_unescape.dart';

import 'errors.dart';

final HtmlUnescape _unescape = HtmlUnescape();

/// `&quot;` и прочие сущности — в обычный текст.
String unescapeHtml(String value) => _unescape.convert(value);

/// `RegExp.firstMatch` плюс понятная ошибка, когда ничего не нашлось.
String searchGroup(
  RegExp pattern,
  String text, {
  int group = 1,
  String what = 'нужный фрагмент',
  String? orElse,
  bool required = true,
}) {
  final match = pattern.firstMatch(text);
  final value = match?.group(group);
  if (value == null) {
    if (!required || orElse != null) return orElse ?? '';
    throw ExtractionError(
      'Не удалось найти $what — плеер, скорее всего, сменил вёрстку.',
    );
  }
  return value;
}

/// То же самое, но без исключения: `null`, когда не нашлось.
String? searchOrNull(RegExp pattern, String text, {int group = 1}) {
  return pattern.firstMatch(text)?.group(group);
}

/// json из html-атрибута (с `&quot;` внутри).
Map<String, dynamic> jsonFromAttribute(String value) {
  try {
    final decoded = jsonDecode(unescapeHtml(value));
    if (decoded is Map<String, dynamic>) return decoded;
    throw const ExtractionError('json в атрибуте страницы — не объект');
  } on FormatException catch (error) {
    throw ExtractionError('Не разобрать json из атрибута страницы: ${error.message}');
  }
}

/// Один вариант качества из master-плейлиста HLS.
class HlsVariant {
  HlsVariant({
    required this.url,
    this.height,
    this.width,
    this.bandwidth,
    this.codecs,
    this.audioUrl,
  });

  final String url;
  final int? height;
  final int? width;
  final int? bandwidth;
  final String? codecs;

  /// Отдельная звуковая дорожка (`#EXT-X-MEDIA:TYPE=AUDIO`), если видео без звука.
  final String? audioUrl;
}

final RegExp _streamInf = RegExp(
  r'#EXT-X-STREAM-INF:([^\n]+)\n\s*([^\s#][^\n]*)',
);
final RegExp _mediaAudio = RegExp(
  r'#EXT-X-MEDIA:([^\n]*TYPE=AUDIO[^\n]*)',
  caseSensitive: false,
);

/// Разбирает master-плейлист HLS на варианты качества (от низкого к высокому).
///
/// fMP4-плейлисты (Aniboom) держат звук отдельной дорожкой, поэтому у варианта
/// появляется [HlsVariant.audioUrl] — без неё скачанное видео будет немым.
List<HlsVariant> parseMasterPlaylist(String content, String baseUrl) {
  final audioGroups = <String, String>{};
  for (final match in _mediaAudio.allMatches(content)) {
    final attrs = match.group(1) ?? '';
    final group = searchOrNull(RegExp(r'GROUP-ID="([^"]+)"'), attrs);
    final uri = searchOrNull(RegExp(r'URI="([^"]+)"'), attrs);
    if (group == null || uri == null) continue;
    final isDefault = RegExp('DEFAULT=YES', caseSensitive: false).hasMatch(attrs);
    if (!audioGroups.containsKey(group) || isDefault) {
      audioGroups[group] = absoluteUrl(baseUrl, uri.trim());
    }
  }

  final variants = <HlsVariant>[];
  for (final match in _streamInf.allMatches(content)) {
    final attrs = match.group(1) ?? '';
    final uri = (match.group(2) ?? '').trim();
    if (uri.isEmpty) continue;
    final audioGroup = searchOrNull(RegExp(r'AUDIO="([^"]+)"'), attrs);
    final resolution = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(attrs);
    variants.add(
      HlsVariant(
        url: absoluteUrl(baseUrl, uri),
        width: resolution == null ? null : int.tryParse(resolution.group(1)!),
        height: resolution == null ? null : int.tryParse(resolution.group(2)!),
        bandwidth: int.tryParse(
          searchOrNull(RegExp(r'[^-]BANDWIDTH=(\d+)'), ' $attrs') ?? '',
        ),
        codecs: searchOrNull(RegExp(r'CODECS="([^"]+)"'), attrs),
        audioUrl: audioGroup == null ? null : audioGroups[audioGroup],
      ),
    );
  }
  variants.sort((a, b) {
    final byHeight = (a.height ?? 0).compareTo(b.height ?? 0);
    if (byHeight != 0) return byHeight;
    return (a.bandwidth ?? 0).compareTo(b.bandwidth ?? 0);
  });
  return variants;
}

/// Относительная ссылка -> абсолютная относительно [baseUrl].
String absoluteUrl(String baseUrl, String url) {
  if (url.startsWith('//')) {
    final scheme = Uri.tryParse(baseUrl)?.scheme;
    return '${scheme == null || scheme.isEmpty ? 'https' : scheme}:$url';
  }
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  return Uri.parse(baseUrl).resolve(url).toString();
}

/// `//host/path` -> `https://host/path`, остальное не трогаем.
String forceHttps(String url) => url.startsWith('//') ? 'https:$url' : url;

/// Значение GET-параметра из ссылки.
String? queryParam(String url, String key) {
  return Uri.tryParse(url)?.queryParameters[key];
}

const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// Шифр Цезаря по латинице с сохранением регистра.
String caesarShift(String text, int shift) {
  final buffer = StringBuffer();
  for (final char in text.split('')) {
    final index = _alphabet.indexOf(char.toUpperCase());
    if (index == -1) {
      buffer.write(char);
      continue;
    }
    final shifted = _alphabet[(index + shift) % 26];
    final isLower = char == char.toLowerCase() && char != char.toUpperCase();
    buffer.write(isLower ? shifted.toLowerCase() : shifted);
  }
  return buffer.toString();
}

String _b64Padded(String value) {
  final padded = value + '=' * ((4 - value.length % 4) % 4);
  return utf8.decode(base64.decode(padded));
}

/// Расшифрованная ссылка Kodik и сдвиг, которым она открылась.
class KodikLink {
  const KodikLink(this.url, this.shift);

  final String url;
  final int shift;
}

/// Kodik отдаёт ссылку как base64 со сдвигом Цезаря.
///
/// Сдвиг время от времени меняется, поэтому он перебирается (26 вариантов), а
/// сработавший переиспользуется через [knownShift].
KodikLink decodeKodikUrl(String value, {int? knownShift}) {
  final shifts = <int>[?knownShift, ...List.generate(26, (i) => i)];
  for (final shift in shifts) {
    String decoded;
    try {
      decoded = _b64Padded(caesarShift(value, shift));
    } catch (_) {
      // мусор на выходе означает просто «не тот сдвиг»
      continue;
    }
    if (decoded.startsWith('//') || decoded.startsWith('http')) {
      return KodikLink(decoded, shift);
    }
  }
  throw const DecryptionError(
    'Не удалось расшифровать ссылку Kodik — похоже, шифрование изменилось.',
  );
}

// Метки качества на этих сайтах пишут и латинской «p», и кириллической «р».
final RegExp _qualityRe = RegExp(r'(\d{3,4})\s*[pр]?', caseSensitive: false);

/// Достаёт число качества из метки вида `720p` / `1080` / `hd720`.
int? qualityFromLabel(String? label) {
  final match = _qualityRe.firstMatch(label ?? '');
  if (match == null) return null;
  final value = int.tryParse(match.group(1)!);
  if (value == null) return null;
  return value >= 100 && value <= 4320 ? value : null;
}

/// Плееры присылают числа то числами, то строками.
int? toInt(Object? value) {
  if (value == null || value is bool) return null;
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    return int.tryParse(trimmed) ?? double.tryParse(trimmed)?.toInt();
  }
  return null;
}

/// `"22:55"` / `"1:02:03"` -> секунды.
int? timecodeToSeconds(String value) {
  final parts = value.trim().split(':');
  if (parts.isEmpty) return null;
  var seconds = 0;
  for (final part in parts) {
    final number = int.tryParse(part.trim());
    if (number == null) return null;
    seconds = seconds * 60 + number;
  }
  return seconds;
}
