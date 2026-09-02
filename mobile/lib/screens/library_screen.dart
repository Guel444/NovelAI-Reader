import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/app_config.dart';
import '../data/epub_parser.dart';
import '../data/pdf_parser.dart';
import '../data/plaintext_parser.dart';
import '../models/parsed_book_source.dart';
import '../theme/app_theme.dart';
import 'chapter_list_screen.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';

Future<ParsedBookSource> _parseByExtension(Uint8List bytes, String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.txt')) {
    return TxtParser.parse(bytes, fileName);
  }
  if (lower.endsWith('.pdf')) {
    return PdfParser.parse(bytes, fileName);
  }
  return EpubParser.parse(bytes, fileName);
}

/// Tela inicial do app: mostra a estante de livros já abertos e o
/// botão pra abrir um livro novo (EPUB, TXT ou PDF).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  AppConfig? _config;
  List<LibraryEntry> _library = [];
  bool _isOpening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final config = await AppConfig.load();
    setState(() {
      _config = config;
      _library = config.getLibrary();
    });
  }

  Future<void> _openBook() async {
    setState(() {
      _error = null;
    });

    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub', 'txt', 'pdf'],
      withData: true,
    );
    if (files.isEmpty) return;

    final picked = files.single;
    Uint8List? bytes;
    try {
      bytes = await picked.xFile.readAsBytes();
    } catch (_) {
      bytes = null;
    }
    if (bytes == null) {
      setState(() => _error = 'Não consegui ler o arquivo selecionado.');
      return;
    }

    setState(() => _isOpening = true);
    try {
      final source = await _parseByExtension(
        Uint8List.fromList(bytes),
        picked.name,
      );
      final overrides = _config?.getChapterOverrides(source.bookId) ?? const {};
      final book = buildParsedBook(source, overrides);

      if (book.chapters.isEmpty) {
        setState(() {
          _error = 'Não encontrei nenhum capítulo de verdade neste arquivo automaticamente. '
              'Abrindo mesmo assim — use "Gerenciar capítulos" pra incluir algum na mão.';
          _isOpening = false;
        });
      }

      await _config?.addToLibrary(LibraryEntry(
        bookId: source.bookId,
        path: picked.path ?? picked.name,
        title: source.title,
        author: source.author,
        lastOpened: DateTime.now(),
      ));
      await _loadLibrary();

      if (!mounted) return;
      setState(() => _isOpening = false);
      _openSource(source);
    } catch (e) {
      setState(() => _isOpening = false);
      if (mounted) _showErrorDialog(e.toString());
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Não consegui abrir o arquivo'),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Entendi')),
        ],
      ),
    );
  }

  void _openSource(ParsedBookSource source) {
    final overrides = _config?.getChapterOverrides(source.bookId) ?? const {};
    final book = buildParsedBook(source, overrides);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => book.chapterCount == 1
          ? ReaderScreen(book: book)
          : ChapterListScreen(source: source),
    ));
  }

  Future<void> _reopenFromLibrary(LibraryEntry entry) async {
    setState(() {
      _error = null;
      _isOpening = true;
    });
    try {
      final file = File(entry.path);
      if (!await file.exists()) {
        setState(() {
          _error = 'Arquivo não encontrado mais nesse caminho: ${entry.path}';
          _isOpening = false;
        });
        return;
      }
      final bytes = await file.readAsBytes();
      final source = await _parseByExtension(bytes, entry.path.split('/').last);
      setState(() => _isOpening = false);
      _openSource(source);
    } catch (e) {
      setState(() => _isOpening = false);
      if (mounted) _showErrorDialog(e.toString());
    }
  }

  Future<void> _removeFromLibrary(LibraryEntry entry) async {
    await _config?.removeFromLibrary(entry.bookId);
    await _loadLibrary();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NovelAI Reader'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Configurações',
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SettingsScreen(),
              ));
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isOpening) const LinearProgressIndicator(minHeight: 3),
          if (_error != null)
            Container(
              width: double.infinity,
              color: Colors.red.withOpacity(0.15),
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          Expanded(
            child: _library.isEmpty ? _buildEmptyState() : _buildLibraryGrid(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isOpening ? null : _openBook,
        icon: const Icon(Icons.menu_book_outlined),
        label: const Text('Abrir livro'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_books_outlined,
              size: 72,
              color: AppPalette.text.withOpacity(0.35),
            ),
            const SizedBox(height: 16),
            Text('Nenhum livro ainda', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Toque em "Abrir livro" para adicionar seu primeiro EPUB.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppPalette.text.withOpacity(0.6)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLibraryGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.62,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _library.length,
      itemBuilder: (context, index) {
        final book = _library[index];
        return GestureDetector(
          onTap: () => _reopenFromLibrary(book),
          onLongPress: () => _confirmRemove(book),
          child: Card(
            color: AppPalette.surface,
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Container(
                    color: AppPalette.accentDark,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      book.title,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text(
                    book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _confirmRemove(LibraryEntry entry) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover da biblioteca?'),
        content: Text(entry.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _removeFromLibrary(entry);
            },
            child: const Text('Remover'),
          ),
        ],
      ),
    );
  }
}
