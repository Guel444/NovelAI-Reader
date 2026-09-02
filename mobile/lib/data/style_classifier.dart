/// Classifica cada parágrafo em duas categorias visuais:
///
///  - "highlighted": texto entre colchetes especiais (『』「」【】 ou
///    colchete reto [...]) — comum em web novels pra sistema/status
///    ou falas destacadas. Só marca "isso está destacado no
///    original", sem adivinhar quem fala.
///  - "narration": todo o resto — texto corrido normal.
///
/// "italic" é preservado à parte, só quando o próprio EPUB original
/// já marcava o trecho como itálico (tag em/i).
library style_classifier;

const _cornerBrackets = [
  ['『', '』'],
  ['「', '」'],
  ['【', '】'],
];

final _bracketPattern = RegExp(r'^[\[\(<].+[\]\)>]$', dotAll: true);

String classifyStyle(String text, {String originalTag = ''}) {
  final stripped = text.trim();
  if (stripped.isEmpty) return 'narration';

  for (final pair in _cornerBrackets) {
    if (stripped.startsWith(pair[0]) && stripped.endsWith(pair[1])) {
      return 'highlighted';
    }
  }

  if (_bracketPattern.hasMatch(stripped)) {
    return 'highlighted';
  }

  final tag = originalTag.toLowerCase();
  if (tag == 'em' || tag == 'i' || tag == 'cite') {
    return 'italic';
  }

  return 'narration';
}
