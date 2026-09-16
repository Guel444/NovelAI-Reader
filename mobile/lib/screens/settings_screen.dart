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

  final _deeplKeyController = TextEditingController();
  final _geminiKeyController = TextEditingController();
  bool _showDeeplKey = false;
  bool _showGeminiKey = false;

  @override
  void initState() {
    super.initState();
    AppConfig.load().then((c) {
      _deeplKeyController.text = c.get('deepl_api_key', '') as String;
      _geminiKeyController.text = c.get('gemini_api_key', '') as String;
      setState(() => _config = c);
    });
  }

  @override
  void dispose() {
    _deeplKeyController.dispose();
    _geminiKeyController.dispose();
    super.dispose();
  }

  String _providerSubtitle(TranslationProvider p) => switch (p) {
        TranslationProvider.google =>
          'Gratuito, sem limite conhecido. Traduz frase a frase — expressões '
              'idiomáticas às vezes saem ao pé da letra.',
        TranslationProvider.deepl =>
          'Grátis até um teto de caracteres por mês (definido pela própria DeepL). '
              'Qualidade geralmente melhor que o Google.',
        TranslationProvider.gemini =>
          'Grátis com limite diário de requisições. Por ser um modelo de linguagem, '
              'entende melhor contexto e expressões idiomáticas.',
      };

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Widget _apiKeyField({
    required String label,
    required String helpText,
    required TextEditingController controller,
    required bool obscure,
    required VoidCallback toggleObscure,
    required String configKey,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            obscureText: !obscure,
            style: const TextStyle(color: AppPalette.text),
            decoration: InputDecoration(
              labelText: label,
              suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: toggleObscure,
              ),
            ),
            onChanged: (v) => _update(configKey, v),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              helpText,
              style: TextStyle(color: AppPalette.text.withOpacity(0.6), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _quotaStatus(TranslationProvider p) {
    final resetWindow = p.quotaResetWindow;
    final exhaustedAt = _config?.getQuotaExhaustedAt(p.storageKey);
    if (resetWindow == null || exhaustedAt == null) return null;
    final renewsAround = exhaustedAt.add(resetWindow);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8, left: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Créditos esgotados em ${_formatDate(exhaustedAt)} — deve renovar por volta '
              'de ${_formatDate(renewsAround)}. Até lá, o app usa o Google Translate '
              'automaticamente.',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () async {
              await _config?.clearQuotaExhausted(p.storageKey);
              setState(() {});
            },
            child: const Text('Testar de novo'),
          ),
        ],
      ),
    );
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
    final currentProvider = TranslationProviderX.fromStorageKey(
      config.get('translation_provider', 'google') as String,
    );
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
          const SizedBox(height: 8),
          const Text(
            'Motor de tradução',
            style: TextStyle(color: AppPalette.text, fontWeight: FontWeight.w600, fontSize: 13),
          ),
          ...TranslationProvider.values.map(
            (p) => RadioListTile<TranslationProvider>(
              contentPadding: EdgeInsets.zero,
              title: Text(p.displayName),
              subtitle: Text(_providerSubtitle(p)),
              value: p,
              groupValue: currentProvider,
              activeColor: AppPalette.accent,
              onChanged: (v) {
                if (v != null) _update('translation_provider', v.storageKey);
              },
            ),
          ),
          if (currentProvider == TranslationProvider.deepl) ...[
            _apiKeyField(
              label: 'Chave de API da DeepL',
              helpText: 'Grátis em www.deepl.com/pro-api (plano "DeepL API Free").',
              controller: _deeplKeyController,
              obscure: _showDeeplKey,
              toggleObscure: () => setState(() => _showDeeplKey = !_showDeeplKey),
              configKey: 'deepl_api_key',
            ),
            if (_quotaStatus(TranslationProvider.deepl) != null) _quotaStatus(TranslationProvider.deepl)!,
          ],
          if (currentProvider == TranslationProvider.gemini) ...[
            _apiKeyField(
              label: 'Chave de API do Gemini',
              helpText: 'Grátis em aistudio.google.com/apikey.',
              controller: _geminiKeyController,
              obscure: _showGeminiKey,
              toggleObscure: () => setState(() => _showGeminiKey = !_showGeminiKey),
              configKey: 'gemini_api_key',
            ),
            if (_quotaStatus(TranslationProvider.gemini) != null) _quotaStatus(TranslationProvider.gemini)!,
          ],
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
