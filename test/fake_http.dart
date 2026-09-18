/// Заглушка сети для тестов: отвечает сохранёнными ответами плееров.
///
/// Маршруты ищутся по подстроке url — первый подошедший выигрывает, ровно как
/// в тестах исходной python-библиотеки.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:anipocket/core/http.dart';

/// Что вернуть на запрос.
class FakeRoute {
  const FakeRoute(this.body, {this.status = 200, this.headers = const {}});

  final String body;
  final int status;
  final Map<String, String> headers;
}

class RecordedCall {
  RecordedCall(this.method, this.url, this.body, this.headers);

  final String method;
  final String url;
  final String? body;
  final Map<String, dynamic> headers;

  /// Тело формы, разобранное в словарь.
  Map<String, String> get form {
    final result = <String, String>{};
    for (final pair in (body ?? '').split('&')) {
      if (pair.isEmpty) continue;
      final index = pair.indexOf('=');
      if (index < 0) continue;
      result[Uri.decodeQueryComponent(pair.substring(0, index))] =
          Uri.decodeQueryComponent(pair.substring(index + 1));
    }
    return result;
  }
}

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(Map<String, Object> routes)
      : routes = {
          for (final entry in routes.entries)
            entry.key: entry.value is FakeRoute
                ? entry.value as FakeRoute
                : FakeRoute('${entry.value}'),
        };

  final Map<String, FakeRoute> routes;
  final List<RecordedCall> calls = [];

  RecordedCall? lastCall(String method) {
    for (final call in calls.reversed) {
      if (call.method == method) return call;
    }
    return null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    calls.add(
      RecordedCall(
        options.method,
        url,
        options.data is String ? options.data as String : null,
        Map<String, dynamic>.from(options.headers),
      ),
    );

    for (final entry in routes.entries) {
      if (url.contains(entry.key)) {
        return ResponseBody.fromString(
          entry.value.body,
          entry.value.status,
          headers: {
            for (final header in entry.value.headers.entries)
              header.key.toLowerCase(): [header.value],
            Headers.contentTypeHeader: [
              entry.value.body.trimLeft().startsWith('{') ||
                      entry.value.body.trimLeft().startsWith('[')
                  ? 'application/json; charset=utf-8'
                  : 'text/html; charset=utf-8',
            ],
          },
        );
      }
    }
    return ResponseBody.fromString('not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

/// Клиент, который ходит в заглушку вместо сети, плюс сама заглушка.
class FakeHttp {
  FakeHttp(Map<String, Object> routes) : adapter = FakeAdapter(routes) {
    client = AnimeHttpClient(adapter: adapter);
  }

  final FakeAdapter adapter;
  late final AnimeHttpClient client;

  List<RecordedCall> get calls => adapter.calls;

  RecordedCall? lastCall(String method) => adapter.lastCall(method);
}

/// Содержимое файла из `test/fixtures`.
String fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();
