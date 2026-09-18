/// Плеер: смотрим серию онлайн или из скачанного файла.
///
/// Заголовки (`Referer`) едут прямо в ExoPlayer — именно поэтому мобильному
/// приложению не нужен серверный прокси, без которого не обходится сайт.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../anime/catalog.dart';
import '../anime/models.dart';
import '../core/errors.dart';
import '../data/library_store.dart';
import '../data/models.dart';
import '../data/settings_store.dart';
import '../services/download_manager.dart';
import 'widgets/common.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.card,
    required this.episode,
    required this.episodes,
    this.playerKey,
  });

  final AnimeCard card;
  final int episode;
  final List<int> episodes;
  final String? playerKey;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _controller;
  EpisodeSource? _source;
  DownloadTask? _offline;
  VideoStream? _stream;

  late int _episode = widget.episode;
  late List<int> _episodes = widget.episodes;
  String? _playerKey;
  String? _error;
  bool _loading = true;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  Timer? _saveTimer;
  Duration _startAt = Duration.zero;
  double _completedRatio = 0.85;
  late final LibraryStore _library;

  @override
  void initState() {
    super.initState();
    // ссылку на хранилище держим у себя: dispose() уже не должен трогать context
    _library = context.read<LibraryStore>();
    _playerKey = widget.playerKey;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _open();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _saveProgress();
    _controller?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final downloads = context.read<DownloadManager>();
    // читаем провайдеры до первого await: после него context трогать нельзя
    final catalog = context.read<Catalog>();
    final completedRatio = context.read<SettingsStore>().completedRatio;
    _completedRatio = completedRatio;
    final offline = downloads.downloadedEpisode(
      widget.card.source,
      widget.card.id,
      _episode,
    );

    try {
      final stored = await _library.progressOf(widget.card.source, widget.card.id, _episode);
      _startAt = Duration(seconds: (stored?.position ?? 0).round());
      // досмотренную серию начинаем сначала, а не с последних секунд
      if (stored?.completed ?? false) _startAt = Duration.zero;

      if (offline != null && await File(offline.filePath).exists()) {
        _offline = offline;
        _source = null;
        _stream = null;
        await _attach(VideoPlayerController.file(File(offline.filePath)));
        return;
      }

      if (_episodes.isEmpty) {
        // сюда попадают с «продолжить просмотр»: список серий там не передают
        _episodes = await catalog.episodes(widget.card.id);
      }
      final source = await catalog.buildSource(
        widget.card.id,
        _episode,
        playerKey: _playerKey,
        card: widget.card,
      );
      if (!mounted) return;
      _offline = null;
      _source = source;
      _playerKey = source.option.key;
      final stream = source.preferred;
      _stream = stream;
      await _attach(
        VideoPlayerController.networkUrl(
          Uri.parse(stream.url),
          httpHeaders: stream.headers,
        ),
      );
    } on AnimeError catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось включить серию: $error';
        _loading = false;
      });
    }
  }

  Future<void> _attach(VideoPlayerController controller) async {
    final previous = _controller;
    _controller = controller;
    controller.addListener(_onTick);
    try {
      await controller.initialize();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Плеер не смог открыть дорожку. Попробуйте другое качество '
            'или другую озвучку.\n\n$error';
        _loading = false;
      });
      return;
    }
    await previous?.dispose();
    if (_startAt > Duration.zero && _startAt < controller.value.duration) {
      await controller.seekTo(_startAt);
    }
    await controller.play();
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 15), (_) => _saveProgress());
    if (!mounted) return;
    setState(() => _loading = false);
    _scheduleHide();
  }

  void _onTick() {
    if (!mounted) return;
    setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _saveProgress() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final position = controller.value.position.inSeconds.toDouble();
    if (position <= 0) return;
    final duration = controller.value.duration.inSeconds.toDouble();
    unawaited(
      _library.saveProgress(
        card: widget.card,
        episode: _episode,
        position: position,
        duration: duration > 0 ? duration : null,
        translation: _source?.option.label ?? _offline?.translation,
        playerKey: _playerKey,
        episodesTotal: _episodes.isEmpty ? null : _episodes.last,
        completedRatio: _completedRatio,
      ),
    );
  }

  Future<void> _switchStream(VideoStream stream) async {
    final controller = _controller;
    _startAt = controller?.value.position ?? Duration.zero;
    _stream = stream;
    setState(() => _loading = true);
    await _attach(
      VideoPlayerController.networkUrl(
        Uri.parse(stream.url),
        httpHeaders: stream.headers,
      ),
    );
  }

  Future<void> _switchEpisode(int episode) async {
    _saveProgress();
    _saveTimer?.cancel();
    setState(() {
      _episode = episode;
      _controlsVisible = true;
    });
    await _open();
  }

  Future<void> _switchDub() async {
    final options = await context.read<Catalog>().players(widget.card.id, _episode);
    if (!mounted) return;
    final choice = await showModalBottomSheet<PlayerOption>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final option in options)
              ListTile(
                textColor: Colors.white,
                iconColor: Colors.white,
                selected: option.key == _playerKey,
                leading: const Icon(Icons.record_voice_over_outlined),
                title: Text(option.label),
                subtitle: Text(
                  option.player,
                  style: const TextStyle(color: Colors.white70),
                ),
                onTap: () => Navigator.of(context).pop(option),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    _saveProgress();
    setState(() => _playerKey = choice.key);
    await _open();
  }

  Future<void> _pickQuality() async {
    final streams = _source?.streams ?? const <VideoStream>[];
    if (streams.isEmpty) return;
    final choice = await showModalBottomSheet<VideoStream>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final stream in streams)
              ListTile(
                textColor: Colors.white,
                iconColor: Colors.white,
                selected: stream.url == _stream?.url,
                leading: Icon(
                  stream.isMaster ? Icons.auto_awesome : Icons.high_quality_outlined,
                ),
                title: Text(stream.isMaster ? 'Авто (адаптивно)' : stream.qualityLabel),
                subtitle: Text(
                  stream.kind.value.toUpperCase(),
                  style: const TextStyle(color: Colors.white70),
                ),
                onTap: () => Navigator.of(context).pop(stream),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _switchStream(choice);
  }

  SkipSegment? get _activeSkip {
    final controller = _controller;
    final source = _source;
    if (controller == null || source == null || !controller.value.isInitialized) {
      return null;
    }
    final position = controller.value.position.inSeconds;
    for (final segment in source.skipSegments) {
      if (position >= segment.start && position < segment.end - 1) return segment;
    }
    return null;
  }

  int? get _nextEpisode {
    final index = _episodes.indexOf(_episode);
    if (index == -1 || index + 1 >= _episodes.length) return null;
    return _episodes[index + 1];
  }

  int? get _previousEpisode {
    final index = _episodes.indexOf(_episode);
    if (index <= 0) return null;
    return _episodes[index - 1];
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ready)
              Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
            if (_loading) const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Center(
                child: MessageView(
                  message: _error!,
                  onRetry: _open,
                  retryLabel: 'Попробовать снова',
                ),
              ),
            if (_controlsVisible || !ready) _controls(ready),
            if (_activeSkip != null && _controlsVisible == false) _skipButton(),
          ],
        ),
      ),
    );
  }

  Widget _skipButton() {
    final segment = _activeSkip!;
    return Positioned(
      right: 24,
      bottom: 32,
      child: FilledButton.icon(
        onPressed: () => _controller?.seekTo(Duration(seconds: segment.end)),
        icon: const Icon(Icons.fast_forward),
        label: Text(segment.title),
      ),
    );
  }

  Widget _controls(bool ready) {
    final controller = _controller;
    final position = controller?.value.position ?? Duration.zero;
    final duration = controller?.value.duration ?? Duration.zero;
    final playing = controller?.value.isPlaying ?? false;
    final skip = _activeSkip;

    return Container(
      color: Colors.black45,
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.card.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 15),
                      ),
                      Text(
                        _offline != null
                            ? 'Серия $_episode · скачано (${_offline!.translation})'
                            : 'Серия $_episode · ${_source?.option.label ?? ''}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (_source != null)
                  IconButton(
                    tooltip: 'Качество',
                    icon: const Icon(Icons.hd_outlined, color: Colors.white),
                    onPressed: _pickQuality,
                  ),
                IconButton(
                  tooltip: 'Озвучка',
                  icon: const Icon(Icons.record_voice_over_outlined, color: Colors.white),
                  onPressed: _switchDub,
                ),
              ],
            ),
            const Spacer(),
            if (skip != null)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 24, bottom: 8),
                  child: FilledButton.icon(
                    onPressed: () => _controller?.seekTo(Duration(seconds: skip.end)),
                    icon: const Icon(Icons.fast_forward),
                    label: Text(skip.title),
                  ),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 32,
                  color: Colors.white,
                  tooltip: 'Предыдущая серия',
                  onPressed: _previousEpisode == null
                      ? null
                      : () => _switchEpisode(_previousEpisode!),
                  icon: const Icon(Icons.skip_previous),
                ),
                IconButton(
                  iconSize: 32,
                  color: Colors.white,
                  onPressed: ready
                      ? () => controller!.seekTo(position - const Duration(seconds: 10))
                      : null,
                  icon: const Icon(Icons.replay_10),
                ),
                IconButton(
                  iconSize: 48,
                  color: Colors.white,
                  onPressed: ready
                      ? () {
                          if (playing) {
                            controller!.pause();
                          } else {
                            controller!.play();
                          }
                          _scheduleHide();
                        }
                      : null,
                  icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                ),
                IconButton(
                  iconSize: 32,
                  color: Colors.white,
                  onPressed: ready
                      ? () => controller!.seekTo(position + const Duration(seconds: 10))
                      : null,
                  icon: const Icon(Icons.forward_10),
                ),
                IconButton(
                  iconSize: 32,
                  color: Colors.white,
                  tooltip: 'Следующая серия',
                  onPressed:
                      _nextEpisode == null ? null : () => _switchEpisode(_nextEpisode!),
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(
                    formatDuration(position),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Expanded(
                    child: Slider(
                      value: duration.inMilliseconds == 0
                          ? 0
                          : position.inMilliseconds
                              .clamp(0, duration.inMilliseconds)
                              .toDouble(),
                      max: duration.inMilliseconds.toDouble().clamp(1, double.infinity),
                      onChanged: ready
                          ? (value) => controller!
                              .seekTo(Duration(milliseconds: value.round()))
                          : null,
                    ),
                  ),
                  Text(
                    formatDuration(duration),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
