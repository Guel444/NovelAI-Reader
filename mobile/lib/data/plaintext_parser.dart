/// Leitura de arquivos .txt como livro, devolvendo o mesmo formato
/// (`ParsedBookSource`) do parser de EPUB. A heurística de divisão
/// em capítulos mora em chapter_heuristics.dart (compartilhada com
/// o parser de PDF).
library plaintext_parser;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/parsed_book_source.dart';
import 'chapter_heuristics.dart';

class TxtParser {
  static Future<ParsedBookSource> parse(Uint8List bytes, String sourcePath) async {
    String content;
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      // fallback pra arquivos que não são UTF-8 de verdade (comum em
      // textos antigos salvos em Latin-1/Windows-1252)
      content = latin1.decode(bytes, allowInvalid: true);
    }

    final fileName = sourcePath.split('/').last;
    final candidates = splitPlainTextIntoCandidates(content, 'txt_chunk');
    final title = fileName.replaceAll(RegExp(r'\.txt$', caseSensitive: false), '');
    final bookId = sha1.convert(utf8.encode(fileName)).toString().substring(0, 12);

    return ParsedBookSource(
      bookId: bookId,
      path: sourcePath,
      title: title,
      author: '',
      coverBytes: null,
      candidates: candidates,
    );
  }
}
