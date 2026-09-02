import 'dart:typed_data';

import 'epub_chapter.dart';

/// Resultado completo de abrir um livro — metadados, capa e todos
/// os capítulos já filtrados (front-matter descartado
/// automaticamente).
class ParsedBook {
  final String bookId; // hash estável do nome do arquivo
  final String path; // caminho do arquivo no dispositivo
  final String title;
  final String author;
  final Uint8List? coverBytes;
  final List<EpubChapterData> chapters;

  const ParsedBook({
    required this.bookId,
    required this.path,
    required this.title,
    required this.author,
    required this.coverBytes,
    required this.chapters,
  });

  int get chapterCount => chapters.length;
}
