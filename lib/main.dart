/// Точка входа: поднимаем локальное хранилище, каталог и очередь загрузок.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'anime/catalog.dart';
import 'app.dart';
import 'data/database.dart';
import 'data/library_store.dart';
import 'data/settings_store.dart';
import 'services/download_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await SettingsStore.load();
  final database = await AppDatabase.open();
  final catalog = Catalog(settings.catalogConfig);

  final library = LibraryStore(database);
  await library.load();

  final downloads = DownloadManager(
    database: database,
    catalog: catalog,
    settings: settings,
  );
  await downloads.load();

  // настройки сети меняются редко, но каталог надо пересобирать вместе с ними
  settings.addListener(() {
    catalog.updateConfig(settings.catalogConfig);
    downloads.attachCatalog(catalog);
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: library),
        ChangeNotifierProvider.value(value: downloads),
        Provider<Catalog>.value(value: catalog),
      ],
      child: const MobileAnimeApp(),
    ),
  );
}
