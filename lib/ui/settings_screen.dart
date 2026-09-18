/// Настройки: источник, зеркало, прокси, качество и оформление.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../anime/catalog.dart';
import 'widgets/common.dart';
import '../data/settings_store.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final catalog = context.read<Catalog>();

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        children: [
          const SectionTitle('Каталог'),
          ListTile(
            title: const Text('Источник'),
            subtitle: Text(
              settings.source == 'animedia'
                  ? 'Animedia (amd.online)'
                  : 'AnimeGO — больше озвучек',
            ),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'animego', label: Text('AnimeGO')),
                ButtonSegment(value: 'animedia', label: Text('Animedia')),
              ],
              selected: {settings.source},
              onSelectionChanged: (value) => settings.setSource(value.first),
            ),
          ),
          _TextSetting(
            title: 'Зеркало AnimeGO',
            subtitle: 'Например animego.me — помогает, когда основной домен '
                'закрыт Cloudflare',
            value: settings.animegoMirror,
            hint: 'animego.me',
            onChanged: settings.setAnimegoMirror,
          ),
          _TextSetting(
            title: 'Адрес Animedia',
            subtitle: 'Домен переезжает время от времени',
            value: settings.animediaBaseUrl,
            hint: 'https://amd.online',
            onChanged: settings.setAnimediaBaseUrl,
          ),
          _TextSetting(
            title: 'HTTP-прокси',
            subtitle: 'host:port — когда источник или CDN недоступны',
            value: settings.proxy,
            hint: '127.0.0.1:8080',
            onChanged: settings.setProxy,
          ),
          ListTile(
            title: const Text('Сбросить кэш каталога'),
            subtitle: const Text('Поиск, списки серий и ссылки на видео'),
            trailing: const Icon(Icons.refresh),
            onTap: () {
              catalog.clearCaches();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Кэш очищен')),
              );
            },
          ),

          const SectionTitle('Просмотр'),
          _QualitySetting(
            title: 'Максимальное качество',
            value: settings.maxQuality,
            onChanged: settings.setMaxQuality,
          ),
          ListTile(
            title: const Text('Считать серию просмотренной'),
            subtitle: Text('после ${(settings.completedRatio * 100).round()}% длительности'),
            trailing: SizedBox(
              width: 160,
              child: Slider(
                value: settings.completedRatio,
                min: 0.5,
                max: 0.98,
                divisions: 24,
                label: '${(settings.completedRatio * 100).round()}%',
                onChanged: settings.setCompletedRatio,
              ),
            ),
          ),

          const SectionTitle('Скачивание'),
          _QualitySetting(
            title: 'Качество загрузок',
            value: settings.downloadQuality,
            onChanged: settings.setDownloadQuality,
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Куда сохраняются серии'),
            subtitle: Text(
              'Во внутреннюю папку приложения — разрешения не нужны, но при '
              'удалении приложения файлы тоже удалятся.',
            ),
          ),

          const SectionTitle('Оформление'),
          ListTile(
            title: const Text('Тема'),
            trailing: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto)),
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode)),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode)),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (value) => settings.setThemeMode(value.first),
            ),
          ),

          const SectionTitle('О приложении'),
          const ListTile(
            leading: Icon(Icons.lock_open),
            title: Text('Ни аккаунтов, ни сервера'),
            subtitle: Text(
              'Список, оценки и прогресс хранятся только в этом телефоне. '
              'Видео приложение берёт напрямую у плееров — так же, как это '
              'делает обычный браузер.',
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _QualitySetting extends StatelessWidget {
  const _QualitySetting({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final int value;
  final ValueChanged<int> onChanged;

  static const List<int> _options = [360, 480, 720, 1080, 2160];

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: DropdownButton<int>(
        value: _options.contains(value) ? value : 1080,
        borderRadius: BorderRadius.circular(12),
        items: [
          for (final option in _options)
            DropdownMenuItem(value: option, child: Text('${option}p')),
        ],
        onChanged: (selected) => selected == null ? null : onChanged(selected),
      ),
    );
  }
}

class _TextSetting extends StatelessWidget {
  const _TextSetting({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.hint,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(value.isEmpty ? subtitle : value),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () async {
        final controller = TextEditingController(text: value);
        final result = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: hint, helperText: subtitle),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(''),
                child: const Text('Очистить'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: const Text('Сохранить'),
              ),
            ],
          ),
        );
        if (result != null) onChanged(result);
      },
    );
  }
}
