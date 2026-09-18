/// Настройки приложения. Хранятся в SharedPreferences, как и всё остальное —
/// локально.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../anime/catalog.dart';

class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SettingsStore> load() async {
    return SettingsStore(await SharedPreferences.getInstance());
  }

  /// Источник каталога: `animego` или `animedia`.
  String get source => _prefs.getString('source') ?? 'animego';

  /// Зеркало AnimeGO — помогает, когда основной домен закрыт Cloudflare.
  String get animegoMirror => _prefs.getString('animego_mirror') ?? '';

  String get animediaBaseUrl =>
      _prefs.getString('animedia_base_url') ?? 'https://amd.online';

  /// HTTP-прокси вида `http://host:port`.
  String get proxy => _prefs.getString('proxy') ?? '';

  int get timeoutSeconds => _prefs.getInt('timeout') ?? 25;

  /// Потолок качества: выше него дорожки не запрашиваются.
  int get maxQuality => _prefs.getInt('max_quality') ?? 1080;

  /// Доля серии, после которой она считается просмотренной.
  double get completedRatio => _prefs.getDouble('completed_ratio') ?? 0.85;

  /// Качество, которое предлагается для скачивания по умолчанию.
  int get downloadQuality => _prefs.getInt('download_quality') ?? 720;

  /// Скачивать только по Wi-Fi — проверка выполняется перед стартом задания.
  bool get wifiOnly => _prefs.getBool('wifi_only') ?? false;

  /// Автоматически предлагать пропуск опенинга.
  bool get autoSkipOpening => _prefs.getBool('auto_skip_opening') ?? false;

  ThemeMode get themeMode {
    return switch (_prefs.getString('theme')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  CatalogConfig get catalogConfig => CatalogConfig(
        source: source,
        animegoMirror: animegoMirror,
        animediaBaseUrl: animediaBaseUrl,
        proxy: proxy,
        timeoutSeconds: timeoutSeconds,
        maxQuality: maxQuality,
      );

  Future<void> setSource(String value) => _setString('source', value);

  Future<void> setAnimegoMirror(String value) => _setString('animego_mirror', value.trim());

  Future<void> setAnimediaBaseUrl(String value) =>
      _setString('animedia_base_url', value.trim());

  Future<void> setProxy(String value) => _setString('proxy', value.trim());

  Future<void> setTimeout(int value) => _setInt('timeout', value);

  Future<void> setMaxQuality(int value) => _setInt('max_quality', value);

  Future<void> setDownloadQuality(int value) => _setInt('download_quality', value);

  Future<void> setCompletedRatio(double value) async {
    await _prefs.setDouble('completed_ratio', value);
    notifyListeners();
  }

  Future<void> setWifiOnly(bool value) async {
    await _prefs.setBool('wifi_only', value);
    notifyListeners();
  }

  Future<void> setAutoSkipOpening(bool value) async {
    await _prefs.setBool('auto_skip_opening', value);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) {
    return _setString('theme', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  Future<void> _setString(String key, String value) async {
    await _prefs.setString(key, value);
    notifyListeners();
  }

  Future<void> _setInt(String key, int value) async {
    await _prefs.setInt(key, value);
    notifyListeners();
  }
}
