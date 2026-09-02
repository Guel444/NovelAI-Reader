import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../data/app_config.dart';
import '../services/translator_service.dart';
import '../theme/app_theme.dart';

/// Tela de configurações: idioma de destino, fonte, tradução
/// automática, tema por capa, e backup/restaurar.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppConfig? _config;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    AppConfig.load().then((c) => setState(() => _config = c));
  }

  Future<void> _update(String key, dynamic value) async {
    await _config?.set(key, value);
    setState(() {});
  }

  Future<void> _exportBackup() async {
    final config = _config;
    if (config == null) return;
    try {
      final jsonStr = config.exportJson();
      final dir = await getTemporaryDirectory();
      final tmpFile = File('${dir.path}/novelai_reader_backup.json');
      await tmpFile.writeAsString(jsonStr);

      final savedPath = await FilePicker.saveFile(
        fileName: 'novelai_reader_backup.json',
        bytes: utf8.encode(jsonStr),
      );
      setState(() {
        _statusMessage = savedPath != null
            ? 'Backup salvo com sucesso.'
            : 'Backup cancelado.';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Erro ao exportar backup: $e');
    }
  }

  Future<void> _importBackup() async {
    final config = _config;
    if (config == null) return;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (files.isEmpty) return;
      Uint8List? bytes;
      try {
        bytes = await files.single.xFile.readAsBytes();
      } catch (_) {
        bytes = null;
      }
      if (bytes == null) {
        setState(() => _statusMessage = 'Não consegui ler o arquivo de backup.');
        return;
      }
      await config.importJson(utf8.decode(bytes));
      setState(() => _statusMessage = 'Backup restaurado com sucesso.');
    } catch (e) {
      setState(() => _statusMessage = 'Erro ao restaurar backup: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    if (config == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final targetLang = config.get('target_language', 'pt') as String;
    final autoTranslate = config.get('auto_translate', true) as bool;
    final useCoverTheme = config.get('use_cover_theme', true) as bool;
    final fontSize = (config.get('font_size', 15) as num).toDouble();
    final lineSpacing = (config.get('line_spacing', 1.4) as num).toDouble();
    final fontFamily = config.get('font_family', '') as String;
    const fontOptions = <(String value, String label)>[
      ('', 'Padrão do sistema'),
      ('sans-serif', 'Sem serifa'),
      ('serif', 'Serifada'),
      ('monospace', 'Monoespaçada'),
      ('sans-serif-condensed', 'Condensada'),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('Tradução'),
          ListTile(
            title: const Text('Idioma de destino'),
            trailing: DropdownButton<String>(
              value: targetLang,
              underline: const SizedBox(),
              dropdownColor: AppPalette.surface,
              items: supportedLanguages
                  .map((lang) => DropdownMenuItem(value: lang.$1, child: Text(lang.$2)))
                  .toList(),
              onChanged: (v) {
                if (v != null) _update('target_language', v);
              },
            ),
          ),
          SwitchListTile(
            title: const Text('Traduzir automaticamente'),
            subtitle: const Text('Traduz o capítulo ao abrir'),
            value: autoTranslate,
            onChanged: (v) => _update('auto_translate', v),
          ),
          const Divider(height: 32),
          _sectionTitle('Leitura'),
          ListTile(
            title: const Text('Fonte'),
            trailing: DropdownButton<String>(
              value: fontFamily,
              underline: const SizedBox(),
              dropdownColor: AppPalette.surface,
              items: fontOptions
                  .map((f) => DropdownMenuItem(value: f.$1, child: Text(f.$2)))
                  .toList(),
              onChanged: (v) {
                if (v != null) _update('font_family', v);
              },
            ),
          ),
          ListTile(
            title: const Text('Tamanho da fonte'),
            subtitle: Slider(
              value: fontSize,
              min: 11,
              max: 26,
              divisions: 15,
              label: fontSize.round().toString(),
              onChanged: (v) => _update('font_size', v),
            ),
          ),
          ListTile(
            title: const Text('Espaçamento entre linhas'),
            subtitle: Slider(
              value: lineSpacing,
              min: 1.0,
              max: 2.2,
              divisions: 12,
              label: lineSpacing.toStringAsFixed(1),
              onChanged: (v) => _update('line_spacing', v),
            ),
          ),
          SwitchListTile(
            title: const Text('Tema pela capa do livro'),
            subtitle: const Text('Tinge o fundo com a cor dominante da capa'),
            value: useCoverTheme,
            onChanged: (v) => _update('use_cover_theme', v),
          ),
          const Divider(height: 32),
          _sectionTitle('Backup'),
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: const Text('Exportar backup'),
            subtitle: const Text('Biblioteca, favoritos, notas, grifos e glossário'),
            onTap: _exportBackup,
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Restaurar backup'),
            onTap: _importBackup,
          ),
          if (_statusMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _statusMessage!,
                style: TextStyle(color: AppPalette.text.withOpacity(0.7), fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            color: AppPalette.accent,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      );
}
