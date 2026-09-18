/// HTTP-клиент порта: один Dio на всё приложение, единый User-Agent и прокси.
///
/// Плееры отдают ссылки, которые CDN не отдаёт без `Referer`, поэтому заголовки
/// здесь — не украшение: они едут и в парсинг, и дальше в плеер со скачиванием.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'errors.dart';

const String defaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// Ответ в том виде, в каком его ждут парсеры.
class HttpResponse {
  HttpResponse({
    required this.status,
    required this.text,
    required this.url,
    required this.headers,
    this.data,
  });

  final int status;
  final String text;
  final String url;
  final Map<String, String> headers;

  /// Разобранный json, когда сервер его прислал.
  final Object? data;

  bool get ok => status >= 200 && status < 400;

  HttpResponse raiseForStatus() {
    if (!ok) {
      throw ServiceError('Сервер ответил $status ($url)', status: status, url: url);
    }
    return this;
  }

  /// Тело как json-объект. Бросает, если это не json.
  Map<String, dynamic> jsonMap() {
    final value = data ?? _decodeOrNull(text);
    if (value is Map<String, dynamic>) return value;
    throw ExtractionError('Ответ $url — не json-объект');
  }

  List<dynamic> jsonList() {
    final value = data ?? _decodeOrNull(text);
    if (value is List) return value;
    throw ExtractionError('Ответ $url — не json-массив');
  }
}

Object? _decodeOrNull(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

/// Тонкая обёртка над Dio: таймауты, прокси, общий User-Agent.
class AnimeHttpClient {
  AnimeHttpClient({
    Duration timeout = const Duration(seconds: 25),
    this.userAgent = defaultUserAgent,
    Map<String, String>? headers,
    HttpClientAdapter? adapter,
    this.proxy,
  }) {
    _dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        followRedirects: true,
        maxRedirects: 5,
        // статус разбираем сами: 403 от плеера — это не повод падать исключением
        validateStatus: (_) => true,
        responseType: ResponseType.plain,
        headers: {
          'User-Agent': userAgent,
          'Accept-Language': 'ru-RU,ru;q=0.9,en;q=0.8',
          ...?headers,
        },
      ),
    );
    if (adapter != null) {
      // в тестах сюда подставляется заглушка с сохранёнными ответами плееров
      _dio.httpClientAdapter = adapter;
    } else {
      _applyProxy();
    }
  }

  late final Dio _dio;
  final String userAgent;

  /// HTTP-прокси вида `host:port`, если он задан в настройках.
  final String? proxy;

  void _applyProxy() {
    final value = proxy;
    if (value == null || value.trim().isEmpty) return;
    final normalized = value.trim().replaceFirst(RegExp(r'^https?://'), '');
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (_) => 'PROXY $normalized';
        // у домашних прокси сертификат обычно самоподписанный
        client.badCertificateCallback = (_, _, _) => true;
        return client;
      },
    );
  }

  Future<HttpResponse> get(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? params,
  }) {
    return _request('GET', url, headers: headers, params: params);
  }

  /// POST формой (`application/x-www-form-urlencoded`) — так ходит Kodik.
  Future<HttpResponse> postForm(
    String url, {
    required Map<String, String> data,
    Map<String, String>? headers,
  }) {
    return _request('POST', url, headers: headers, formData: data);
  }

  /// Адрес, куда ведёт редирект (или сам url, если редиректа нет).
  Future<String> resolveRedirect(String url, {Map<String, String>? headers}) async {
    try {
      final response = await _dio.request<ResponseBody>(
        url,
        options: Options(
          method: 'GET',
          headers: headers,
          followRedirects: false,
          validateStatus: (_) => true,
          responseType: ResponseType.stream,
        ),
      );
      await response.data?.stream.drain<void>();
      final location = response.headers.value('location');
      if (location == null || location.isEmpty) return url;
      if (location.startsWith('//')) return 'https:$location';
      if (location.startsWith('http')) return location;
      return Uri.parse(url).resolve(location).toString();
    } on DioException catch (error) {
      throw NetworkError('Не удалось проверить редирект $url: ${_reason(error)}');
    }
  }

  Future<Uint8List> getBytes(String url, {Map<String, String>? headers}) async {
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 400) {
        throw ServiceError(
          'Скачивание не удалось: сервер ответил $status',
          status: status,
          url: url,
        );
      }
      return Uint8List.fromList(response.data ?? const <int>[]);
    } on DioException catch (error) {
      throw NetworkError('Сеть недоступна ($url): ${_reason(error)}');
    }
  }

  /// Поток байтов для больших файлов (скачивание серии).
  ///
  /// [rangeFrom] докачивает файл с указанного байта — сервер, который `Range`
  /// не понимает, ответит 200 и полным телом, это отслеживает вызывающий код.
  Future<StreamedResponse> openStream(
    String url, {
    Map<String, String>? headers,
    int? rangeFrom,
  }) async {
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          headers: {
            ...?headers,
            if (rangeFrom != null && rangeFrom > 0) 'Range': 'bytes=$rangeFrom-',
          },
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          // редиректы отрабатывает сам dio, но Range при этом сохраняется
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 400) {
        await response.data?.stream.drain<void>();
        throw ServiceError(
          'Скачивание не удалось: сервер ответил $status',
          status: status,
          url: url,
        );
      }
      final length = int.tryParse(response.headers.value('content-length') ?? '');
      return StreamedResponse(
        status: status,
        stream: response.data!.stream,
        contentLength: length,
        acceptsRange: status == 206,
      );
    } on DioException catch (error) {
      throw NetworkError('Сеть недоступна ($url): ${_reason(error)}');
    }
  }

  Future<HttpResponse> _request(
    String method,
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? params,
    Map<String, String>? formData,
  }) async {
    try {
      final response = await _dio.request<String>(
        url,
        queryParameters: params,
        data: formData == null ? null : _encodeForm(formData),
        options: Options(
          method: method,
          headers: headers,
          contentType: formData != null ? Headers.formUrlEncodedContentType : null,
        ),
      );
      final text = response.data ?? '';
      return HttpResponse(
        status: response.statusCode ?? 0,
        text: text,
        url: response.realUri.toString(),
        headers: _flatten(response.headers),
        data: _decodeOrNull(text),
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw NetworkError('Источник не ответил вовремя ($url)');
      }
      throw NetworkError('Сеть недоступна ($url): ${_reason(error)}');
    }
  }

  static String _encodeForm(Map<String, String> data) {
    return data.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  static Map<String, String> _flatten(Headers headers) {
    final result = <String, String>{};
    headers.forEach((key, values) {
      if (values.isNotEmpty) result[key.toLowerCase()] = values.first;
    });
    return result;
  }

  void close() => _dio.close(force: true);
}

/// У DioException сообщение бывает пустым — тогда берём причину и тип.
String _reason(DioException error) {
  final message = error.message;
  if (message != null && message.isNotEmpty) return message;
  final cause = error.error;
  if (cause != null) return '$cause';
  return switch (error.type) {
    DioExceptionType.connectionError => 'соединение не установилось',
    DioExceptionType.badCertificate => 'сертификат сервера не принят',
    DioExceptionType.cancel => 'запрос отменён',
    _ => error.type.name,
  };
}

/// Открытый поток ответа — то, чем качается серия.
class StreamedResponse {
  StreamedResponse({
    required this.status,
    required this.stream,
    required this.contentLength,
    required this.acceptsRange,
  });

  final int status;
  final Stream<Uint8List> stream;
  final int? contentLength;

  /// Сервер ответил 206 — докачка с середины сработала.
  final bool acceptsRange;
}
