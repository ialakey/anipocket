/// Поиск по каталогу выбранного источника.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../anime/catalog.dart';
import '../core/errors.dart';
import 'anime_screen.dart';
import 'settings_screen.dart';
import 'widgets/common.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery ?? '');

  List<AnimeCard>? _results;
  String? _error;
  bool _loading = false;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    if ((widget.initialQuery ?? '').trim().length >= 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.length < 2) {
      setState(() => _error = 'Введите хотя бы два символа');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _lastQuery = query;
    });
    try {
      final results = await context.read<Catalog>().search(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } on AnimeError catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _results = null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = context.watch<Catalog>().sourceName;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Поиск'),
        actions: [
          IconButton(
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Название аниме — источник $source',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _controller.clear();
                          setState(() {
                            _results = null;
                            _error = null;
                          });
                        },
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return MessageView(message: _error!, onRetry: _search);
    }
    final results = _results;
    if (results == null) {
      return const MessageView(
        icon: Icons.travel_explore,
        message: 'Найдите аниме по названию — русскому или оригинальному.',
      );
    }
    if (results.isEmpty) {
      return MessageView(
        icon: Icons.search_off,
        message: 'По запросу «$_lastQuery» ничего не нашлось',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.52,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final card = results[index];
        return AnimeGridCard(
          card: card,
          subtitle: card.originalTitle,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => AnimeScreen(card: card)),
          ),
        );
      },
    );
  }
}
