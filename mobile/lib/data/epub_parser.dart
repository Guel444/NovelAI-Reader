/// Parser de EPUB: abre o arquivo como zip, lê container.xml e o
/// .opf pra montar spine/manifest/guide, e extrai parágrafos e
/// imagens de cada capítulo. Filtra front-matter (capa, índice,
/// copyright...) por 3 sinais: item não-linear no spine, tipo do
/// item no <guide>, e título/conteúdo batendo com palavra-chave.
library epub_parser;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../models/epub_block.dart';
import '../models/epub_chapter.dart';
import '../models/parsed_book.dart';
import '../models/parsed_book_source.dart';
import '../models/raw_chapter_candidate.dart';
import 'style_classifier.dart';

const _textTags = ['p', 'h1', 'h2', 'h3', 'h4', 'blockquote', 'li'];
const _blockTags = [..._textTags, 'img', 'image'];

const _guideSkipTypes = {
  'cover', 'toc', 'title-page', 'titlepage', 'copyright-page',
  'copyright', 'dedication', 'epigraph', 'foreword', 'preface',
  'loi', 'lot', 'notes', 'bibliography', 'glossary', 'index',
  'colophon', 'acknowledgements',
};

const _frontMatterKeywords = [
  'índice', 'indice', 'sumário', 'sumario', 'copyright',
  'direitos autorais', 'informações', 'informacoes',
  'table of contents', 'contents', 'title page', 'folha de rosto',
  'sobre este livro', 'sobre esta obra', 'ficha catalográfica',
];
const _frontMatterMaxParagraphs = 8;

class EpubParseException implements Exception {
  final String message;
  EpubParseException(this.message);
  @override
  String toString() => message;
}

/// Um item candidato a capítulo, antes de decidir se é front-matter.
class _RawEntry {
  final String href;
  final String? title;
  final List<EpubBlock> blocks;
  final bool autoFrontMatter;
  _RawEntry({
    required this.href,
    required this.title,
    required this.blocks,
    required this.autoFrontMatter,
  });
}

/// ---------- utilitários de caminho estilo posix (paths de zip) ----------

String _posixNormalize(String path) {
  final parts = path.split('/');
  final result = <String>[];
  for (final part in parts) {
    if (part == '.' || part.isEmpty) continue;
    if (part == '..') {
      if (result.isNotEmpty) result.removeLast();
    } else {
      result.add(part);
    }
  }
  return result.join('/');
}

String _posixJoin(String base, String rel) {
  if (rel.startsWith('/')) return _posixNormalize(rel.substring(1));
  final combined = base.isEmpty ? rel : '$base/$rel';
  return _posixNormalize(combined);
}

String _posixDirname(String path) {
  final idx = path.lastIndexOf('/');
  return idx == -1 ? '' : path.substring(0, idx);
}

String _stripFragment(String href) => href.split('#').first;

class EpubParser {
  /// Faz o parsing completo de um arquivo EPUB a partir dos bytes.
  /// Devolve TODOS os candidatos a capítulo (inclusive os que a
  /// heurística automática já marcaria como front-matter) — quem
  /// decide o filtro final é `buildParsedBook`, pra dar espaço a
  /// correção manual sem reabrir o arquivo.
  static Future<ParsedBookSource> parse(Uint8List bytes, String sourcePath) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final filesByName = <String, ArchiveFile>{
      for (final f in archive.files) f.name: f,
    };

    // 1. container.xml -> caminho do .opf
    final containerFile = filesByName['META-INF/container.xml'];
    if (containerFile == null) {
      throw EpubParseException('Arquivo EPUB inválido: container.xml não encontrado.');
    }
    final containerXml = XmlDocument.parse(
      utf8.decode(containerFile.content as List<int>, allowMalformed: true),
    );
    final rootfileEl = containerXml.descendants
        .whereType<XmlElement>()
        .firstWhere((e) => e.name.local == 'rootfile');
    final opfPath = rootfileEl.getAttribute('full-path')!;
    final opfDir = _posixDirname(opfPath);

    final opfFile = filesByName[opfPath];
    if (opfFile == null) {
      throw EpubParseException('Arquivo EPUB inválido: .opf não encontrado ($opfPath).');
    }
    final opfXml = XmlDocument.parse(
      utf8.decode(opfFile.content as List<int>, allowMalformed: true),
    );

