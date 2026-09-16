/// Traduz parágrafos passando primeiro pelo glossário e pelo cache.
///
/// Suporta 3 motores de tradução, escolhidos pelo usuário nas
/// configurações:
/// - Google Translate (endpoint gratuito não-oficial, sem chave, sem limite conhecido)
/// - DeepL (API oficial, tier gratuito com cota mensal de caracteres)
/// - Gemini (API oficial do Google, tier gratuito com cota diária de requisições —
///   entende contexto/expressões idiomáticas melhor por ser um modelo de linguagem)
///
/// Se o motor escolhido não tiver chave configurada, ou estourar a cota
/// gratuita (detectado pelo HTTP de "sem créditos" de cada provedor), o
/// Translator cai automaticamente pro Google Translate e expõe um aviso
/// em [pendingFallbackNotice] pra tela mostrar ao usuário. O esgotamento
/// fica registrado no AppConfig (por provedor, com data) pra não ficar
/// tentando o provedor esgotado de novo antes da cota ter chance de
/// renovar.
///
/// Parágrafos que ainda não estão no cache são agrupados em blocos e
/// traduzidos numa ÚNICA chamada por bloco (com um separador que
/// sobrevive à tradução), em vez de uma chamada por parágrafo — isso
/// evita bloqueio por excesso de requisições em livros longos.
library translator_service;

import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;

import '../data/app_config.dart';
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

String _languageNameFor(String code) {
  for (final lang in supportedLanguages) {
    if (lang.$1 == code) return lang.$2;
  }
  return code;
}

/// Motores de tradução disponíveis.
enum TranslationProvider { google, deepl, gemini }

extension TranslationProviderX on TranslationProvider {
  /// Chave usada pra salvar/ler no AppConfig — não mude, já pode
  /// existir configuração salva com esses valores.
  String get storageKey => switch (this) {
        TranslationProvider.google => 'google',
        TranslationProvider.deepl => 'deepl',
        TranslationProvider.gemini => 'gemini',
      };

  String get displayName => switch (this) {
        TranslationProvider.google => 'Google Translate',
        TranslationProvider.deepl => 'DeepL',
        TranslationProvider.gemini => 'Gemini',
      };

  bool get needsApiKey => this != TranslationProvider.google;

  /// Tempo aproximado até a cota gratuita renovar — usado só pra
  /// decidir quando vale tentar o provedor esgotado de novo, evitando
  /// bater na mesma parede a cada capítulo aberto. Não é garantia de
  /// quando o provedor renova de fato; é só uma folga razoável.
  Duration? get quotaResetWindow => switch (this) {
        TranslationProvider.deepl => const Duration(days: 30),
        TranslationProvider.gemini => const Duration(days: 1),
        TranslationProvider.google => null,
      };

  static TranslationProvider fromStorageKey(String key) => switch (key) {
        'deepl' => TranslationProvider.deepl,
        'gemini' => TranslationProvider.gemini,
        _ => TranslationProvider.google,
      };
}

class TranslationError implements Exception {
  final String message;
  TranslationError(this.message);
  @override
  String toString() => message;
}

/// Sinaliza especificamente "provedor sem créditos/cota agora" —
/// tratado à parte de outros erros porque não adianta tentar de novo
/// com o mesmo provedor: o Translator cai pro Google imediatamente.
class _QuotaExceededError implements Exception {
  final TranslationProvider provider;
  _QuotaExceededError(this.provider);
}

/// Mapeamento pros códigos de idioma que a API do DeepL espera
/// (diferem em parte dos códigos do Google). Idiomas ausentes daqui
/// não são suportados pelo DeepL — o Translator cai pro Google
/// automaticamente nesse caso. Cheque a documentação da DeepL de
/// tempos em tempos, essa lista de idiomas suportados muda.
const _deeplLangCodes = <String, String>{
  'pt': 'PT-BR',
  'en': 'EN-US',
  'es': 'ES',
  'fr': 'FR',
  'de': 'DE',
  'it': 'IT',
  'ja': 'JA',
  'ko': 'KO',
  'zh-CN': 'ZH',
  'ru': 'RU',
  'nl': 'NL',
  'pl': 'PL',
  'tr': 'TR',
  'id': 'ID',
  'sv': 'SV',
  'no': 'NB',
  'da': 'DA',
  'fi': 'FI',
  'el': 'EL',
  'uk': 'UK',
  'cs': 'CS',
  'ro': 'RO',
  'hu': 'HU',
  'bg': 'BG',
  'sk': 'SK',
  'lt': 'LT',
  'lv': 'LV',
  'et': 'ET',
  'sl': 'SL',
};

