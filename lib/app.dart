/// Оболочка приложения: четыре вкладки и общая тема.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/settings_store.dart';
import 'ui/downloads_screen.dart';
import 'ui/home_screen.dart';
import 'ui/library_screen.dart';
import 'ui/search_screen.dart';
import 'ui/theme.dart';

class MobileAnimeApp extends StatelessWidget {
  const MobileAnimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    return MaterialApp(
      title: 'AniPocket',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: settings.themeMode,
      home: const RootShell(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const List<Widget> _screens = [
    HomeScreen(),
    SearchScreen(),
    LibraryScreen(),
    DownloadsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Главная',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'Поиск',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmark_border),
            selectedIcon: Icon(Icons.bookmark),
            label: 'Мой список',
          ),
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: 'Загрузки',
          ),
        ],
      ),
    );
  }
}
