import 'package:flutter/material.dart';

import '../data/app_config.dart';
import '../data/epub_parser.dart';
import '../data/reading_time.dart';
import '../models/parsed_book.dart';
import '../models/parsed_book_source.dart';
import '../theme/app_theme.dart';
import 'chapter_manager_screen.dart';
import 'export_screen.dart';
import 'reader_screen.dart';

/// Lista de capítulos do livro aberto, com busca, indicadores de
/// lido/favorito/nota/grifos, e acesso ao gerenciador manual de
/// capítulos.
class ChapterListScreen extends StatefulWidget {
  final ParsedBookSource source;

  const ChapterListScreen({super.key, required this.source});

  @override
  State<ChapterListScreen> createState() => _ChapterListScreenState();
}

class _ChapterListScreenState extends State<ChapterListScreen> {
  AppConfig? _config;
  String _query = '';
  late ParsedBook _book;

  @override
  void initState() {
    super.initState();
    _book = buildParsedBook(widget.source, const {});
    AppConfig.load().then((c) {
      setState(() {
        _config = c;
        _book = buildParsedBook(widget.source, c.getChapterOverrides(widget.source.bookId));
      });
    });
  }

  Future<void> _openChapterManager() async {
    final config = _config;
    if (config == null) return;
    final result = await Navigator.of(context).push<Map<String, bool>>(
      MaterialPageRoute(
        builder: (_) => ChapterManagerScreen(
          source: widget.source,
          initialOverrides: config.getChapterOverrides(widget.source.bookId),
        ),
      ),
    );
    if (result == null) return;
    await config.setChapterOverrides(widget.source.bookId, result);
    setState(() {
      _book = buildParsedBook(widget.source, result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _book.chapters
        .where((c) => c.title.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_book.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: 'Exportar EPUB traduzido',
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ExportScreen(book: _book),
              ));
            },
          ),
          IconButton(
            icon: const Icon(Icons.rule_folder_outlined),
            tooltip: 'Gerenciar capítulos',
            onPressed: _openChapterManager,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Buscar capítulo…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, i) {
                final chapter = filtered[i];
                final isRead = _config?.isRead(_book.bookId, chapter.index) ?? false;
                final isFav = _config?.isFavorite(_book.bookId, chapter.index) ?? false;
                final hasNote = (_config?.getNote(_book.bookId, chapter.index) ?? '').trim().isNotEmpty;
                final highlightCount = _config?.getHighlights(_book.bookId, chapter.index).length ?? 0;
                final wpm = (_config?.get('reading_wpm', 200) as num? ?? 200).toInt();
                final minutes = estimateReadingMinutes(chapter, wpm);
                return ListTile(
                  leading: isRead
                      ? const Icon(Icons.check_circle, color: AppPalette.accent, size: 20)
                      : const Icon(Icons.circle_outlined, size: 20, color: Colors.white24),
                  title: Text(chapter.title),
                  subtitle: Row(
                    children: [
                      Text(
                        '≈ $minutes min',
                        style: TextStyle(color: AppPalette.text.withOpacity(0.5), fontSize: 11),
                      ),
                      if (hasNote) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.edit_note, size: 14, color: AppPalette.text.withOpacity(0.5)),
                      ],
                      if (highlightCount > 0) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.format_quote, size: 13, color: AppPalette.text.withOpacity(0.5)),
                        Text(
                          ' $highlightCount',
                          style: TextStyle(color: AppPalette.text.withOpacity(0.5), fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                  trailing: isFav ? const Icon(Icons.star, color: AppPalette.accent, size: 18) : null,
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ReaderScreen(
                        book: _book,
                        initialChapterIndex: chapter.index,
                      ),
                    ));
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
