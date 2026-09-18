/// Страница тайтла: описание, озвучки, серии, кнопки списка и скачивания.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../anime/catalog.dart';
import '../core/errors.dart';
import '../data/library_store.dart';
import '../data/models.dart';
import '../services/download_manager.dart';
import 'player_screen.dart';
import 'widgets/common.dart';

class AnimeScreen extends StatefulWidget {
  const AnimeScreen({super.key, required this.card, this.startEpisode});

  final AnimeCard card;

  /// С какой серии открывать (кнопка «продолжить»).
  final int? startEpisode;

  @override
  State<AnimeScreen> createState() => _AnimeScreenState();
}

class _AnimeScreenState extends State<AnimeScreen> {
  late AnimeCard _card = widget.card;

  List<int> _episodes = const [];
  List<PlayerOption> _players = const [];
  Map<int, EpisodeProgress> _progress = const {};
  String? _playerKey;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final catalog = context.read<Catalog>();
    final library = context.read<LibraryStore>();
    try {
      final details = await catalog.details(
        _card.id,
        episode: widget.startEpisode ?? 1,
        card: _card.description == null ? null : _card,
      );
      final progress = await library.progressFor(_card.source, _card.id);
      if (!mounted) return;
      setState(() {
        _card = details.card.poster == null
            ? details.card.copyWith(poster: _card.poster)
            : details.card;
        _episodes = details.episodes;
        _players = details.players;
        _progress = progress;
        _playerKey ??= _preferredPlayerKey(details.players, progress);
        _loading = false;
      });
    } on AnimeError catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  /// Озвучку берём ту, на которой остановились в прошлый раз.
  String? _preferredPlayerKey(
    List<PlayerOption> options,
    Map<int, EpisodeProgress> progress,
  ) {
    if (options.isEmpty) return null;
    final seen = progress.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    for (final item in seen) {
      final key = item.playerKey;
      if (key == null) continue;
      for (final option in options) {
        if (option.key == key) return key;
      }
    }
    return options.first.key;
  }

  PlayerOption? get _selectedOption {
    for (final option in _players) {
      if (option.key == _playerKey) return option;
    }
    return _players.isEmpty ? null : _players.first;
  }

