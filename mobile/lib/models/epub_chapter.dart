import 'epub_block.dart';

/// Um capítulo já resolvido: título + blocos ordenados (texto/imagem).
class EpubChapterData {
  final int index;
  final String title;
  final List<EpubBlock> blocks;
  final String href; // caminho do item dentro do zip — id estável do capítulo

  const EpubChapterData({
    required this.index,
    required this.title,
    required this.blocks,
    required this.href,
  });

  /// Só o texto dos blocos, na ordem — usado pelo tradutor e pelo cache.
  List<String> get paragraphs =>
      blocks.where((b) => b.kind == 'text').map((b) => b.text).toList();
}
