import 'epub_block.dart';

/// Um item do spine do EPUB, ANTES da decisão final de "isso é
/// capítulo ou é front-matter". Exposto pra tela de gerenciamento
/// manual de capítulos poder mostrar tudo e deixar o usuário
/// corrigir a heurística automática.
class RawChapterCandidate {
  final String href; // id estável — usado tanto pra numerar quanto pra excluir manualmente
  final String? title;
  final List<EpubBlock> blocks;
  final bool autoFrontMatter; // true = a heurística automática descartaria isso

  const RawChapterCandidate({
    required this.href,
    required this.title,
    required this.blocks,
    required this.autoFrontMatter,
  });

  List<String> get paragraphs =>
      blocks.where((b) => b.kind == 'text').map((b) => b.text).toList();

  String get displayTitle => (title != null && title!.trim().isNotEmpty) ? title! : href;
}
