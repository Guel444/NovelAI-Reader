import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Cartão visual de um grifo. Formato quadrado (bom pra compartilhar
/// em qualquer rede), fundo escuro com borda de destaque, aspas
/// grandes, o trecho grifado, o comentário (se houver) e a
/// atribuição livro/capítulo.
class HighlightCard extends StatelessWidget {
  final String text;
  final String comment;
  final String bookTitle;
  final String chapterTitle;

  const HighlightCard({
    super.key,
    required this.text,
    required this.bookTitle,
    required this.chapterTitle,
    this.comment = '',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 360,
      height: 360,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppPalette.bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppPalette.accent.withOpacity(0.6), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '“',
            style: TextStyle(
              color: AppPalette.accent.withOpacity(0.8),
              fontSize: 48,
              height: 0.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          Flexible(
            child: Text(
              text,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppPalette.text,
                fontSize: 17,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          if (comment.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              comment,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppPalette.text.withOpacity(0.7), fontSize: 13),
            ),
          ],
          const SizedBox(height: 20),
          Container(height: 1, color: AppPalette.accent.withOpacity(0.3)),
          const SizedBox(height: 10),
          Text(
            bookTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppPalette.accent, fontSize: 12, fontWeight: FontWeight.bold),
          ),
          Text(
            chapterTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppPalette.text.withOpacity(0.5), fontSize: 11),
          ),
        ],
      ),
    );
  }
}
