/// Иерархия ошибок порта `anime-dl-core`.
///
/// Каждая ошибка несёт текст, который не стыдно показать пользователю:
/// экраны печатают `error.toString()` без дополнительной обработки.
library;

class AnimeError implements Exception {
  const AnimeError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Ссылка не подошла ни одному плееру.
class UnsupportedUrlError extends AnimeError {
  const UnsupportedUrlError(super.message);
}

/// Таймаут, обрыв соединения, недоступный прокси.
class NetworkError extends AnimeError {
  const NetworkError(super.message);
}

/// Сервер ответил чем-то неожиданным.
class ServiceError extends AnimeError {
  const ServiceError(super.message, {this.status, this.url});

  final int? status;
  final String? url;
}

/// Ответ пришёл, но разобрать его не удалось — плеер сменил вёрстку.
class ExtractionError extends AnimeError {
  const ExtractionError(super.message);
}

/// Страница разобралась, но ссылок на видео в ней нет.
class NoStreamsFoundError extends AnimeError {
  const NoStreamsFoundError(super.message);
}

/// Ссылку Kodik не удалось расшифровать.
class DecryptionError extends AnimeError {
  const DecryptionError(super.message);
}

/// Гео-блокировка, возрастное ограничение, правообладатель.
class ContentBlockedError extends AnimeError {
  const ContentBlockedError(super.message);
}

/// Нет такой серии / озвучки / релиза.
class NotFoundError extends AnimeError {
  const NotFoundError(super.message);
}
