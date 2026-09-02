import 'dart:typed_data';

/// Um pedaço de conteúdo do capítulo, na ordem em que aparece no livro.
class EpubBlock {
  final String kind; // "text" ou "image"
  final String text;
  final Uint8List? image;
  final String style; // "narration" | "highlighted" | "italic"

  const EpubBlock.text(this.text, {this.style = 'narration'})
      : kind = 'text',
        image = null;

  const EpubBlock.image(this.image)
      : kind = 'image',
        text = '',
        style = 'narration';
}
