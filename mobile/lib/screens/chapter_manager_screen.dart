import 'package:flutter/material.dart';

import '../models/parsed_book_source.dart';
import '../models/raw_chapter_candidate.dart';
import '../theme/app_theme.dart';

/// Gerenciador manual de capítulos. Mostra TODOS os itens do spine
/// (inclusive os que a heurística automática já descartaria) e
/// deixa o usuário corrigir na mão. Devolve (via Navigator.pop) o
/// novo mapa de overrides — quem chamou esta tela é responsável por
/// salvar em AppConfig e reconstruir o ParsedBook com
/// `buildParsedBook`.
class ChapterManagerScreen extends StatefulWidget {
  final ParsedBookSource source;
  final Map<String, bool> initialOverrides;

  const ChapterManagerScreen({
    super.key,
    required this.source,
    required this.initialOverrides,
  });

  @override
  State<ChapterManagerScreen> createState() => _ChapterManagerScreenState();
}

class _ChapterManagerScreenState extends State<ChapterManagerScreen> {
  late Map<String, bool> _overrides;

  @override
  void initState() {
    super.initState();
    _overrides = Map<String, bool>.from(widget.initialOverrides);
  }

  bool _isIncluded(RawChapterCandidate c) {
    final isExcluded = _overrides[c.href] ?? c.autoFrontMatter;
    return !isExcluded;
  }

  void _toggle(RawChapterCandidate c, bool included) {
    setState(() => _overrides[c.href] = !included);
  }

  void _resetToAutomatic() {
    setState(() => _overrides = {});
  }

  @override
  Widget build(BuildContext context) {
    final includedCount = widget.source.candidates.where(_isIncluded).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gerenciar capítulos'),
        actions: [
          TextButton(
            onPressed: _resetToAutomatic,
            child: const Text('Automático'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: AppPalette.surface,
            child: Text(
              '$includedCount de ${widget.source.candidates.length} itens marcados como capítulo. '
              'Desmarcados ficam de fora da lista de leitura (rosto, índice, copyright…).',
              style: TextStyle(color: AppPalette.text.withOpacity(0.7), fontSize: 12),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: widget.source.candidates.length,
              itemBuilder: (context, i) {
                final candidate = widget.source.candidates[i];
                final included = _isIncluded(candidate);
                return CheckboxListTile(
                  value: included,
                  onChanged: (v) => _toggle(candidate, v ?? false),
                  title: Text(candidate.displayTitle, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    candidate.autoFrontMatter ? 'Detectado como front-matter' : 'Detectado como capítulo',
                    style: TextStyle(color: AppPalette.text.withOpacity(0.5), fontSize: 11),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pop(context, _overrides),
        icon: const Icon(Icons.check),
        label: const Text('Salvar'),
      ),
    );
  }
}
