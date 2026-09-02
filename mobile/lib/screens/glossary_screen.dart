import 'package:flutter/material.dart';

import '../data/glossary.dart';
import '../theme/app_theme.dart';

/// Tela de glossário: ver, adicionar, remover termos e sugerir
/// candidatos. [contextParagraphs], quando fornecido (abrindo a
/// partir de um capítulo), habilita o botão "Sugerir termos" pra
/// esse capítulo.
class GlossaryScreen extends StatefulWidget {
  final List<String>? contextParagraphs;

  const GlossaryScreen({super.key, this.contextParagraphs});

  @override
  State<GlossaryScreen> createState() => _GlossaryScreenState();
}

class _GlossaryScreenState extends State<GlossaryScreen> {
  final Glossary _glossary = Glossary();
  bool _loading = true;
  List<String> _suggestions = [];

  @override
  void initState() {
    super.initState();
    _glossary.load().then((_) => setState(() => _loading = false));
  }

  void _suggest() {
    if (widget.contextParagraphs == null) return;
    setState(() {
      _suggestions = _glossary.suggestTerms(widget.contextParagraphs!);
    });
  }

  Future<void> _openAddDialog({String original = '', String translated = ''}) async {
    final originalController = TextEditingController(text: original);
    final translatedController = TextEditingController(text: translated);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Termo do glossário'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: originalController,
              decoration: const InputDecoration(labelText: 'Termo original'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: translatedController,
              decoration: const InputDecoration(labelText: 'Tradução fixa'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salvar')),
        ],
      ),
    );
    if (result == true &&
        originalController.text.trim().isNotEmpty &&
        translatedController.text.trim().isNotEmpty) {
      await _glossary.addTerm(originalController.text.trim(), translatedController.text.trim());
      setState(() {
        _suggestions.remove(originalController.text.trim());
      });
    }
  }

  Future<void> _removeTerm(String key) async {
    await _glossary.removeTerm(key);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final entries = _glossary.terms.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Glossário'),
        actions: [
          if (widget.contextParagraphs != null)
            IconButton(
              icon: const Icon(Icons.auto_awesome),
              tooltip: 'Sugerir termos deste capítulo',
              onPressed: _suggest,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_suggestions.isNotEmpty) ...[
            Text(
              'Sugestões deste capítulo',
              style: TextStyle(color: AppPalette.text.withOpacity(0.7), fontSize: 13),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _suggestions
                  .map((s) => ActionChip(
                        label: Text(s),
                        onPressed: () => _openAddDialog(original: s),
                      ))
                  .toList(),
            ),
            const Divider(height: 32),
          ],
          Text(
            '${entries.length} termo(s) cadastrado(s)',
            style: TextStyle(color: AppPalette.text.withOpacity(0.7), fontSize: 13),
          ),
          const SizedBox(height: 8),
          ...entries.map((e) => Card(
                color: AppPalette.surface,
                child: ListTile(
                  title: Text(e.key),
                  subtitle: Text('→ ${e.value}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _removeTerm(e.key),
                  ),
                  onTap: () => _openAddDialog(original: e.key, translated: e.value),
                ),
              )),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openAddDialog(),
        child: const Icon(Icons.add),
      ),
    );
  }
}
