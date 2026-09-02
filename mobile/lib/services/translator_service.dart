/// Traduz parágrafos passando primeiro pelo glossário e pelo cache.
/// Usa o endpoint gratuito do Google Translate.
///
/// Parágrafos que ainda não estão no cache são agrupados em blocos e
/// traduzidos numa ÚNICA chamada por bloco (com um separador que
/// sobrevive à tradução), em vez de uma chamada por parágrafo — isso
/// evita bloqueio por excesso de requisições em livros longos.
library translator_service;

import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;

import '../data/glossary.dart';
import '../data/translation_cache.dart';

/// Lista curada de idiomas suportados.
const supportedLanguages = <(String code, String name)>[
  ('pt', 'Português'), ('en', 'Inglês'), ('es', 'Espanhol'),
  ('fr', 'Francês'), ('de', 'Alemão'), ('it', 'Italiano'),
  ('ja', 'Japonês'), ('ko', 'Coreano'), ('zh-CN', 'Chinês (simplificado)'),
  ('zh-TW', 'Chinês (tradicional)'), ('ru', 'Russo'), ('ar', 'Árabe'),
  ('hi', 'Hindi'), ('nl', 'Holandês'), ('pl', 'Polonês'),
  ('tr', 'Turco'), ('vi', 'Vietnamita'), ('th', 'Tailandês'),
  ('id', 'Indonésio'), ('sv', 'Sueco'), ('no', 'Norueguês'),
  ('da', 'Dinamarquês'), ('fi', 'Finlandês'), ('el', 'Grego'),
  ('he', 'Hebraico'), ('uk', 'Ucraniano'), ('cs', 'Tcheco'),
  ('ro', 'Romeno'), ('hu', 'Húngaro'), ('bg', 'Búlgaro'),
  ('fa', 'Persa'), ('ms', 'Malaio'), ('bn', 'Bengali'),
  ('ta', 'Tâmil'), ('ur', 'Urdu'), ('sr', 'Sérvio'),
  ('hr', 'Croata'), ('sk', 'Eslovaco'), ('lt', 'Lituano'),
  ('lv', 'Letão'), ('et', 'Estoniano'), ('sl', 'Esloveno'),
  ('af', 'Africâner'), ('sw', 'Suaíli'), ('tl', 'Filipino'),
];

class TranslationError implements Exception {
  final String message;
  TranslationError(this.message);
  @override
  String toString() => message;
}

const _maxRetries = 3;
const _retryDelay = Duration(milliseconds: 1500);
const _chunkSize = 4000; // limite prático por chamada
const _paragraphSeparator = '\n@@P@@\n';
const _separatorToken = '@@P@@';

const _errorSignatures = [
  'error 500', 'server error', "that's an error", 'that’s an error',
  "that's all we know", 'that’s all we know', '502 bad gateway',
  '503 service unavailable', '429 too many requests', '<!doctype html',
  '<html', 'access denied', 'please try again later',
];

bool _looksLikeErrorPage(String text) {
  final lowered = text.toLowerCase();
  return _errorSignatures.any((sig) => lowered.contains(sig));
}

class Translator {
  final String targetLang;
  final TranslationCache cache;
  final Glossary glossary;

  Translator({required this.targetLang, required this.cache, required this.glossary});

