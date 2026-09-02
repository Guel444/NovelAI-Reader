import 'package:flutter/material.dart';

import '../data/app_config.dart';
import '../models/parsed_book.dart';
import '../theme/app_theme.dart';
import 'reader_screen.dart';
import 'share_highlight_screen.dart';

/// Lista de grifos (trechos marcados + comentário) de um livro,
/// agrupados por capítulo.
class HighlightsScreen extends StatefulWidget {
  final ParsedBook book;

  const HighlightsScreen({super.key, required this.book});

  @override
  State<HighlightsScreen> createState() => _HighlightsScreenState();
}

class _HighlightsScreenState extends State<HighlightsScreen> {
  AppConfig? _config;

  @override
  void initState() {
    super.initState();
    AppConfig.load().then((c) => setState(() => _config = c));
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    if (config == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final items = <(int chapterIndex, String chapterTitle, int highlightIndex, Map<String, dynamic> highlight)>[];
    for (final chapter in widget.book.chapters) {
      final chapterHighlights = config.getHighlights(widget.book.bookId, chapter.index);
      for (var hi = 0; hi < chapterHighlights.length; hi++) {
        items.add((chapter.index, chapter.title, hi, chapterHighlights[hi]));
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Grifos')),
      body: items.isEmpty
          ? Center(
              child: Text(
                'Nenhum grifo ainda.\nSegure um parágrafo na leitura para grifar.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppPalette.text.withOpacity(0.6)),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final (chapterIndex, chapterTitle, highlightIndex, highlight) = items[i];
                final text = highlight['text'] as String? ?? '';
                final comment = highlight['comment'] as String? ?? '';
                return Card(
                  color: AppPalette.surface,
                  child: ListTile(
                    title: Text(
                      text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                    subtitle: Text(
                      comment.isNotEmpty ? '$chapterTitle · $comment' : chapterTitle,
                      style: TextStyle(color: AppPalette.text.withOpacity(0.6), fontSize: 12),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.share_outlined, size: 20),
                          tooltip: 'Compartilhar como imagem',
                          onPressed: () {
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => ShareHighlightScreen(
                                text: text,
                                comment: comment,
                                bookTitle: widget.book.title,
                                chapterTitle: chapterTitle,
                              ),
                            ));
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: 'Remover grifo',
                          onPressed: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Remover grifo?'),
                                content: Text(text, maxLines: 4, overflow: TextOverflow.ellipsis),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancelar'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Remover'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true) {
                              await config.removeHighlightAt(widget.book.bookId, chapterIndex, highlightIndex);
                              setState(() {});
                            }
                          },
                        ),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ReaderScreen(
                          book: widget.book,
                          initialChapterIndex: chapterIndex,
                        ),
                      ));
                    },
                  ),
                );
              },
            ),
    );
  }
}
