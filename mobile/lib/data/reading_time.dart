import '../models/epub_chapter.dart';

/// Estima o tempo de leitura de um capítulo pela contagem de
/// palavras dos parágrafos, dividida pelo `reading_wpm` configurado.
int estimateReadingMinutes(EpubChapterData chapter, int wpm) {
  if (wpm <= 0) return 0;
  var wordCount = 0;
  for (final paragraph in chapter.paragraphs) {
    if (paragraph.trim().isEmpty) continue;
    wordCount += paragraph.trim().split(RegExp(r'\s+')).length;
  }
  final minutes = (wordCount / wpm).ceil();
  return minutes < 1 ? 1 : minutes;
}
