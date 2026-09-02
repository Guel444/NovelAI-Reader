/// Cache de traduções em SQLite: cada parágrafo já traduzido fica
/// salvo localmente, indexado pelo hash do texto original + idioma
/// de destino. Reabrir um capítulo já traduzido é instantâneo e
/// nunca traduz o mesmo trecho duas vezes.
library translation_cache;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

String _hashText(String text, String targetLang) {
  final key = '$targetLang:$text';
  return sha256.convert(utf8.encode(key)).toString();
}

class TranslationCache {
  Database? _db;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'cache', 'translations.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS translations (
            hash TEXT PRIMARY KEY,
            original TEXT NOT NULL,
            translated TEXT NOT NULL,
            target_lang TEXT NOT NULL,
            book_id TEXT,
            chapter_index INTEGER
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_book_chapter ON translations (book_id, chapter_index)',
        );
      },
    );
    return _db!;
  }

  Future<String?> get(String text, String targetLang) async {
    final db = await _database;
    final hash = _hashText(text, targetLang);
    final rows = await db.query(
      'translations',
      columns: ['translated'],
      where: 'hash = ?',
      whereArgs: [hash],
    );
    return rows.isEmpty ? null : rows.first['translated'] as String;
  }

  Future<void> set(
    String text,
    String translated,
    String targetLang, {
    String bookId = '',
    int chapterIndex = -1,
  }) async {
    final db = await _database;
    final hash = _hashText(text, targetLang);
    await db.insert(
      'translations',
      {
        'hash': hash,
        'original': text,
        'translated': translated,
        'target_lang': targetLang,
        'book_id': bookId,
        'chapter_index': chapterIndex,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> chapterIsCached(List<String> paragraphs, String targetLang) async {
    for (final p in paragraphs) {
      if (p.trim().isEmpty) continue;
      final cached = await get(p, targetLang);
      if (cached == null) return false;
    }
    return true;
  }

  Future<void> clearBook(String bookId) async {
    final db = await _database;
    await db.delete('translations', where: 'book_id = ?', whereArgs: [bookId]);
  }

  Future<void> clearAll() async {
    final db = await _database;
    await db.delete('translations');
  }
}
