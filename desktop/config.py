"""
config.py — Configurações do NovelAI Reader.

Guarda e carrega preferências do usuário (tema, fonte, tamanho da letra,
espaçamento, margens, tradução automática, biblioteca, favoritos, notas)
em um arquivo JSON simples, para que tudo persista entre sessões.
"""

import json
import os
import time

CONFIG_PATH = os.path.join(os.path.dirname(__file__), "assets", "settings.json")

DEFAULTS = {
    "theme": "dark",            # "dark" ou "light"
    "font_family": "Arial",
    "font_size": 15,
    "line_spacing": 1.4,
    "margin": 28,                # em pixels
    "auto_translate": True,
    "use_cover_theme": True,
    "target_language": "pt",
    "last_book": None,
    "last_chapter": {},          # {book_id: chapter_index}
    "excluded_chapters": {},     # {book_id: [nome_do_item, ...]}
    "library": {},               # {book_id: {path, title, author, cover_thumb, last_opened}}
    "favorites": {},             # {book_id: [chapter_index, ...]}
    "notes": {},                 # {book_id: {chapter_index_str: texto}}
    "highlights": {},            # {book_id: {chapter_index_str: [{text, comment}, ...]}}
    "read_chapters": {},         # {book_id: [chapter_index, ...]}
    "reading_wpm": 200,           # velocidade de leitura em palavras/minuto, pra estimar tempo
    "side_by_side": False,        # Fase 10: mostrar original + tradução juntos
}


