import 'package:flutter/material.dart';

import '../data/glossary.dart';
import '../theme/app_theme.dart';

/// Wiki de personagens, gerada a partir do glossário. É
/// deliberadamente só leitura; editar termos continua sendo função
/// da tela de Glossário.
class WikiScreen extends StatefulWidget {
  const WikiScreen({super.key});

  @override
  State<WikiScreen> createState() => _WikiScreenState();
}

class _WikiScreenState extends State<WikiScreen> {
  final Glossary _glossary = Glossary();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _glossary.load().then((_) => setState(() => _loading = false));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final entries = _glossary.terms.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    return Scaffold(
      appBar: AppBar(title: const Text('Wiki de personagens')),
      body: entries.isEmpty
          ? Center(
              child: Text(
                'Nenhum termo no glossário ainda.',
                style: TextStyle(color: AppPalette.text.withOpacity(0.6)),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 1.4,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final entry = entries[i];
                return Card(
                  color: AppPalette.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          entry.key,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          entry.value,
                          style: TextStyle(color: AppPalette.text.withOpacity(0.7), fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
