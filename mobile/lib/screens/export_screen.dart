import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/app_config.dart';
import '../data/epub_exporter.dart';
import '../data/glossary.dart';
import '../data/translation_cache.dart';
import '../models/parsed_book.dart';
import '../services/translator_service.dart';
import '../theme/app_theme.dart';

/// Tela de exportação: traduz (usando o cache sempre que possível)
/// todos os capítulos que ainda não tiverem tradução, depois monta
/// um EPUB novo e deixa o usuário escolher onde salvar.
class ExportScreen extends StatefulWidget {
  final ParsedBook book;

  const ExportScreen({super.key, required this.book});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  bool _running = false;
  bool _done = false;
  String? _error;
  Uri? _savedPath;
  int _chaptersDone = 0;
  double _chapterProgress = 0;

  Future<void> _startExport() async {
    setState(() {
      _running = true;
      _error = null;
      _done = false;
      _chaptersDone = 0;
    });

    try {
      final config = await AppConfig.load();
      final targetLang = config.get('target_language', 'pt') as String;
      final glossary = Glossary();
      await glossary.load();
      final cache = TranslationCache();
      final translator = Translator(targetLang: targetLang, cache: cache, glossary: glossary);

      final translatedByChapter = <int, List<String>>{};
      for (final chapter in widget.book.chapters) {
        final paragraphs = chapter.paragraphs;
        if (paragraphs.isEmpty) {
          _chaptersDone++;
          continue;
        }
        setState(() => _chapterProgress = 0);
        final translated = await translator.translateChapter(
          paragraphs,
          bookId: widget.book.bookId,
          chapterIndex: chapter.index,
          onProgress: (done, total) {
            if (mounted && total > 0) setState(() => _chapterProgress = done / total);
          },
        );
        translatedByChapter[chapter.index] = translated;
        _chaptersDone++;
        if (mounted) setState(() {});
      }

      final epubBytes = buildTranslatedEpub(widget.book, translatedByChapter, targetLang: targetLang);
      await _saveEpub(epubBytes);
    } catch (e) {
      setState(() => _error = 'Erro ao exportar: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _saveEpub(Uint8List bytes) async {
    final safeName = widget.book.title.replaceAll(RegExp(r'[^\w\- ]'), '_');
    final savedPath = await FilePicker.saveFile(
      fileName: '$safeName (traduzido).epub',
      bytes: bytes,
    );
    setState(() {
      _done = true;
      _savedPath = savedPath;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exportar EPUB traduzido')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.book.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.book.chapterCount} capítulo(s). Capítulos já traduzidos antes usam o '
              'cache — não são traduzidos de novo.',
              style: TextStyle(color: AppPalette.text.withOpacity(0.7)),
            ),
            const SizedBox(height: 24),
            if (_running) ...[
              LinearProgressIndicator(value: _chapterProgress == 0 ? null : _chapterProgress),
              const SizedBox(height: 8),
              Text('Traduzindo capítulo $_chaptersDone de ${widget.book.chapterCount}…'),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ),
            if (_done)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _savedPath != null
                      ? 'EPUB salvo com sucesso.'
                      : 'Exportação cancelada (nenhum local escolhido pra salvar).',
                  style: const TextStyle(color: AppPalette.accent),
                ),
              ),
            const SizedBox(height: 24),
            if (!_running)
              FilledButton.icon(
                onPressed: _startExport,
                icon: const Icon(Icons.file_download_outlined),
                label: Text(_done ? 'Exportar de novo' : 'Iniciar exportação'),
              ),
          ],
        ),
      ),
    );
  }
}
