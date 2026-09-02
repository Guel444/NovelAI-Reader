"""
cache.py — Cache inteligente de traduções (Fase 5).

Guarda cada parágrafo já traduzido em um banco SQLite local, indexado
pelo hash do texto original + idioma de destino. Assim, reabrir um
capítulo já traduzido é instantâneo e nunca traduz o mesmo trecho
duas vezes.
"""

import hashlib
import os
import sqlite3
from contextlib import contextmanager

CACHE_DB_PATH = os.path.join(os.path.dirname(__file__), "cache", "translations.db")


def _hash_text(text: str, target_lang: str) -> str:
    key = f"{target_lang}:{text}".encode("utf-8")
    return hashlib.sha256(key).hexdigest()


class TranslationCache:
    def __init__(self, db_path: str = CACHE_DB_PATH):
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self.db_path = db_path
        self._init_db()

    @contextmanager
    def _connect(self):
        conn = sqlite3.connect(self.db_path)
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def _init_db(self):
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS translations (
                    hash TEXT PRIMARY KEY,
                    original TEXT NOT NULL,
                    translated TEXT NOT NULL,
                    target_lang TEXT NOT NULL,
                    book_id TEXT,
                    chapter_index INTEGER
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_book_chapter "
                "ON translations (book_id, chapter_index)"
            )

    def get(self, text: str, target_lang: str) -> str | None:
        h = _hash_text(text, target_lang)
        with self._connect() as conn:
            row = conn.execute(
                "SELECT translated FROM translations WHERE hash = ?", (h,)
            ).fetchone()
        return row[0] if row else None

    def set(self, text: str, translated: str, target_lang: str,
            book_id: str = "", chapter_index: int = -1):
        h = _hash_text(text, target_lang)
        with self._connect() as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO translations
                    (hash, original, translated, target_lang, book_id, chapter_index)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (h, text, translated, target_lang, book_id, chapter_index),
            )

    def chapter_is_cached(self, paragraphs: list[str], target_lang: str) -> bool:
        """Retorna True se todo o capítulo já está no cache (abre instantâneo)."""
        return all(self.get(p, target_lang) is not None for p in paragraphs if p.strip())

    def clear_book(self, book_id: str):
        with self._connect() as conn:
            conn.execute("DELETE FROM translations WHERE book_id = ?", (book_id,))

    def clear_all(self):
        with self._connect() as conn:
            conn.execute("DELETE FROM translations")
