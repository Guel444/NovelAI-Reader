import 'dart:typed_data';

import 'raw_chapter_candidate.dart';

/// Tudo que o parser extraiu de um EPUB, antes de aplicar exclusões
/// manuais do usuário. `EpubParser.parse` devolve isso; a tela chama
/// `buildParsedBook` (em epub_parser.dart) com o conjunto de hrefs
/// excluídos manualmente pra chegar no `ParsedBook` final.
class ParsedBookSource {
  final String bookId;
  final String path;
  final String title;
  final String author;
  final Uint8List? coverBytes;
  final List<RawChapterCandidate> candidates;

  const ParsedBookSource({
    required this.bookId,
    required this.path,
    required this.title,
    required this.author,
    required this.coverBytes,
    required this.candidates,
  });
}
