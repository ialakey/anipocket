/// Мой список — локальный кабинет: статусы, оценки, прогресс.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/library_store.dart';
import '../data/models.dart';
import 'anime_screen.dart';
import 'widgets/common.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: WatchStatus.values.length + 1, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final counts = library.counts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Мой список'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: 'Все (${library.entries.length})'),
            for (final status in WatchStatus.values)
              Tab(text: '${status.title} (${counts[status] ?? 0})'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _list(library, null),
          for (final status in WatchStatus.values) _list(library, status),
        ],
      ),
    );
  }

  Widget _list(LibraryStore library, WatchStatus? status) {
    final entries = library.byStatus(status);
    if (entries.isEmpty) {
      return const MessageView(
        icon: Icons.bookmark_border,
        message: 'Пока пусто. Добавьте аниме из поиска — список хранится только '
            'в этом телефоне.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => _EntryTile(entry: entries[index]),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final WatchlistEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = entry.episodesTotal;
    final subtitle = <String>[
      entry.status.title,
      if (entry.lastEpisode > 0)
        'серия ${entry.lastEpisode}${total != null ? ' из $total' : ''}',
      if (entry.rating != null) 'оценка ${entry.rating}',
    ].join(' · ');

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: PosterImage(url: entry.posterUrl, width: 46, height: 66),
      ),
      title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
      trailing: total != null && total > 0
          ? SizedBox(
              width: 42,
              child: Text(
                '${((entry.lastEpisode / total) * 100).clamp(0, 100).round()}%',
                textAlign: TextAlign.end,
                style: theme.textTheme.labelMedium,
              ),
            )
          : null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AnimeScreen(
            card: entry.toCard(),
            startEpisode: entry.lastEpisode > 0 ? entry.lastEpisode : null,
          ),
        ),
      ),
      onLongPress: () => showModalBottomSheet<void>(
        context: context,
        builder: (_) => _EntryActions(entry: entry),
      ),
    );
  }
}

class _EntryActions extends StatelessWidget {
  const _EntryActions({required this.entry});

  final WatchlistEntry entry;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryStore>();
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(entry.title), subtitle: const Text('Сменить статус')),
          for (final status in WatchStatus.values)
            ListTile(
              title: Text(status.title),
              trailing: status == entry.status ? const Icon(Icons.check) : null,
              onTap: () async {
                await library.setStatus(entry.toCard(), status);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Убрать из списка'),
            onTap: () async {
              await library.remove(entry.source, entry.animeId);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}
