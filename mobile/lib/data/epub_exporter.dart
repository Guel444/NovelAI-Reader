/// Monta um EPUB3 novo a partir dos capítulos já traduzidos (mantendo
/// as imagens originais).
///
/// Nota de compatibilidade: o `mimetype` sai com o mesmo nível de
/// compressão do resto do zip. A especificação EPUB pede ele sem
/// compressão; a maioria dos leitores tolera, mas é o primeiro lugar
/// a ajustar se algum leitor específico recusar o arquivo.
library epub_exporter;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/parsed_book.dart';

String _xmlEscape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _imageExtFor(Uint8List bytes) {
  if (bytes.length >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50) return 'png';
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpg';
  if (bytes.length >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49) return 'gif';
  return 'jpg';
}

/// Monta o EPUB traduzido em memória e devolve os bytes prontos pra
/// salvar em disco. [translatedParagraphsByChapter] é indexado pelo
/// MESMO índice de `book.chapters` — capítulos ausentes do mapa saem
/// no idioma original.
Uint8List buildTranslatedEpub(
  ParsedBook book,
  Map<int, List<String>> translatedParagraphsByChapter, {
  required String targetLang,
}) {
  final archive = Archive();

  void addTextFile(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  // mimetype (deve ser o primeiro arquivo do zip)
  final mimetypeBytes = utf8.encode('application/epub+zip');
  archive.addFile(ArchiveFile('mimetype', mimetypeBytes.length, mimetypeBytes));

  // META-INF/container.xml
  addTextFile('META-INF/container.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');

  // imagens: coleta todas as imagens de todos os capítulos, gerando
  // nomes estáveis (img_<capítulo>_<posição>.<ext>)
  final imageManifestEntries = <String>[]; // linhas <item .../> do manifest
  final chapterImageRefs = <int, List<String>>{}; // índice do capítulo -> [nomes de arquivo, na ordem dos blocos de imagem]

  for (final chapter in book.chapters) {
    final refs = <String>[];
    var imgCounter = 0;
    for (final block in chapter.blocks) {
      if (block.kind != 'image' || block.image == null) continue;
      final ext = _imageExtFor(block.image!);
      final fileName = 'images/img_${chapter.index}_$imgCounter.$ext';
      archive.addFile(ArchiveFile('OEBPS/$fileName', block.image!.length, block.image!));
      final mediaType = ext == 'png' ? 'image/png' : (ext == 'gif' ? 'image/gif' : 'image/jpeg');
      imageManifestEntries.add(
        '<item id="img_${chapter.index}_$imgCounter" href="$fileName" media-type="$mediaType"/>',
      );
      refs.add(fileName);
      imgCounter++;
    }
    chapterImageRefs[chapter.index] = refs;
  }

  // capítulos: um .xhtml por capítulo
  final manifestChapterItems = <String>[];
  final spineItems = <String>[];
  final navPoints = <String>[];

  for (final chapter in book.chapters) {
    final translated = translatedParagraphsByChapter[chapter.index];
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln(
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>${_xmlEscape(chapter.title)}</title>'
      '<meta charset="utf-8"/></head><body>',
    );
    buffer.writeln('<h1>${_xmlEscape(chapter.title)}</h1>');

    var textIndex = 0;
    var imgIndex = 0;
    final imageRefs = chapterImageRefs[chapter.index] ?? const [];
    for (final block in chapter.blocks) {
      if (block.kind == 'image') {
        if (imgIndex < imageRefs.length) {
          buffer.writeln('<p><img src="${imageRefs[imgIndex]}" alt=""/></p>');
          imgIndex++;
        }
        continue;
      }
      final text = (translated != null && textIndex < translated.length)
          ? translated[textIndex]
          : block.text;
      textIndex++;
      final escaped = _xmlEscape(text);
      switch (block.style) {
        case 'highlighted':
          buffer.writeln('<p style="text-align:center;font-weight:bold;font-style:italic;">$escaped</p>');
          break;
        case 'italic':
          buffer.writeln('<p><em>$escaped</em></p>');
          break;
        default:
          buffer.writeln('<p>$escaped</p>');
      }
    }
    buffer.writeln('</body></html>');

    final fileName = 'chapter_${chapter.index}.xhtml';
    addTextFile('OEBPS/$fileName', buffer.toString());
    manifestChapterItems.add('<item id="chap_${chapter.index}" href="$fileName" media-type="application/xhtml+xml"/>');
    spineItems.add('<itemref idref="chap_${chapter.index}"/>');
    navPoints.add('<li><a href="$fileName">${_xmlEscape(chapter.title)}</a></li>');
  }

  // nav.xhtml (sumário EPUB3)
  addTextFile('OEBPS/nav.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Sumário</title><meta charset="utf-8"/></head>
<body>
<nav epub:type="toc" id="toc">
<h1>Sumário</h1>
<ol>
${navPoints.join('\n')}
</ol>
</nav>
</body>
</html>
''');

  final safeTitle = _xmlEscape(book.title);
  final safeAuthor = _xmlEscape(book.author.isNotEmpty ? book.author : 'Desconhecido');

  // content.opf
  addTextFile('OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:${book.bookId}</dc:identifier>
    <dc:title>$safeTitle</dc:title>
    <dc:creator>$safeAuthor</dc:creator>
    <dc:language>$targetLang</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    ${manifestChapterItems.join('\n    ')}
    ${imageManifestEntries.join('\n    ')}
  </manifest>
  <spine>
    ${spineItems.join('\n    ')}
  </spine>
</package>
''');

  final zipBytes = ZipEncoder().encode(archive);
  return Uint8List.fromList(zipBytes!);
}
