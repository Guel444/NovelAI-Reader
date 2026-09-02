/// Leitura de .pdf como livro, devolvendo o mesmo formato
/// (`ParsedBookSource`) do parser de EPUB. Extrai o texto puro de
/// cada página via Syncfusion PDF e reaproveita a heurística de
/// divisão de capítulos do parser de .txt, já que PDF não tem
/// estrutura de capítulo garantida.
///
/// Exige registrar uma chave de licença gratuita da Syncfusion —
/// veja lib/services/syncfusion_license.dart.
library pdf_parser;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/parsed_book_source.dart';
import 'chapter_heuristics.dart';

class PdfParseException implements Exception {
  final String message;
  PdfParseException(this.message);
  @override
  String toString() => message;
}

const _friendlyConversionTip =
    'Isso costuma acontecer quando o PDF usa uma fonte incorporada sem '
    'mapeamento de caracteres — nenhuma biblioteca de PDF consegue extrair '
    'o texto certo nesses casos, mesmo quando o PDF abre normal num leitor '
    'comum. O jeito de contornar é converter esse PDF pra EPUB antes (o '
    'Calibre, programa gratuito, faz isso em "Converter livros") e abrir o '
    'EPUB resultante aqui no app.';

final _letterPattern = RegExp(r'\p{L}', unicode: true);

/// Proporção de caracteres que são letras "de verdade" (qualquer
/// alfabeto) sobre o total sem espaço em branco. Texto legível fica
/// bem acima de 0.5; texto com mapeamento de fonte quebrado (glifos
/// sem correspondência Unicode real) fica bem abaixo disso.
double _letterRatio(String text) {
  final nonBlank = text.replaceAll(RegExp(r'\s'), '');
  if (nonBlank.isEmpty) return 0;
  final letterCount = _letterPattern.allMatches(nonBlank).length;
  return letterCount / nonBlank.length;
}

final _sentenceEndPattern = RegExp(r'[.!?…”"»」』]\s*$');
final _wrapHyphenPattern = RegExp(r'\p{Ll}-$', unicode: true);

/// Reconstrói parágrafos a partir do texto de uma página de PDF, que
/// vem com uma quebra de linha a cada linha VISUAL (por causa da
/// largura da página), não uma quebra de linha por parágrafo. Junta
/// linhas seguidas até achar uma que termine em pontuação de fim de
/// frase — aí sim considera que o parágrafo acabou. Também corrige
/// hifenização de fim de linha (ex.: "cami-\nnho" → "caminho").
String _reflowPdfPageText(String pageText) {
  final lines = pageText.split('\n').map((l) => l.trim()).toList();
  final paragraphs = <String>[];
  final current = StringBuffer();

  void flush() {
    final text = current.toString().trim();
    if (text.isNotEmpty) paragraphs.add(text);
    current.clear();
  }

  for (final line in lines) {
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (looksLikeChapterHeading(line)) {
      flush();
      paragraphs.add(line);
      continue;
    }
    if (current.isEmpty) {
      current.write(line);
    } else {
      final soFar = current.toString();
      if (_wrapHyphenPattern.hasMatch(soFar)) {
        current
          ..clear()
          ..write(soFar.substring(0, soFar.length - 1) + line);
      } else {
        current.write(' $line');
      }
    }
    if (_sentenceEndPattern.hasMatch(line)) flush();
  }
  flush();

  return paragraphs.join('\n\n');
}

class PdfParser {
  static Future<ParsedBookSource> parse(Uint8List bytes, String sourcePath) async {
    late PdfDocument document;
    try {
      document = PdfDocument(inputBytes: bytes);
    } catch (e) {
      throw PdfParseException('Não consegui abrir o PDF (arquivo corrompido ou protegido?): $e');
    }

    final buffer = StringBuffer();
    var pageCount = 0;
    try {
      final extractor = PdfTextExtractor(document);
      pageCount = document.pages.count;
      for (var i = 0; i < pageCount; i++) {
        final pageText = extractor.extractText(startPageIndex: i, endPageIndex: i);
        buffer.writeln(_reflowPdfPageText(pageText));
        buffer.writeln(); // separador extra entre páginas
      }
    } finally {
      document.dispose();
    }

    final content = buffer.toString();
    if (content.trim().isEmpty) {
      throw PdfParseException(
        'Não encontrei texto extraível neste PDF ($pageCount página(s) lida(s), '
        'nenhuma com texto). $_friendlyConversionTip',
      );
    }

    if (_letterRatio(content) < 0.4) {
      throw PdfParseException(
        'Extraí texto deste PDF, mas ele saiu ilegível (símbolos sem sentido '
        'em vez de letras). $_friendlyConversionTip',
      );
    }

    final fileName = sourcePath.split('/').last;
    final candidates = splitPlainTextIntoCandidates(content, 'pdf_chunk');
    final title = fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    final bookId = sha1.convert(utf8.encode(fileName)).toString().substring(0, 12);

    if (candidates.isEmpty) {
      throw PdfParseException(
        'Extraí texto do PDF ($pageCount página(s)), mas não consegui organizar '
        'em parágrafos (formatação incomum). Isso é um caso pra ajustar a '
        'heurística de divisão — avise sobre esse arquivo.',
      );
    }

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
