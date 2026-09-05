import 'package:flutter/material.dart';

import '../data/app_config.dart';
import '../data/glossary.dart';
import '../data/translation_cache.dart';
import '../models/parsed_book.dart';
import '../services/translator_service.dart';
import '../theme/app_theme.dart';

/// Tela de tradução em lote: traduz todos os capítulos do livro de
/// uma vez (reaproveitando o cache do que já foi traduzido antes),
/// sem gerar nenhum arquivo — só deixa tudo pronto no cache local
/// pra ler offline depois, capítulo por capítulo.
class TranslateAllScreen extends StatefulWidget {
  final ParsedBook book;

  const TranslateAllScreen({super.key, required this.book});

  @override
  State<TranslateAllScreen> createState() => _TranslateAllScreenState();
}

class _TranslateAllScreenState extends State<TranslateAllScreen> {
  bool _running = false;
  bool _done = false;
  String? _error;
  int _chaptersDone = 0;
  int _chaptersFailed = 0;
  double _chapterProgress = 0;

  Future<void> _startTranslating() async {
    setState(() {
      _running = true;
      _error = null;
      _done = false;
      _chaptersDone = 0;
      _chaptersFailed = 0;
    });

    try {
      final config = await AppConfig.load();
      final targetLang = config.get('target_language', 'pt') as String;
      final glossary = Glossary();
      await glossary.load();
      final cache = TranslationCache();
      final translator = Translator(targetLang: targetLang, cache: cache, glossary: glossary);

      for (final chapter in widget.book.chapters) {
        final paragraphs = chapter.paragraphs;
        if (paragraphs.isEmpty) {
          _chaptersDone++;
          if (mounted) setState(() {});
          continue;
        }
        setState(() => _chapterProgress = 0);
        try {
          await translator.translateChapter(
            paragraphs,
            bookId: widget.book.bookId,
            chapterIndex: chapter.index,
            onProgress: (done, total) {
              if (mounted && total > 0) setState(() => _chapterProgress = done / total);
            },
          );
        } on TranslationError {
          _chaptersFailed++;
        }
        _chaptersDone++;
        if (mounted) setState(() {});
      }

      if (mounted) setState(() => _done = true);
    } catch (e) {
      setState(() => _error = 'Erro ao traduzir: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Traduzir livro inteiro')),
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
              'cache e não são traduzidos de novo. Nenhum arquivo é gerado — o resultado só '
              'fica salvo pra você ler offline depois, capítulo por capítulo.',
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
                  _chaptersFailed == 0
                      ? 'Pronto! Todos os capítulos foram traduzidos.'
                      : '$_chaptersFailed capítulo(s) não traduziram (mantidos no idioma '
                          'original) — pode tentar de novo mais tarde.',
                  style: TextStyle(
                    color: _chaptersFailed == 0 ? AppPalette.accent : Colors.orangeAccent,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            if (!_running)
              FilledButton.icon(
                onPressed: _startTranslating,
                icon: const Icon(Icons.translate),
                label: Text(_done ? 'Traduzir de novo' : 'Traduzir tudo agora'),
              ),
          ],
        ),
      ),
    );
  }
}