  Future<void> _openEpisode(int episode) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          card: _card,
          episode: episode,
          episodes: _episodes,
          playerKey: _playerKey,
        ),
      ),
    );
    if (!mounted) return;
    final progress = await context.read<LibraryStore>().progressFor(_card.source, _card.id);
    if (!mounted) return;
    setState(() => _progress = progress);
  }

  Future<void> _download(int episode) async {
    final option = _selectedOption;
    if (option == null) return;
    final downloads = context.read<DownloadManager>();
    await context.read<LibraryStore>().ensureEntry(
          _card,
          episodesTotal: _episodes.isEmpty ? null : _episodes.last,
        );
    await downloads.enqueue(
      card: _card,
      episode: episode,
      translation: option.label,
      playerKey: option.key,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Серия $episode добавлена в загрузки')),
    );
  }

  Future<void> _downloadRange() async {
    final option = _selectedOption;
    if (option == null || _episodes.isEmpty) return;
    final range = await showDialog<List<int>>(
      context: context,
      builder: (_) => _RangeDialog(episodes: _episodes),
    );
    if (range == null || range.isEmpty || !mounted) return;

    await context.read<LibraryStore>().ensureEntry(
          _card,
          episodesTotal: _episodes.last,
        );
    if (!mounted) return;
    await context.read<DownloadManager>().enqueueRange(
          card: _card,
          episodes: range,
          translation: option.label,
          playerKey: option.key,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('В очередь добавлено серий: ${range.length}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final entry = library.find(_card.source, _card.id);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 260,
              flexibleSpace: FlexibleSpaceBar(
                background: _Header(card: _card),
                title: Text(
                  _card.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
                titlePadding: const EdgeInsets.fromLTRB(52, 0, 16, 14),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: MessageView(message: _error!, onRetry: _load),
              )
            else ...[
              SliverToBoxAdapter(child: _statusRow(entry)),
              SliverToBoxAdapter(child: _info()),
              SliverToBoxAdapter(child: _playersRow()),
              SliverToBoxAdapter(
                child: SectionTitle(
                  'Серии (${_episodes.length})',
                  trailing: TextButton.icon(
                    onPressed: _downloadRange,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('Скачать несколько'),
                  ),
                ),
              ),
              _episodeGrid(),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _info() {
    final description = _card.description;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_card.originalTitle != null && _card.originalTitle!.isNotEmpty)
            Text(
              _card.originalTitle!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_card.genres.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final genre in _card.genres)
                  Chip(
                    label: Text(genre, style: const TextStyle(fontSize: 12)),
                    padding: EdgeInsets.zero,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ExpandableText(text: description),
          ],
        ],
      ),
    );
  }

  Widget _statusRow(WatchlistEntry? entry) {
    final library = context.read<LibraryStore>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButtonHideUnderline(
            child: DropdownButton<WatchStatus?>(
              value: entry?.status,
              hint: const Text('Добавить в список'),
              borderRadius: BorderRadius.circular(12),
              items: [
                for (final status in WatchStatus.values)
                  DropdownMenuItem(value: status, child: Text(status.title)),
              ],
              onChanged: (status) async {
                if (status == null) return;
                await library.setStatus(_card, status);
              },
            ),
          ),
          if (entry != null)
            _RatingButton(
              rating: entry.rating,
              onChanged: (value) => library.setRating(_card.source, _card.id, value),
            ),
          if (entry != null)
            IconButton(
              tooltip: 'Убрать из списка',
              icon: const Icon(Icons.bookmark_remove_outlined),
              onPressed: () => library.remove(_card.source, _card.id),
            ),
        ],
      ),
    );
  }

  Widget _playersRow() {
    if (_players.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('Озвучка и плеер'),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _players.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final option = _players[index];
              final selected = option.key == _selectedOption?.key;
              return ChoiceChip(
                selected: selected,
                onSelected: (_) => setState(() => _playerKey = option.key),
                label: Text('${option.label} · ${option.player}'),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _episodeGrid() {
    final downloads = context.watch<DownloadManager>();
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 96,
          childAspectRatio: 1.35,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        delegate: SliverChildBuilderDelegate(
          childCount: _episodes.length,
          (context, index) {
            final episode = _episodes[index];
            final progress = _progress[episode];
            final task = downloads.findFor(
              _card.source,
              _card.id,
              episode,
              _selectedOption?.label ?? '',
            );
            return _EpisodeTile(
              episode: episode,
              progress: progress,
              task: task,
              onTap: () => _openEpisode(episode),
              onDownload: () => _download(episode),
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.card});

  final AnimeCard card;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        PosterImage(url: card.poster),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.15),
                Colors.black.withValues(alpha: 0.85),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.progress,
    required this.task,
    required this.onTap,
    required this.onDownload,
  });

  final int episode;
  final EpisodeProgress? progress;
  final DownloadTask? task;
  final VoidCallback onTap;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final watched = progress?.completed ?? false;
    final percent = progress?.percent ?? 0;

    return InkWell(
      onTap: onTap,
      onLongPress: onDownload,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        decoration: BoxDecoration(
          color: watched
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
              : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$episode', style: theme.textTheme.titleMedium),
                  if (percent > 0 && !watched)
                    Text('$percent%', style: theme.textTheme.labelSmall),
                ],
              ),
            ),
            if (watched)
              const Positioned(
                right: 4,
                top: 4,
                child: Icon(Icons.check_circle, size: 14),
              ),
            if (task != null)
              Positioned(
                left: 4,
                top: 4,
                child: Icon(
                  task!.status == DownloadStatus.done
                      ? Icons.offline_pin
                      : Icons.downloading,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
              ),
            Positioned(
              right: 0,
              bottom: 0,
              child: IconButton(
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                tooltip: 'Скачать',
                onPressed: onDownload,
                icon: const Icon(Icons.download_outlined),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RatingButton extends StatelessWidget {
  const _RatingButton({required this.rating, required this.onChanged});

  final int? rating;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int?>(
      tooltip: 'Моя оценка',
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (var value = 10; value >= 1; value--)
          PopupMenuItem(value: value, child: Text('$value')),
        const PopupMenuDivider(),
        const PopupMenuItem<int?>(value: null, child: Text('Убрать оценку')),
      ],
      child: Chip(
        avatar: const Icon(Icons.star_outline, size: 18),
        label: Text(rating == null ? 'Оценка' : '$rating / 10'),
      ),
    );
  }
}

class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.text});

  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Text(
        widget.text,
        maxLines: _expanded ? null : 4,
        overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

/// Диалог «скачать с N по M».
class _RangeDialog extends StatefulWidget {
  const _RangeDialog({required this.episodes});

  final List<int> episodes;

  @override
  State<_RangeDialog> createState() => _RangeDialogState();
}

class _RangeDialogState extends State<_RangeDialog> {
  late double _from = widget.episodes.first.toDouble();
  late double _to = widget.episodes.length > 5
      ? widget.episodes[4].toDouble()
      : widget.episodes.last.toDouble();

  @override
  Widget build(BuildContext context) {
    final first = widget.episodes.first.toDouble();
    final last = widget.episodes.last.toDouble();
    final count = widget.episodes
        .where((episode) => episode >= _from && episode <= _to)
        .length;

    return AlertDialog(
      title: const Text('Скачать серии'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('С ${_from.round()} по ${_to.round()} — серий: $count'),
          Slider(
            value: _from,
            min: first,
            max: last,
            divisions: last > first ? (last - first).round() : null,
            label: '${_from.round()}',
            onChanged: (value) => setState(() {
              _from = value;
              if (_to < _from) _to = _from;
            }),
          ),
          Slider(
            value: _to,
            min: first,
            max: last,
            divisions: last > first ? (last - first).round() : null,
            label: '${_to.round()}',
            onChanged: (value) => setState(() {
              _to = value;
              if (_from > _to) _from = _to;
            }),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            widget.episodes
                .where((episode) => episode >= _from && episode <= _to)
                .toList(),
          ),
          child: const Text('В очередь'),
        ),
      ],
    );
  }
}
