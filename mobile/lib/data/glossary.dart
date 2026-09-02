/// Fixa a tradução de nomes próprios/termos específicos de uma
/// novel, pra tradução automática não ficar inconsistente entre
/// capítulos. Troca cada termo por um marcador ALFANUMÉRICO antes de
/// traduzir (símbolos exóticos às vezes são alterados pelo próprio
/// tradutor) e restaura o valor definido no glossário depois —
/// comparação sempre case-insensitive.
library glossary;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class Glossary {
  Map<String, String> terms = {};
  late File _file;
  bool _loaded = false;

  Future<void> load() async {
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/glossario.json');
    if (await _file.exists()) {
      try {
        final content = await _file.readAsString();
        final decoded = json.decode(content) as Map<String, dynamic>;
        terms = decoded.map((k, v) => MapEntry(k, v as String));
      } catch (_) {
        terms = {};
      }
    }
    _loaded = true;
  }

  Future<void> _save() async {
    await _file.writeAsString(json.encode(terms));
  }

  Future<void> addTerm(String original, String translated) async {
    if (!_loaded) await load();
    terms[original] = translated;
    await _save();
  }

  Future<void> removeTerm(String original) async {
    if (!_loaded) await load();
    terms.remove(original);
    await _save();
  }

  /// Sugere possíveis nomes próprios: palavras capitalizadas repetidas
  /// no MEIO de uma frase (não no início, onde toda palavra vem
  /// maiúscula por gramática mesmo sem ser nome próprio).
  List<String> suggestTerms(List<String> paragraphs, {int minOccurrences = 2, int maxSuggestions = 40}) {
    final counts = <String, int>{};
    for (final paragraph in paragraphs) {
      final words = paragraph.split(RegExp(r'\s+'));
      for (var i = 0; i < words.length; i++) {
        final cleaned = words[i].replaceAll(RegExp(r'^[^\w]+|[^\w]+$', unicode: true), '');
        if (cleaned.isEmpty || i == 0 || cleaned.length < 3) continue;
        final firstChar = cleaned[0];
        if (firstChar != firstChar.toUpperCase() || cleaned == cleaned.toUpperCase()) continue;
        counts[cleaned] = (counts[cleaned] ?? 0) + 1;
      }
    }
    final alreadyKnown = terms.keys.map((k) => k.toLowerCase()).toSet();
    final candidates = counts.entries
        .where((e) => e.value >= minOccurrences && !alreadyKnown.contains(e.key.toLowerCase()))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return candidates.take(maxSuggestions).map((e) => e.key).toList();
  }

  (String, Map<String, String>) protect(String text) {
    final placeholders = <String, String>{};
    var protectedText = text;
    var i = 0;
    for (final entry in terms.entries) {
      final pattern = RegExp(RegExp.escape(entry.key), caseSensitive: false);
      if (pattern.hasMatch(protectedText)) {
        final marker = 'XPROTECT${i}X';
        placeholders[marker] = entry.value;
        protectedText = protectedText.replaceAll(pattern, marker);
      }
      i++;
    }
    return (protectedText, placeholders);
  }

  String restore(String text, Map<String, String> placeholders) {
    var restored = text;
    for (final entry in placeholders.entries) {
      final pattern = RegExp(RegExp.escape(entry.key), caseSensitive: false);
      restored = restored.replaceAll(pattern, entry.value);
    }
    return restored;
  }
}
