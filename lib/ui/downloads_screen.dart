/// Загрузки: очередь, прогресс и то, что уже лежит на телефоне.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../anime/catalog.dart';
import '../data/models.dart';
import '../services/download_manager.dart';
import 'player_screen.dart';
import 'widgets/common.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadManager>();
    final active = downloads.active;
    final paused = downloads.tasks
        .where((task) =>
            task.status == DownloadStatus.paused || task.status == DownloadStatus.failed)
        .toList();
    final done = downloads.completed;

    if (downloads.tasks.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Загрузки')),
        body: const MessageView(
          icon: Icons.download_outlined,
          message: 'Здесь появятся серии, скачанные на телефон.\n'
              'Кнопка «скачать» — на странице аниме, у каждой серии.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Загрузки')),
      body: ListView(
        children: [
          if (active.isNotEmpty) ...[
            const SectionTitle('Сейчас качается'),
            for (final task in active) _TaskTile(task: task),
          ],
          if (paused.isNotEmpty) ...[
            const SectionTitle('Остановлено'),
            for (final task in paused) _TaskTile(task: task),
          ],
          if (done.isNotEmpty) ...[
            SectionTitle('На телефоне (${done.length})'),
            for (final task in done) _TaskTile(task: task),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final downloads = context.read<DownloadManager>();
    final theme = Theme.of(context);

    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: PosterImage(url: task.posterUrl, width: 42, height: 60),
      ),
      title: Text(task.label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _subtitle(task),
            style: theme.textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (task.status != DownloadStatus.done) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: task.progress > 0 ? task.progress : null,
              minHeight: 4,
            ),
          ],
        ],
      ),
      trailing: _actions(context, downloads),
      onTap: task.status == DownloadStatus.done ? () => _play(context) : null,
    );
  }

  String _subtitle(DownloadTask task) {
    final parts = <String>[
      task.translation,
      if (task.quality != null) '${task.quality}p',
      task.status.title,
    ];
    if (task.status == DownloadStatus.failed && task.error != null) {
      return '${parts.join(' · ')}\n${task.error}';
    }
    if (task.segmentsTotal != null && task.status != DownloadStatus.done) {
      parts.add('${task.segmentsDone}/${task.segmentsTotal} сегментов');
    } else if (task.receivedBytes > 0) {
      parts.add(formatBytes(task.receivedBytes));
    }
    return parts.join(' · ');
  }

  Widget _actions(BuildContext context, DownloadManager downloads) {
    return PopupMenuButton<String>(
      onSelected: (action) async {
        switch (action) {
          case 'pause':
            await downloads.pause(task);
          case 'resume':
            await downloads.resume(task);
          case 'delete':
            await downloads.remove(task);
          case 'play':
            if (context.mounted) _play(context);
        }
      },
      itemBuilder: (context) => [
        if (task.status == DownloadStatus.done)
          const PopupMenuItem(value: 'play', child: Text('Смотреть')),
        if (task.isActive)
          const PopupMenuItem(value: 'pause', child: Text('Пауза')),
        if (task.status == DownloadStatus.paused || task.status == DownloadStatus.failed)
          const PopupMenuItem(value: 'resume', child: Text('Продолжить')),
        const PopupMenuItem(value: 'delete', child: Text('Удалить')),
      ],
    );
  }

  void _play(BuildContext context) {
    if (!File(task.filePath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Файл не найден — возможно, его удалили')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          card: AnimeCard(
            id: task.animeId,
            title: task.animeTitle,
            source: task.source,
            poster: task.posterUrl,
          ),
          episode: task.episode,
          episodes: [task.episode],
          playerKey: task.playerKey,
        ),
      ),
    );
  }
}
