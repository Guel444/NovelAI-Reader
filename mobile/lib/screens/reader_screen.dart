import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/app_config.dart';
import '../data/cover_theme.dart';
import '../data/glossary.dart';
import '../data/reading_time.dart';
import '../data/translation_cache.dart';
import '../models/epub_block.dart';
import '../models/parsed_book.dart';
import '../services/translator_service.dart';
import '../theme/app_theme.dart';
import 'glossary_screen.dart';
import 'highlights_screen.dart';
import 'export_screen.dart';
import 'translate_all_screen.dart';
import 'settings_screen.dart';
import 'wiki_screen.dart';

/// Tela de leitura de um capítulo: traduz automaticamente (se ligado
/// em config), navega entre capítulos, e marca como lido perto do
/// fim da rolagem (só marca de verdade perto do fim, não em
/// qualquer troca de capítulo).
class ReaderScreen extends StatefulWidget {
  final ParsedBook book;
  final int initialChapterIndex;

  const ReaderScreen({
    super.key,
    required this.book,
    this.initialChapterIndex = 0,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late int _chapterIndex;
  final ScrollController _scrollController = ScrollController();

  AppConfig? _config;
  Translator? _translator;
  List<String>? _translatedParagraphs; // alinhado por índice com chapter.paragraphs
  bool _isTranslating = false;
  String? _translationError;
  bool _markedReadThisChapter = false;
  Color _bgColor = AppPalette.bg;
  bool _sideBySide = false;
  bool _focusMode = false;

  @override
  void initState() {
    super.initState();
    _chapterIndex = widget.initialChapterIndex;
    _scrollController.addListener(_onScroll);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final config = await AppConfig.load();
    final glossary = Glossary();
    await glossary.load();
    final cache = TranslationCache();
    final translator = Translator(
      targetLang: config.get('target_language', 'pt') as String,
      cache: cache,
      glossary: glossary,
    );
    setState(() {
      _config = config;
      _translator = translator;
      _sideBySide = config.get('side_by_side', false) as bool;
      _chapterIndex = config.getLastChapter(widget.book.bookId).clamp(0, widget.book.chapterCount - 1);
    });

    final useCoverTheme = config.get('use_cover_theme', true) as bool;
    final cover = widget.book.coverBytes;
    if (useCoverTheme && cover != null) {
      final tint = await computeCoverTint(cover);
      if (mounted) setState(() => _bgColor = tint);
    }

    await _loadChapter(_chapterIndex);
  }

  Future<void> _loadChapter(int index) async {
    _markedReadThisChapter = _config?.isRead(widget.book.bookId, index) ?? false;
    setState(() {
      _translatedParagraphs = null;
      _translationError = null;
    });
    await _config?.setLastChapter(widget.book.bookId, index);

    final autoTranslate = _config?.get('auto_translate', true) as bool? ?? true;
    if (!autoTranslate || _translator == null) return;

    final chapter = widget.book.chapters[index];
    final paragraphs = chapter.paragraphs;
    if (paragraphs.isEmpty) return;

    setState(() => _isTranslating = true);
    try {
      final translated = await _translator!.translateChapter(
        paragraphs,
        bookId: widget.book.bookId,
        chapterIndex: index,
      );
      if (!mounted || index != _chapterIndex) return;
      setState(() {
        _translatedParagraphs = translated;
        _isTranslating = false;
      });
    } on TranslationError catch (e) {
      if (!mounted) return;
      setState(() {
        _translationError = e.message;
        _isTranslating = false;
      });
    }
  }

  void _onScroll() {
    if (_markedReadThisChapter || _config == null) return;
    final position = _scrollController.position;
    // perto do fim (ou capítulo curto o bastante pra caber na tela
    // sem precisar rolar)
    final nearEnd = position.maxScrollExtent <= 0 ||
        position.pixels >= position.maxScrollExtent - 80;
    if (nearEnd) {
      _markedReadThisChapter = true;
      _config!.markAsRead(widget.book.bookId, _chapterIndex);
    }
  }

  void _goToChapter(int newIndex) {
    if (newIndex < 0 || newIndex >= widget.book.chapterCount) return;
    setState(() => _chapterIndex = newIndex);
    _scrollController.jumpTo(0);
    _loadChapter(newIndex);
  }

  Future<void> _toggleFavorite() async {
    if (_config == null) return;
    await _config!.toggleFavorite(widget.book.bookId, _chapterIndex);
    setState(() {});
  }

  Future<void> _toggleRead() async {
    if (_config == null) return;
    if (_config!.isRead(widget.book.bookId, _chapterIndex)) {
      await _config!.unmarkAsRead(widget.book.bookId, _chapterIndex);
      _markedReadThisChapter = false;
    } else {
      await _config!.markAsRead(widget.book.bookId, _chapterIndex);
      _markedReadThisChapter = true;
    }
    setState(() {});
  }

  Future<void> _toggleSideBySide() async {
    setState(() => _sideBySide = !_sideBySide);
    await _config?.set('side_by_side', _sideBySide);
  }

  Future<void> _openNoteDialog() async {
    final config = _config;
    if (config == null) return;
    final controller = TextEditingController(text: config.getNote(widget.book.bookId, _chapterIndex));
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nota do capítulo'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          decoration: const InputDecoration(hintText: 'Escreva sua anotação…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salvar')),
        ],
      ),
    );
    if (result == true) {
      await config.setNote(widget.book.bookId, _chapterIndex, controller.text);
    }
  }

  Future<void> _onParagraphLongPress(String paragraphText) async {
    final config = _config;
    if (config == null) return;
    final existingIndex = config.findHighlightIndex(widget.book.bookId, _chapterIndex, paragraphText);
    if (existingIndex >= 0) {
      await _confirmRemoveHighlight(existingIndex, paragraphText);
    } else {
      await _openAddHighlightDialog(paragraphText);
    }
  }

  Future<void> _confirmRemoveHighlight(int highlightIndex, String paragraphText) async {
    final config = _config;
    if (config == null) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover grifo'),
        content: Text(
          paragraphText,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remover')),
        ],
      ),
    );
    if (result == true) {
      await config.removeHighlightAt(widget.book.bookId, _chapterIndex, highlightIndex);
      if (mounted) setState(() {});
    }
  }

  Future<void> _editTranslation(int paragraphIndex, String originalText, String currentTranslated) async {
    final translator = _translator;
    if (translator == null) return;
    final controller = TextEditingController(text: currentTranslated);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Corrigir tradução'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Original: $originalText',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppPalette.text.withOpacity(0.5), fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 6,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Tradução'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salvar')),
        ],
      ),
    );
    if (result == true) {
      final newText = controller.text.trim();
      if (newText.isEmpty) return;
      await translator.cache.set(
        originalText,
        newText,
        translator.targetLang,
        bookId: widget.book.bookId,
        chapterIndex: _chapterIndex,
      );
      if (mounted) {
        setState(() {
          if (_translatedParagraphs != null && paragraphIndex < _translatedParagraphs!.length) {
            _translatedParagraphs![paragraphIndex] = newText;
          }
        });
      }
    }
  }

  Future<void> _openAddHighlightDialog(String paragraphText) async {
    final config = _config;
    if (config == null) return;
    final commentController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Grifar parágrafo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              paragraphText,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: commentController,
              decoration: const InputDecoration(hintText: 'Comentário (opcional)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Grifar')),
        ],
      ),
    );
    if (result == true) {
      await config.addHighlight(
        widget.book.bookId,
        _chapterIndex,
        paragraphText,
        comment: commentController.text.trim(),
      );
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Parágrafo grifado.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.book.chapters[_chapterIndex];
    final isFavorite = _config?.isFavorite(widget.book.bookId, _chapterIndex) ?? false;
    final isRead = _config?.isRead(widget.book.bookId, _chapterIndex) ?? false;

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: _focusMode
          ? null
          : AppBar(
              backgroundColor: _bgColor,
              title: Text(
                chapter.title,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  onPressed: () => setState(() => _focusMode = true),
                  tooltip: 'Modo foco',
                ),
                IconButton(
                  icon: Icon(_sideBySide ? Icons.vertical_split : Icons.vertical_split_outlined),
                  onPressed: _toggleSideBySide,
                  tooltip: 'Original + tradução',
                ),
                IconButton(
                  icon: const Icon(Icons.edit_note),
                  onPressed: _openNoteDialog,
                  tooltip: 'Nota do capítulo',
                ),
                IconButton(
                  icon: Icon(isFavorite ? Icons.star : Icons.star_border),
                  onPressed: _toggleFavorite,
                  tooltip: 'Favoritar',
                ),
                IconButton(
                  icon: Icon(isRead ? Icons.check_circle : Icons.check_circle_outline),
                  onPressed: _toggleRead,
                  tooltip: 'Marcar como lido',
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'glossary':
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => GlossaryScreen(contextParagraphs: chapter.paragraphs),
                        ));
                        break;
                      case 'highlights':
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => HighlightsScreen(book: widget.book),
                        ));
                        break;
                      case 'settings':
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ));
                        break;
                      case 'wiki':
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const WikiScreen(),
                        ));
                        break;
                      case 'export':
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ExportScreen(book: widget.book),
                        ));
                        break;
                      case 'translate_all':
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => TranslateAllScreen(book: widget.book),
                        ));
                        break;
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'glossary', child: Text('Glossário')),
                    PopupMenuItem(value: 'highlights', child: Text('Grifos')),
                    PopupMenuItem(value: 'wiki', child: Text('Wiki de personagens')),
                    PopupMenuItem(value: 'translate_all', child: Text('Traduzir livro inteiro')),
                    PopupMenuItem(value: 'export', child: Text('Exportar EPUB traduzido')),
                    PopupMenuItem(value: 'settings', child: Text('Configurações')),
                  ],
                ),
              ],
            ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_isTranslating) const LinearProgressIndicator(minHeight: 3),
              if (_translationError != null)
                Container(
                  width: double.infinity,
                  color: Colors.red.withOpacity(0.15),
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'Erro ao traduzir: $_translationError',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  padding: EdgeInsets.symmetric(
                    horizontal: (_config?.get('margin', 28) as num? ?? 28).toDouble(),
                    vertical: 16,
                  ),
                  children: _buildBlocks(chapter.blocks),
                ),
              ),
              if (!_focusMode) _buildNavBar(),
            ],
          ),
          if (_focusMode)
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: Material(
                  color: Colors.black.withOpacity(0.35),
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.fullscreen_exit, color: Colors.white70),
                    tooltip: 'Sair do modo foco',
                    onPressed: () => setState(() => _focusMode = false),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildBlocks(List<EpubBlock> blocks) {
    final widgets = <Widget>[];
    var textIndex = 0;
    final fontSize = (_config?.get('font_size', 15) as num? ?? 15).toDouble();
    final lineSpacing = (_config?.get('line_spacing', 1.4) as num? ?? 1.4).toDouble();
    final fontFamilyValue = _config?.get('font_family', '') as String? ?? '';
    final fontFamily = fontFamilyValue.isEmpty ? null : fontFamilyValue;

    for (final block in blocks) {
      if (block.kind == 'image') {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Image.memory(block.image ?? Uint8List(0)),
        ));
        continue;
      }

      final currentIndex = textIndex; // snapshot antes de incrementar — usado no toque de editar
      final translated = _translatedParagraphs != null && currentIndex < _translatedParagraphs!.length
          ? _translatedParagraphs![currentIndex]
          : null;
      final showOriginalToo = _sideBySide && translated != null && translated != block.text;
      final displayText = translated ?? block.text;
      textIndex++;

      final isHighlighted = _config != null &&
          _config!.findHighlightIndex(widget.book.bookId, _chapterIndex, displayText) >= 0;

      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: GestureDetector(
          onLongPress: () => _onParagraphLongPress(displayText),
          onTap: translated != null
              ? () => _editTranslation(currentIndex, block.text, translated)
              : null,
          child: Container(
            decoration: isHighlighted
                ? BoxDecoration(
                    color: Colors.amber.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(6),
                    border: Border(
                      left: BorderSide(color: Colors.amber.withOpacity(0.8), width: 3),
                    ),
                  )
                : null,
            padding: isHighlighted
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
                : EdgeInsets.zero,
            child: showOriginalToo
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        block.text,
                        textAlign: block.style == 'highlighted' ? TextAlign.center : TextAlign.start,
                        style: TextStyle(
                          color: AppPalette.text.withOpacity(0.5),
                          fontSize: fontSize * 0.9,
                          height: lineSpacing,
                          fontStyle: FontStyle.italic,
                          fontFamily: fontFamily,
                        ),
                      ),
                      const SizedBox(height: 2),
                      _paragraphWidget(displayText, block.style, fontSize, lineSpacing, fontFamily),
                    ],
                  )
                : _paragraphWidget(displayText, block.style, fontSize, lineSpacing, fontFamily),
          ),
        ),
      ));
    }
    return widgets;
  }

  Widget _paragraphWidget(String text, String style, double fontSize, double lineSpacing, String? fontFamily) {
    switch (style) {
      case 'highlighted':
        return Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppPalette.text,
            fontSize: fontSize,
            height: lineSpacing,
            fontWeight: FontWeight.bold,
            fontStyle: FontStyle.italic,
            fontFamily: fontFamily,
          ),
        );
      case 'italic':
        return Text(
          text,
          style: TextStyle(
            color: AppPalette.text,
            fontSize: fontSize,
            height: lineSpacing,
            fontStyle: FontStyle.italic,
            fontFamily: fontFamily,
          ),
        );
      default:
        return Text(
          text,
          style: TextStyle(color: AppPalette.text, fontSize: fontSize, height: lineSpacing, fontFamily: fontFamily),
        );
    }
  }

  Widget _buildNavBar() {
    final wpm = (_config?.get('reading_wpm', 200) as num? ?? 200).toInt();
    final minutes = estimateReadingMinutes(widget.book.chapters[_chapterIndex], wpm);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            OutlinedButton.icon(
              onPressed: _chapterIndex > 0 ? () => _goToChapter(_chapterIndex - 1) : null,
              icon: const Icon(Icons.chevron_left),
              label: const Text('Anterior'),
            ),
            const Spacer(),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_chapterIndex + 1} / ${widget.book.chapterCount}',
                  style: TextStyle(color: AppPalette.text.withOpacity(0.6), fontSize: 12),
                ),
                Text(
                  '≈ $minutes min',
                  style: TextStyle(color: AppPalette.text.withOpacity(0.4), fontSize: 10),
                ),
              ],
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _chapterIndex < widget.book.chapterCount - 1
                  ? () => _goToChapter(_chapterIndex + 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
              label: const Text('Próximo'),
            ),
          ],
        ),
      ),
    );
  }
}