class Config:
    def __init__(self, path: str = CONFIG_PATH):
        self.path = path
        self.data = dict(DEFAULTS)
        self.load()

    def load(self):
        if os.path.exists(self.path):
            try:
                with open(self.path, "r", encoding="utf-8") as f:
                    saved = json.load(f)
                self.data.update(saved)
            except (json.JSONDecodeError, OSError):
                # Config corrompida ou ilegível: seguimos com os padrões
                pass

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(self.data, f, ensure_ascii=False, indent=2)

    def export_backup(self, dest_path: str):
        """Exporta TUDO (biblioteca, favoritos, notas, grifos, config)
        num único arquivo JSON, pra levar pra outro PC ou recuperar
        depois de reinstalar."""
        with open(dest_path, "w", encoding="utf-8") as f:
            json.dump(self.data, f, ensure_ascii=False, indent=2)

    def import_backup(self, src_path: str):
        """Restaura tudo a partir de um arquivo exportado por
        export_backup — substitui biblioteca, favoritos, notas, grifos
        e configurações pelos dados do backup."""
        with open(src_path, "r", encoding="utf-8") as f:
            incoming = json.load(f)
        if not isinstance(incoming, dict):
            raise ValueError("Arquivo de backup inválido (formato inesperado).")
        self.data.update(incoming)
        self.save()

    def get(self, key, default=None):
        return self.data.get(key, default)

    def set(self, key, value):
        self.data[key] = value
        self.save()

    def set_last_chapter(self, book_id: str, chapter_index: int):
        chapters = self.data.setdefault("last_chapter", {})
        chapters[book_id] = chapter_index
        self.save()

    def get_last_chapter(self, book_id: str) -> int:
        return self.data.get("last_chapter", {}).get(book_id, 0)

    def get_excluded_chapters(self, book_id: str) -> list[str] | None:
        """None = usuário nunca mexeu manualmente; use a detecção automática."""
        excluded = self.data.get("excluded_chapters", {})
        return excluded.get(book_id)

    def set_excluded_chapters(self, book_id: str, item_names: list[str]):
        excluded = self.data.setdefault("excluded_chapters", {})
        excluded[book_id] = list(item_names)
        self.save()

    # ---------- biblioteca (histórico de livros abertos) ----------

    def add_to_library(self, book_id: str, path: str, title: str, author: str,
                        cover_thumb_b64: str | None = None):
        library = self.data.setdefault("library", {})
        existing = library.get(book_id, {})
        library[book_id] = {
            "path": path,
            "title": title,
            "author": author,
            "cover_thumb": cover_thumb_b64 or existing.get("cover_thumb"),
            "last_opened": time.time(),
        }
        self.save()

    def get_library(self) -> list[dict]:
        library = self.data.get("library", {})
        entries = [{"book_id": bid, **info} for bid, info in library.items()]
        return sorted(entries, key=lambda e: e.get("last_opened", 0), reverse=True)

    def remove_from_library(self, book_id: str):
        library = self.data.get("library", {})
        library.pop(book_id, None)
        self.save()

    # ---------- favoritos ----------

    def toggle_favorite(self, book_id: str, chapter_index: int) -> bool:
        """Alterna favorito e devolve o novo estado (True = favoritado)."""
        favorites = self.data.setdefault("favorites", {})
        book_favs = favorites.setdefault(book_id, [])
        if chapter_index in book_favs:
            book_favs.remove(chapter_index)
            is_fav = False
        else:
            book_favs.append(chapter_index)
            is_fav = True
        self.save()
        return is_fav

    def is_favorite(self, book_id: str, chapter_index: int) -> bool:
        return chapter_index in self.data.get("favorites", {}).get(book_id, [])

    def get_favorites(self, book_id: str) -> list[int]:
        return list(self.data.get("favorites", {}).get(book_id, []))

    # ---------- notas ----------

    def get_note(self, book_id: str, chapter_index: int) -> str:
        return self.data.get("notes", {}).get(book_id, {}).get(str(chapter_index), "")

    def set_note(self, book_id: str, chapter_index: int, text: str):
        notes = self.data.setdefault("notes", {})
        book_notes = notes.setdefault(book_id, {})
        if text.strip():
            book_notes[str(chapter_index)] = text
        else:
            book_notes.pop(str(chapter_index), None)
        self.save()

    def has_note(self, book_id: str, chapter_index: int) -> bool:
        return bool(self.get_note(book_id, chapter_index))

    # ---------- grifos + comentários ----------

    def add_highlight(self, book_id: str, chapter_index: int, text: str, comment: str = ""):
        highlights = self.data.setdefault("highlights", {})
        book_h = highlights.setdefault(book_id, {})
        chapter_h = book_h.setdefault(str(chapter_index), [])
        chapter_h.append({"text": text, "comment": comment})
        self.save()

    def get_highlights(self, book_id: str, chapter_index: int) -> list[dict]:
        return self.data.get("highlights", {}).get(book_id, {}).get(str(chapter_index), [])

    def get_all_highlights(self, book_id: str) -> dict:
        """{chapter_index_str: [{text, comment}, ...]} pra esse livro inteiro."""
        return self.data.get("highlights", {}).get(book_id, {})

    def remove_highlight(self, book_id: str, chapter_index: int, position: int):
        highlights = self.data.get("highlights", {})
        book_h = highlights.get(book_id, {})
        chapter_h = book_h.get(str(chapter_index), [])
        if 0 <= position < len(chapter_h):
            chapter_h.pop(position)
            if not chapter_h:
                book_h.pop(str(chapter_index), None)
            self.save()

    # ---------- estatísticas de leitura ----------

    def mark_as_read(self, book_id: str, chapter_index: int):
        read = self.data.setdefault("read_chapters", {})
        book_read = read.setdefault(book_id, [])
        if chapter_index not in book_read:
            book_read.append(chapter_index)
            self.save()

    def unmark_as_read(self, book_id: str, chapter_index: int):
        book_read = self.data.get("read_chapters", {}).get(book_id, [])
        if chapter_index in book_read:
            book_read.remove(chapter_index)
            self.save()

    def toggle_read(self, book_id: str, chapter_index: int) -> bool:
        """Alterna lido/não-lido manualmente e devolve o novo estado."""
        if self.is_read(book_id, chapter_index):
            self.unmark_as_read(book_id, chapter_index)
            return False
        self.mark_as_read(book_id, chapter_index)
        return True

    def is_read(self, book_id: str, chapter_index: int) -> bool:
        return chapter_index in self.data.get("read_chapters", {}).get(book_id, [])

    def get_read_count(self, book_id: str) -> int:
        return len(self.data.get("read_chapters", {}).get(book_id, []))