  Future<String> _translateChunk(String text) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _maxRetries; attempt++) {
      try {
        final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
          'client': 'gtx',
          'sl': 'auto',
          'tl': targetLang,
          'dt': 't',
          'q': text,
        });
        final response = await http.get(uri).timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          throw TranslationError('HTTP ${response.statusCode}');
        }
        final decoded = json.decode(response.body) as List<dynamic>;
        final segments = decoded[0] as List<dynamic>;
        final buffer = StringBuffer();
        for (final segment in segments) {
          final piece = (segment as List<dynamic>)[0];
          if (piece is String) buffer.write(piece);
        }
        final result = buffer.toString();
        if (result.trim().isEmpty) {
          throw TranslationError('A API de tradução devolveu vazio.');
        }
        if (_looksLikeErrorPage(result)) {
          throw TranslationError(
            'O serviço de tradução respondeu com uma página de erro '
            '(provavelmente bloqueio temporário por excesso de requisições).',
          );
        }
        return result;
      } catch (exc) {
        lastError = exc;
        await Future.delayed(_retryDelay * attempt);
      }
    }
    throw TranslationError(
      'Não consegui traduzir depois de $_maxRetries tentativas '
      '(verifique sua conexão, ou espere um pouco). Detalhe: $lastError',
    );
  }

  /// Traduz um único parágrafo (fora do fluxo de capítulo inteiro).
  Future<String> translateParagraph(String text, {String bookId = '', int chapterIndex = -1}) async {
    if (text.trim().isEmpty) return text;

    final cached = await cache.get(text, targetLang);
    if (cached != null && !_looksLikeErrorPage(cached)) return cached;

    final (protectedText, placeholders) = glossary.protect(text);
    final translated = await _translateChunk(protectedText);
    final finalText = glossary.restore(translated, placeholders);

    await cache.set(text, finalText, targetLang, bookId: bookId, chapterIndex: chapterIndex);
    return finalText;
  }

  List<List<String>> _buildBatches(List<String> texts) {
    final batches = <List<String>>[];
    var current = <String>[];
    var currentLen = 0;
    for (final t in texts) {
      final tLen = t.length + _paragraphSeparator.length;
      if (current.isNotEmpty && currentLen + tLen > _chunkSize) {
        batches.add(current);
        current = [];
        currentLen = 0;
      }
      current.add(t);
      currentLen += tLen;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// Traduz uma lista de parágrafos, chamando onProgress(feito, total)
  /// conforme avança. Parágrafos já em cache não geram chamada de API;
  /// os que faltam são agrupados em blocos. Se um bloco falhar, os
  /// parágrafos dele mantêm o texto original em vez de travar o
  /// capítulo inteiro.
  Future<List<String>> translateChapter(
    List<String> paragraphs, {
    String bookId = '',
    int chapterIndex = -1,
    void Function(int done, int total)? onProgress,
  }) async {
    final total = paragraphs.length;
    final results = List<String?>.filled(total, null);
    final pendingIndices = <int>[];
    final pendingTexts = <String>[];

    for (var i = 0; i < total; i++) {
      final p = paragraphs[i];
      if (p.trim().isEmpty) {
        results[i] = p;
        continue;
      }
      final cached = await cache.get(p, targetLang);
      if (cached != null && !_looksLikeErrorPage(cached)) {
        results[i] = cached;
      } else {
        pendingIndices.add(i);
        pendingTexts.add(p);
      }
    }

    var done = total - pendingIndices.length;
    onProgress?.call(done, total);

    if (pendingTexts.isEmpty) {
      return results.map((r) => r!).toList();
    }

    final batches = _buildBatches(pendingTexts);
    var cursor = 0;
    var failures = 0;
    String? lastErrorLocal;

    for (final batch in batches) {
      final protectedTexts = <String>[];
      final placeholdersList = <Map<String, String>>[];
      for (final t in batch) {
        final (protectedText, placeholders) = glossary.protect(t);
        protectedTexts.add(protectedText);
        placeholdersList.add(placeholders);
      }

      List<String?> translatedParts;
      try {
        final joined = protectedTexts.join(_paragraphSeparator);
        final translatedJoined = await _translateChunk(joined);
        translatedParts = translatedJoined.split(_separatorToken).map((s) => s.trim()).toList();
        if (translatedParts.length != batch.length) {
          // separador não sobreviveu à tradução — cai pra tradução
          // parágrafo a parágrafo só deste bloco
          translatedParts = [];
          for (final t in protectedTexts) {
            try {
              translatedParts.add(await _translateChunk(t));
            } on TranslationError {
              translatedParts.add(null);
            }
          }
        }
      } on TranslationError catch (exc) {
        lastErrorLocal = exc.message;
        translatedParts = List<String?>.filled(batch.length, null);
      }

      for (var j = 0; j < batch.length; j++) {
        final original = batch[j];
        final placeholders = placeholdersList[j];
        final translated = translatedParts[j];
        final i = pendingIndices[cursor];
        if (translated == null) {
          results[i] = original;
          failures++;
        } else {
          final finalText = glossary.restore(translated, placeholders);
          await cache.set(original, finalText, targetLang, bookId: bookId, chapterIndex: chapterIndex);
          results[i] = finalText;
        }
        cursor++;
        done++;
        onProgress?.call(done, total);
      }
    }

    if (failures == pendingIndices.length && pendingIndices.isNotEmpty) {
      throw TranslationError(lastErrorLocal ?? 'Nenhum parágrafo foi traduzido.');
    }

    return results.map((r) => r!).toList();
  }

  Future<bool> chapterIsCached(List<String> paragraphs) => cache.chapterIsCached(paragraphs, targetLang);
}