const _maxRetries = 6;
const _baseTimeout = Duration(seconds: 15);
const _retryDelay = Duration(seconds: 2);
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
  final TranslationProvider provider;
  final String? apiKey;

  /// Opcional — se fornecido, o Translator consulta/atualiza aqui
  /// quando o provedor escolhido estourar a cota, pra não insistir
  /// nele de novo antes da janela de renovação passar.
  final AppConfig? config;

  Translator({
    required this.targetLang,
    required this.cache,
    required this.glossary,
    this.provider = TranslationProvider.google,
    this.apiKey,
    this.config,
  });

  /// Cria um Translator já configurado com o motor, idioma e chave
  /// de API escolhidos pelo usuário nas configurações.
  factory Translator.fromConfig(
    AppConfig config, {
    required TranslationCache cache,
    required Glossary glossary,
  }) {
    final provider = TranslationProviderX.fromStorageKey(
      config.get('translation_provider', 'google') as String,
    );
    final apiKey = switch (provider) {
      TranslationProvider.deepl => config.get('deepl_api_key', '') as String,
      TranslationProvider.gemini => config.get('gemini_api_key', '') as String,
      TranslationProvider.google => null,
    };
    return Translator(
      targetLang: config.get('target_language', 'pt') as String,
      cache: cache,
      glossary: glossary,
      provider: provider,
      apiKey: (apiKey != null && apiKey.trim().isEmpty) ? null : apiKey,
      config: config,
    );
  }

  /// Preenchido quando esta instância precisou cair pro Google
  /// Translate por falta de chave ou de cota do motor escolhido. A
  /// tela de leitura/tradução lê isso (com [takeFallbackNotice]) pra
  /// avisar o usuário uma única vez.
  String? pendingFallbackNotice;

  /// Já caiu pro Google nesta instância — evita ficar testando um
  /// provedor que a gente já sabe que vai falhar de novo dentro do
  /// mesmo lote de tradução.
  bool _sessionFallback = false;

  /// Lê e limpa o aviso pendente, se houver.
  String? takeFallbackNotice() {
    final notice = pendingFallbackNotice;
    pendingFallbackNotice = null;
    return notice;
  }

  Future<bool> _recentlyExhausted(TranslationProvider p) async {
    final window = p.quotaResetWindow;
    if (window == null || config == null) return false;
    final exhaustedAt = config!.getQuotaExhaustedAt(p.storageKey);
    if (exhaustedAt == null) return false;
    return DateTime.now().difference(exhaustedAt) < window;
  }

  Future<String> _translateChunk(String text) async {
    var effectiveProvider = provider;

    if (_sessionFallback) {
      effectiveProvider = TranslationProvider.google;
    } else if (provider.needsApiKey && (apiKey == null || apiKey!.trim().isEmpty)) {
      effectiveProvider = TranslationProvider.google;
      pendingFallbackNotice =
          'Nenhuma chave configurada para ${provider.displayName}. Usando o Google '
          'Translate por enquanto — adicione a chave nas configurações pra usar '
          '${provider.displayName}.';
      _sessionFallback = true;
    } else if (provider.needsApiKey && await _recentlyExhausted(provider)) {
      effectiveProvider = TranslationProvider.google;
      pendingFallbackNotice =
          'Os créditos gratuitos do ${provider.displayName} ainda não devem ter '
          'renovado. Usando o Google Translate por enquanto.';
      _sessionFallback = true;
    }

    Object? lastError;
    for (var attempt = 1; attempt <= _maxRetries; attempt++) {
      try {
        final result = await _callProvider(effectiveProvider, text)
            .timeout(_baseTimeout * attempt);
        return _validateResult(result);
      } on _QuotaExceededError catch (exc) {
        // Não adianta insistir no mesmo provedor: registra o
        // esgotamento, avisa a tela e cai pro Google já nesta mesma
        // tentativa (sem contar como uma tentativa "gasta").
        await config?.setQuotaExhausted(exc.provider.storageKey);
        pendingFallbackNotice =
            'Os créditos gratuitos do ${exc.provider.displayName} acabaram por agora. '
            'Troquei para o Google Translate automaticamente.';
        _sessionFallback = true;
        effectiveProvider = TranslationProvider.google;
        try {
          final fallbackResult =
              await _callProvider(TranslationProvider.google, text).timeout(_baseTimeout);
          return _validateResult(fallbackResult);
        } catch (exc2) {
          lastError = exc2;
        }
      } catch (exc) {
        lastError = exc;
        await Future.delayed(_retryDelay * attempt);
      }
    }
    throw TranslationError(
      'Não consegui traduzir depois de $_maxRetries tentativas, mesmo '
      'esperando cada vez mais tempo por tentativa (até '
      '${(_baseTimeout * _maxRetries).inSeconds}s). Verifique se a conexão '
      'está mesmo respondendo, não só ligada. Detalhe: $lastError',
    );
  }

  String _validateResult(String result) {
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
  }

  Future<String> _callProvider(TranslationProvider p, String text) {
    switch (p) {
      case TranslationProvider.deepl:
        return _callDeepL(text);
      case TranslationProvider.gemini:
        return _callGemini(text);
      case TranslationProvider.google:
        return _callGoogle(text);
    }
  }

  Future<String> _callGoogle(String text) async {
    final uri = Uri.https('translate.googleapis.com', '/translate_a/single', {
      'client': 'gtx',
      'sl': 'auto',
      'tl': targetLang,
      'dt': 't',
      'q': text,
    });
    final response = await http.get(uri);
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
    return buffer.toString();
  }

  Future<String> _callDeepL(String text) async {
    final deeplTarget = _deeplLangCodes[targetLang];
    if (deeplTarget == null) {
      // Idioma não suportado pela DeepL — não é questão de cota, mas
      // trata do mesmo jeito (cai pro Google) pra não travar a leitura.
      pendingFallbackNotice =
          '${_languageNameFor(targetLang)} não é suportado pelo DeepL. Usando o '
          'Google Translate para este idioma.';
      _sessionFallback = true;
      return _validateResult(await _callGoogle(text));
    }
    final uri = Uri.parse('https://api-free.deepl.com/v2/translate');
    final response = await http.post(
      uri,
      headers: {
        'Authorization': 'DeepL-Auth-Key $apiKey',
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      },
      body: {
        'text': text,
        'target_lang': deeplTarget,
      },
    );
    if (response.statusCode == 456 || response.statusCode == 429) {
      throw _QuotaExceededError(TranslationProvider.deepl);
    }
    if (response.statusCode == 403) {
      throw TranslationError('Chave de API do DeepL inválida ou não autorizada.');
    }
    if (response.statusCode != 200) {
      throw TranslationError('DeepL respondeu HTTP ${response.statusCode}.');
    }
    final decoded = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final translations = decoded['translations'] as List<dynamic>?;
    if (translations == null || translations.isEmpty) {
      throw TranslationError('DeepL não retornou nenhuma tradução.');
    }
    return (translations.first as Map<String, dynamic>)['text'] as String? ?? '';
  }

  Future<String> _callGemini(String text) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:generateContent',
    );
    final languageName = _languageNameFor(targetLang);
    final prompt =
        'Traduza o texto a seguir para $languageName, mantendo o tom e o registro '
        'do original (inclusive gírias e expressões idiomáticas — adapte pro '
        'equivalente natural em $languageName, não traduza ao pé da letra). '
        'Preserve exatamente, sem traduzir ou alterar: quebras de linha, o '
        'marcador "$_separatorToken" e qualquer trecho no formato XPROTECTnX '
        '(ex: XPROTECT0X, XPROTECT12X). Responda só com o texto traduzido, sem '
        'nenhum comentário, explicação ou marcação extra.\n\n$text';
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey ?? '',
      },
      body: json.encode({
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
      }),
    );
    if (response.statusCode == 429) {
      throw _QuotaExceededError(TranslationProvider.gemini);
    }
    if (response.statusCode == 403 || response.statusCode == 401) {
      throw TranslationError('Chave de API do Gemini inválida ou não autorizada.');
    }
    if (response.statusCode != 200) {
      throw TranslationError('Gemini respondeu HTTP ${response.statusCode}.');
    }
    final decoded = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw TranslationError('Gemini não retornou nenhum candidato de tradução.');
    }
    final content = (candidates.first as Map<String, dynamic>)['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      throw TranslationError('Gemini retornou uma resposta vazia.');
    }
    return (parts.first as Map<String, dynamic>)['text'] as String? ?? '';
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