    // 2. metadados (título, autor)
    String title = sourcePath.split('/').last.replaceAll(RegExp(r'\.epub$', caseSensitive: false), '');
    String author = '';
    final metadataEl = opfXml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'metadata')
        .firstOrNull;
    if (metadataEl != null) {
      final titleEl = metadataEl.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'title')
          .firstOrNull;
      if (titleEl != null && titleEl.innerText.trim().isNotEmpty) {
        title = titleEl.innerText.trim();
      }
      final creatorEl = metadataEl.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'creator')
          .firstOrNull;
      if (creatorEl != null) {
        author = creatorEl.innerText.trim();
      }
    }

    // 3. manifest: id -> {href, mediaType, properties}
    final manifestItems = opfXml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'item');
    final idToHref = <String, String>{};
    final idToProperties = <String, String>{};
    final idToMediaType = <String, String>{};
    for (final item in manifestItems) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      final resolved = _posixJoin(opfDir, href);
      idToHref[id] = resolved;
      idToProperties[id] = item.getAttribute('properties') ?? '';
      idToMediaType[id] = item.getAttribute('media-type') ?? '';
    }

    // 4. spine: ordem real de leitura, pulando itens não-lineares
    final spineItemRefs = opfXml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'itemref');
    final spineHrefsInOrder = <String>[];
    for (final ref in spineItemRefs) {
      final linear = ref.getAttribute('linear');
      if (linear == 'no') continue;
      final idref = ref.getAttribute('idref');
      if (idref == null) continue;
      final href = idToHref[idref];
      if (href == null) continue;
      final properties = idToProperties[idref] ?? '';
      if (properties.contains('nav')) continue; // nav do EPUB3 nunca é capítulo
      if (href.toLowerCase().contains('nav')) continue;
      spineHrefsInOrder.add(href);
    }

    // 5. guide: hrefs marcados como capa/toc/rosto/etc.
    final guideSkipHrefs = <String>{};
    final guideRefs = opfXml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'reference');
    for (final ref in guideRefs) {
      final type = (ref.getAttribute('type') ?? '').toLowerCase();
      final href = ref.getAttribute('href');
      if (href == null) continue;
      if (_guideSkipTypes.contains(type)) {
        guideSkipHrefs.add(_stripFragment(_posixJoin(opfDir, href)));
      }
    }

    // 6. monta os candidatos a capítulo, na ordem do spine
    final rawEntries = <_RawEntry>[];
    for (final href in spineHrefsInOrder) {
      final file = filesByName[href];
      if (file == null) continue; // referência quebrada, ignora

      String htmlContent;
      try {
        htmlContent = utf8.decode(file.content as List<int>, allowMalformed: true);
      } catch (_) {
        continue;
      }

      final document = html_parser.parse(htmlContent);
      final blocks = _extractBlocks(document, href, filesByName);
      final textBlocks = blocks.where((b) => b.kind == 'text').toList();
      if (textBlocks.isEmpty) continue; // página sem texto (ex.: só capa)

      final guessedTitle = _guessTitle(document);
      final autoFrontMatter = guideSkipHrefs.contains(href) ||
          _looksLikeFrontMatter(guessedTitle ?? '', textBlocks);

      rawEntries.add(_RawEntry(
        href: href,
        title: guessedTitle,
        blocks: blocks,
        autoFrontMatter: autoFrontMatter,
      ));
    }

    // 7. capa
    final coverBytes = _extractCover(opfXml, idToHref, idToProperties, filesByName);

    final bookId = sha1.convert(utf8.encode(sourcePath.split('/').last)).toString().substring(0, 12);

    final candidates = rawEntries
        .map((e) => RawChapterCandidate(
              href: e.href,
              title: e.title,
              blocks: e.blocks,
              autoFrontMatter: e.autoFrontMatter,
            ))
        .toList();

    return ParsedBookSource(
      bookId: bookId,
      path: sourcePath,
      title: title,
      author: author,
      coverBytes: coverBytes,
      candidates: candidates,
    );
  }

  static List<EpubBlock> _extractBlocks(
    dom.Document document,
    String chapterHref,
    Map<String, ArchiveFile> filesByName,
  ) {
    final body = document.body ?? document.documentElement;
    if (body == null) return [];

    final elements = body.querySelectorAll(_blockTags.join(', '));
    final blocks = <EpubBlock>[];
    final chapterDir = _posixDirname(chapterHref);

    for (final el in elements) {
      final tag = el.localName ?? '';

      if (tag == 'img' || tag == 'image') {
        final src = el.attributes['src'] ??
            el.attributes['xlink:href'] ??
            el.attributes['href'];
        if (src == null) continue;
        final resolved = _posixNormalize(_posixJoin(chapterDir, src));
        final srcBasename = src.split('/').last;
        final imgFile = filesByName[resolved] ??
            filesByName.values.firstWhereOrNull((f) => f.name.split('/').last == srcBasename);
        if (imgFile == null) continue;
        blocks.add(EpubBlock.image(Uint8List.fromList(imgFile.content as List<int>)));
        continue;
      }

      // ignora bloco que só engloba outro bloco de texto já capturado
      final hasNestedTextTag =
          _textTags.any((t) => el.querySelector(t) != null);
      if (hasNestedTextTag) continue;

      final text = el.text.trim();
      if (text.isEmpty) continue;

      var effectiveTag = tag;
      if (effectiveTag != 'em' && effectiveTag != 'i') {
        // texto inteiro embrulhado num <em>/<i> interno — comum em
        // "pensamentos" marcados em itálico dentro de um <p>
        final emChild = el.querySelector('em, i');
        if (emChild != null && emChild.text.trim() == text) {
          effectiveTag = emChild.localName ?? effectiveTag;
        }
      }

      blocks.add(EpubBlock.text(
        text,
        style: classifyStyle(text, originalTag: effectiveTag),
      ));
    }
    return blocks;
  }

  static String? _guessTitle(dom.Document document) {
    for (final tag in ['h1', 'h2', 'title']) {
      final found = document.querySelector(tag);
      final text = found?.text.trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  static bool _looksLikeFrontMatter(String title, List<EpubBlock> textBlocks) {
    if (textBlocks.length > _frontMatterMaxParagraphs) return false;
    final preview = textBlocks.take(3).map((b) => b.text.toLowerCase()).join(' ');
    final haystack = '${title.toLowerCase()} $preview';
    return _frontMatterKeywords.any((kw) => haystack.contains(kw));
  }

  static Uint8List? _extractCover(
    XmlDocument opfXml,
    Map<String, String> idToHref,
    Map<String, String> idToProperties,
    Map<String, ArchiveFile> filesByName,
  ) {
    // EPUB3: item de manifesto com properties="cover-image"
    for (final entry in idToProperties.entries) {
      if (entry.value.contains('cover-image')) {
        final file = filesByName[idToHref[entry.key]];
        if (file != null) return Uint8List.fromList(file.content as List<int>);
      }
    }
    // EPUB2: <meta name="cover" content="ID_DO_MANIFESTO">
    final metaEls = opfXml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'meta' && e.getAttribute('name') == 'cover');
    for (final meta in metaEls) {
      final coverId = meta.getAttribute('content');
      final href = coverId != null ? idToHref[coverId] : null;
      final file = href != null ? filesByName[href] : null;
      if (file != null) return Uint8List.fromList(file.content as List<int>);
    }
    // Fallback: qualquer imagem cujo caminho contenha "cover"
    for (final href in idToHref.values) {
      if (href.toLowerCase().contains('cover')) {
        final file = filesByName[href];
        if (file != null) return Uint8List.fromList(file.content as List<int>);
      }
    }
    return null;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;

  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}

/// Aplica o filtro final de capítulos sobre um [ParsedBookSource].
/// [manualOverrides] é um mapa href -> "está excluído?" definido pelo
/// usuário no gerenciador de capítulos: um href presente nele SEMPRE
/// vence a heurística automática (em qualquer direção — dá pra forçar
/// incluir algo que a heurística descartou, ou excluir algo que ela
/// manteve). Hrefs ausentes usam o resultado automático
/// (`autoFrontMatter`). Numera pela posição FINAL, depois de decidir
/// o conjunto completo (nunca numerar antes de filtrar).
ParsedBook buildParsedBook(ParsedBookSource source, Map<String, bool> manualOverrides) {
  final chapters = <EpubChapterData>[];
  var index = 0;
  for (final candidate in source.candidates) {
    final isExcluded = manualOverrides[candidate.href] ?? candidate.autoFrontMatter;
    if (isExcluded) continue;
    final chapterTitle = (candidate.title != null && candidate.title!.trim().isNotEmpty)
        ? candidate.title!
        : 'Capítulo ${index + 1}';
    chapters.add(EpubChapterData(
      index: index,
      title: chapterTitle,
      blocks: candidate.blocks,
      href: candidate.href,
    ));
    index++;
  }
  return ParsedBook(
    bookId: source.bookId,
    path: source.path,
    title: source.title,
    author: source.author,
    coverBytes: source.coverBytes,
    chapters: chapters,
  );
}
