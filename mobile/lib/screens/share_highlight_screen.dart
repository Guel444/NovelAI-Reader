import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../theme/app_theme.dart';
import '../widgets/highlight_card.dart';

/// Renderiza o cartão de grifo como widget normal e "fotografa" ele
/// via RepaintBoundary, gerando um PNG pra compartilhar.
class ShareHighlightScreen extends StatefulWidget {
  final String text;
  final String comment;
  final String bookTitle;
  final String chapterTitle;

  const ShareHighlightScreen({
    super.key,
    required this.text,
    required this.bookTitle,
    required this.chapterTitle,
    this.comment = '',
  });

  @override
  State<ShareHighlightScreen> createState() => _ShareHighlightScreenState();
}

class _ShareHighlightScreenState extends State<ShareHighlightScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _sharing = false;
  String? _error;

  Future<void> _share() async {
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      // pequena espera garante que o primeiro frame do cartão já
      // esteja pintado antes de capturar
      await Future.delayed(const Duration(milliseconds: 50));
      final boundary = _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) throw Exception('Não consegui gerar a imagem.');

      final bytes = byteData.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/grifo_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);

      await Share.shareXFiles([XFile(file.path)], text: widget.bookTitle);
    } catch (e) {
      setState(() => _error = 'Erro ao compartilhar: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compartilhar grifo')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                key: _boundaryKey,
                child: HighlightCard(
                  text: widget.text,
                  comment: widget.comment,
                  bookTitle: widget.bookTitle,
                  chapterTitle: widget.chapterTitle,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _sharing ? null : _share,
        icon: _sharing
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.share),
        label: Text(_sharing ? 'Gerando…' : 'Compartilhar'),
        backgroundColor: AppPalette.accent,
      ),
    );
  }
}
