/// Heurística de divisão de capítulos em texto puro (sem estrutura
/// de EPUB pra guiar), compartilhada entre o parser de .txt e o de
/// .pdf: procura cabeçalhos reconhecíveis ("Capítulo 12", "Chapter
/// 5", "Prólogo"…) e, se não achar o suficiente, cai pra divisão em
/// blocos de tamanho fixo.
library chapter_heuristics;

import '../models/epub_block.dart';
import '../models/raw_chapter_candidate.dart';
import 'style_classifier.dart';

final _numberedHeadingPattern = RegExp(
  r'^\s*(cap[ií]tulo|chapter|cap\.?)\s*[:\-.]?\s*(\d+|[ivxlcdm]+)\b',
  caseSensitive: false,
);

const _bareHeadingWords = {
  'prólogo', 'prologo', 'epílogo', 'epilogo', 'prefácio', 'prefacio',
  'introdução', 'introducao', 'interlúdio', 'interludio', 'extra',
  'apêndice', 'apendice', 'posfácio', 'posfacio',
};

const _paragraphsPerFallbackChunk = 35;

bool looksLikeChapterHeading(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || trimmed.length > 80) return false;
  if (_numberedHeadingPattern.hasMatch(trimmed)) return true;
  return _bareHeadingWords.contains(trimmed.toLowerCase());
}

List<EpubBlock> blocksFromParagraphs(List<String> paragraphs) {
  return paragraphs
      .where((p) => p.trim().isNotEmpty)
      .map((p) => EpubBlock.text(p.trim(), style: classifyStyle(p.trim())))
      .toList();
}

/// Divide um texto puro inteiro (sem marcação de EPUB) em candidatos
/// a capítulo. [hrefPrefix] só precisa ser único por arquivo (vira o
/// "href" estável do capítulo, usado pra lembrar overrides manuais).
List<RawChapterCandidate> splitPlainTextIntoCandidates(String content, String hrefPrefix) {
  final lines = content.split(RegExp(r'\r\n|\r|\n'));
  final headingLineIndexes = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (looksLikeChapterHeading(lines[i])) headingLineIndexes.add(i);
  }

  final candidates = <RawChapterCandidate>[];

  if (headingLineIndexes.length >= 2) {
    for (var h = 0; h < headingLineIndexes.length; h++) {
      final start = headingLineIndexes[h];
      final end = h + 1 < headingLineIndexes.length ? headingLineIndexes[h + 1] : lines.length;
      final title = lines[start].trim();
      final bodyLines = lines.sublist(start + 1, end).join('\n');
      final paragraphs = bodyLines.split(RegExp(r'\n\s*\n+'));
      final blocks = blocksFromParagraphs(paragraphs);
      if (blocks.isEmpty) continue;
      candidates.add(RawChapterCandidate(
        href: '${hrefPrefix}_$start',
        title: title,
        blocks: blocks,
        autoFrontMatter: false,
      ));
    }
  } else {
    final allParagraphs = content.split(RegExp(r'\n\s*\n+')).where((p) => p.trim().isNotEmpty).toList();
    var chunkIndex = 0;
    for (var i = 0; i < allParagraphs.length; i += _paragraphsPerFallbackChunk) {
      final end = (i + _paragraphsPerFallbackChunk < allParagraphs.length)
          ? i + _paragraphsPerFallbackChunk
          : allParagraphs.length;
      final blocks = blocksFromParagraphs(allParagraphs.sublist(i, end));
      if (blocks.isEmpty) continue;
      candidates.add(RawChapterCandidate(
        href: '${hrefPrefix}_$i',
        title: 'Parte ${chunkIndex + 1}',
        blocks: blocks,
        autoFrontMatter: false,
      ));
      chunkIndex++;
    }
  }

  return candidates;
}
