/// Persistência de configurações e dados por livro (biblioteca,
/// favoritos, notas, grifos, capítulos lidos) num único JSON local.
library app_config;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LibraryEntry {
  final String bookId;
  final String path;
  final String title;
  final String author;
  final String? coverThumbBase64;
  final DateTime lastOpened;

  LibraryEntry({
    required this.bookId,
    required this.path,
    required this.title,
    required this.author,
    this.coverThumbBase64,
    required this.lastOpened,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'author': author,
        'cover_thumb': coverThumbBase64,
        'last_opened': lastOpened.millisecondsSinceEpoch / 1000,
      };

  static LibraryEntry fromJson(String bookId, Map<String, dynamic> json) {
    final lastOpenedSeconds = (json['last_opened'] as num?)?.toDouble() ?? 0;
    return LibraryEntry(
      bookId: bookId,
      path: json['path'] as String? ?? '',
      title: json['title'] as String? ?? '',
      author: json['author'] as String? ?? '',
      coverThumbBase64: json['cover_thumb'] as String?,
      lastOpened: DateTime.fromMillisecondsSinceEpoch((lastOpenedSeconds * 1000).round()),
    );
  }
}

class AppConfig {
  static const _defaults = <String, dynamic>{
    'theme': 'dark',
    'font_family': '', // vazio = fonte padrão do sistema
    'font_size': 15,
    'line_spacing': 1.4,
    'margin': 28,
    'auto_translate': true,
    'use_cover_theme': true,
    'target_language': 'pt',
    'last_chapter': <String, dynamic>{}, // {book_id: chapter_index}
    'excluded_chapters': <String, dynamic>{}, // {book_id: {href: bool}} — ajuste manual, vence a heurística
    'library': <String, dynamic>{}, // {book_id: {...}}
    'favorites': <String, dynamic>{}, // {book_id: [chapter_index, ...]}
    'notes': <String, dynamic>{}, // {book_id: {chapter_index_str: texto}}
    'highlights': <String, dynamic>{}, // {book_id: {chapter_index_str: [{text, comment}]}}
    'read_chapters': <String, dynamic>{}, // {book_id: [chapter_index, ...]}
    'reading_wpm': 200,
    'side_by_side': false,
  };

  late Map<String, dynamic> _data;
  late File _file;
  bool _loaded = false;

  AppConfig._();

  static AppConfig? _instance;

  /// Acesso único (singleton) — todo o app compartilha a mesma config
  /// carregada em memória, salva em disco a cada mudança.
  static Future<AppConfig> load() async {
    if (_instance != null && _instance!._loaded) return _instance!;
    final config = AppConfig._();
    final dir = await getApplicationDocumentsDirectory();
    config._file = File('${dir.path}/settings.json');
    config._data = Map<String, dynamic>.from(_defaults.map(
      (k, v) => MapEntry(k, v is Map ? Map<String, dynamic>.from(v) : v),
    ));
    if (await config._file.exists()) {
      try {
        final content = await config._file.readAsString();
        final saved = json.decode(content) as Map<String, dynamic>;
        config._data.addAll(saved);
      } catch (_) {
        // config corrompida ou ilegível: segue com os padrões
      }
    }
    config._loaded = true;
    _instance = config;
    return config;
  }

  Future<void> _save() async {
    await _file.writeAsString(json.encode(_data));
  }

  dynamic get(String key, [dynamic fallback]) => _data[key] ?? fallback;

  Future<void> set(String key, dynamic value) async {
    _data[key] = value;
    await _save();
  }

  // ---------- capítulo atual por livro ----------

  Future<void> setLastChapter(String bookId, int chapterIndex) async {
    (_data['last_chapter'] as Map<String, dynamic>)[bookId] = chapterIndex;
    await _save();
  }

  int getLastChapter(String bookId) =>
      (_data['last_chapter'] as Map<String, dynamic>)[bookId] as int? ?? 0;

  // ---------- ajuste manual de capítulos (gerenciador de capítulos) ----------

  Map<String, bool> getChapterOverrides(String bookId) {
    final all = _data['excluded_chapters'] as Map<String, dynamic>;
    final bookOverrides = all[bookId] as Map<String, dynamic>?;
    if (bookOverrides == null) return {};
    return bookOverrides.map((k, v) => MapEntry(k, v as bool));
  }

  Future<void> setChapterOverrides(String bookId, Map<String, bool> overrides) async {
    final all = _data['excluded_chapters'] as Map<String, dynamic>;
    all[bookId] = overrides;
    await _save();
  }

  // ---------- biblioteca (histórico de livros abertos) ----------

  Future<void> addToLibrary(LibraryEntry entry) async {
    final library = _data['library'] as Map<String, dynamic>;
    library[entry.bookId] = entry.toJson();
    await _save();
  }

  List<LibraryEntry> getLibrary() {
    final library = _data['library'] as Map<String, dynamic>;
    final entries = library.entries
        .map((e) => LibraryEntry.fromJson(e.key, e.value as Map<String, dynamic>))
        .toList();
    entries.sort((a, b) => b.lastOpened.compareTo(a.lastOpened));
    return entries;
  }

  Future<void> removeFromLibrary(String bookId) async {
    (_data['library'] as Map<String, dynamic>).remove(bookId);
    await _save();
  }

  // ---------- favoritos ----------

  Future<bool> toggleFavorite(String bookId, int chapterIndex) async {
    final favorites = _data['favorites'] as Map<String, dynamic>;
    final list = (favorites[bookId] as List?)?.cast<int>() ?? <int>[];
    bool isFav;
    if (list.contains(chapterIndex)) {
      list.remove(chapterIndex);
      isFav = false;
    } else {
      list.add(chapterIndex);
      isFav = true;
    }
    favorites[bookId] = list;
    await _save();
    return isFav;
  }

  bool isFavorite(String bookId, int chapterIndex) {
    final favorites = _data['favorites'] as Map<String, dynamic>;
    final list = (favorites[bookId] as List?)?.cast<int>() ?? <int>[];
    return list.contains(chapterIndex);
  }

  // ---------- notas ----------

  String getNote(String bookId, int chapterIndex) {
    final notes = _data['notes'] as Map<String, dynamic>;
    final bookNotes = notes[bookId] as Map<String, dynamic>?;
    return bookNotes?[chapterIndex.toString()] as String? ?? '';
  }

  Future<void> setNote(String bookId, int chapterIndex, String text) async {
    final notes = _data['notes'] as Map<String, dynamic>;
    final bookNotes = (notes[bookId] as Map<String, dynamic>?) ?? <String, dynamic>{};
    if (text.trim().isNotEmpty) {
      bookNotes[chapterIndex.toString()] = text;
    } else {
      bookNotes.remove(chapterIndex.toString());
    }
    notes[bookId] = bookNotes;
    await _save();
  }

  // ---------- grifos + comentários ----------

  Future<void> addHighlight(String bookId, int chapterIndex, String text, {String comment = ''}) async {
    final highlights = _data['highlights'] as Map<String, dynamic>;
    final bookH = (highlights[bookId] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final chapterH = (bookH[chapterIndex.toString()] as List?)?.cast<Map<String, dynamic>>() ?? <Map<String, dynamic>>[];
    chapterH.add({'text': text, 'comment': comment});
    bookH[chapterIndex.toString()] = chapterH;
    highlights[bookId] = bookH;
    await _save();
  }

  List<Map<String, dynamic>> getHighlights(String bookId, int chapterIndex) {
    final highlights = _data['highlights'] as Map<String, dynamic>;
    final bookH = highlights[bookId] as Map<String, dynamic>?;
    return (bookH?[chapterIndex.toString()] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// Índice do grifo cujo texto bate exatamente com [text] neste
  /// capítulo, ou -1 se não houver nenhum — usado pra saber se um
  /// parágrafo já está grifado (destaque visual) e pra alternar
  /// grifar/remover no toque-e-segure.
  int findHighlightIndex(String bookId, int chapterIndex, String text) {
    final list = getHighlights(bookId, chapterIndex);
    for (var i = 0; i < list.length; i++) {
      if (list[i]['text'] == text) return i;
    }
    return -1;
  }

  Future<void> removeHighlightAt(String bookId, int chapterIndex, int highlightIndex) async {
    final highlights = _data['highlights'] as Map<String, dynamic>;
    final bookH = highlights[bookId] as Map<String, dynamic>?;
    if (bookH == null) return;
    final chapterH = (bookH[chapterIndex.toString()] as List?)?.cast<Map<String, dynamic>>();
    if (chapterH == null) return;
    if (highlightIndex < 0 || highlightIndex >= chapterH.length) return;
    chapterH.removeAt(highlightIndex);
    bookH[chapterIndex.toString()] = chapterH;
    highlights[bookId] = bookH;
    await _save();
  }

  // ---------- estatísticas de leitura ----------

  Future<void> markAsRead(String bookId, int chapterIndex) async {
    final read = _data['read_chapters'] as Map<String, dynamic>;
    final list = (read[bookId] as List?)?.cast<int>() ?? <int>[];
    if (!list.contains(chapterIndex)) {
      list.add(chapterIndex);
      read[bookId] = list;
      await _save();
    }
  }

  Future<void> unmarkAsRead(String bookId, int chapterIndex) async {
    final read = _data['read_chapters'] as Map<String, dynamic>;
    final list = (read[bookId] as List?)?.cast<int>() ?? <int>[];
    if (list.contains(chapterIndex)) {
      list.remove(chapterIndex);
      read[bookId] = list;
      await _save();
    }
  }

  bool isRead(String bookId, int chapterIndex) {
    final read = _data['read_chapters'] as Map<String, dynamic>;
    final list = (read[bookId] as List?)?.cast<int>() ?? <int>[];
    return list.contains(chapterIndex);
  }

  int getReadCount(String bookId) {
    final read = _data['read_chapters'] as Map<String, dynamic>;
    return ((read[bookId] as List?)?.length) ?? 0;
  }

  // ---------- backup/restauração ----------

  /// Serializa todo o estado (biblioteca, favoritos, notas, grifos,
  /// capítulos lidos, preferências) num único JSON.
  String exportJson() => json.encode(_data);

  /// Substitui o estado atual pelo conteúdo de um backup exportado
  /// anteriormente. Chaves ausentes no backup mantêm o padrão.
  Future<void> importJson(String content) async {
    final decoded = json.decode(content) as Map<String, dynamic>;
    _data = Map<String, dynamic>.from(_defaults.map(
      (k, v) => MapEntry(k, v is Map ? Map<String, dynamic>.from(v) : v),
    ));
    _data.addAll(decoded);
    await _save();
  }
}
