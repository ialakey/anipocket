/// Главная: продолжить просмотр, что в списке, быстрый поиск.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/library_store.dart';
import '../data/models.dart';
import '../services/download_manager.dart';
import 'anime_screen.dart';
import 'player_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'widgets/common.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final downloads = context.watch<DownloadManager>();
    final watching = library.byStatus(WatchStatus.watching);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AniPocket'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Поиск',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Настройки',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (library.entries.isEmpty && downloads.tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: MessageView(
                icon: Icons.play_circle_outline,
                message: 'Ни регистрации, ни аккаунта.\n'
                    'Найдите аниме — и смотрите или скачивайте.',
              ),
            ),
          if (library.continueWatching.isNotEmpty) ...[
            const SectionTitle('Продолжить просмотр'),
            SizedBox(
              height: 210,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: library.continueWatching.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final item = library.continueWatching[index];
                  return SizedBox(
                    width: 120,
                    child: AnimeGridCard(
                      card: item.entry.toCard(),
                      subtitle: 'Серия ${item.progress.episode} · '
                          '${item.progress.percent}%',
                      progress: item.progress.percent / 100,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PlayerScreen(
                            card: item.entry.toCard(),
                            episode: item.progress.episode,
                            episodes: const [],
                            playerKey: item.progress.playerKey,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          if (watching.isNotEmpty) ...[
            const SectionTitle('Смотрю'),
            SizedBox(
              height: 210,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: watching.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final entry = watching[index];
                  return SizedBox(
                    width: 120,
                    child: AnimeGridCard(
                      card: entry.toCard(),
                      subtitle: entry.lastEpisode > 0
                          ? 'Просмотрено ${entry.lastEpisode}'
                          : null,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AnimeScreen(card: entry.toCard()),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          if (downloads.completed.isNotEmpty) ...[
            const SectionTitle('Скачано на телефон'),
            for (final task in downloads.completed.take(5))
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: PosterImage(url: task.posterUrl, width: 42, height: 60),
                ),
                title: Text(task.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${task.translation}${task.quality != null ? ' · ${task.quality}p' : ''}',
                ),
                trailing: const Icon(Icons.play_arrow),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PlayerScreen(
                      card: task.toCard(),
                      episode: task.episode,
                      episodes: [task.episode],
                      playerKey: task.playerKey,
                    ),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
