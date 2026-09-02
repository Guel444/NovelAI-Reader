"""
plaintext_reader.py — Leitor de arquivos .txt e .pdf, com a MESMA
interface pública do EpubReader (reader.py) — mesmos atributos e
métodos (chapters, book_id, book_title(), get_chapter(), etc.) — pra
funcionar com o resto do app (biblioteca, capítulos, tradução, wiki,
grifos...) sem precisar duplicar nem adaptar nada em app.py.

Detecção de capítulo é heurística e simples de propósito: procura
linhas que parecem título de capítulo (ex.: "Capítulo 5", "Chapter
12"). Se não achar nenhuma, o arquivo inteiro vira um único capítulo —
melhor um livro com 1 capítulo gigante do que o app travar tentando
adivinhar demais a estrutura de um .txt sem marcação nenhuma.

Limitações honestas:
- Sem capa, sem imagens (esses formatos não têm isso do jeito que
  EPUB tem).
- Exportar como EPUB traduzido não funciona pra livros abertos assim
  (não tem uma estrutura de EPUB original pra reaproveitar) — o botão
  de exportar avisa isso em vez de travar.
- PDF escaneado (imagem, sem texto real) não vai extrair nada —
  precisa ser um PDF com texto selecionável.
"""

import hashlib
import os
import re

from reader import Block, Chapter, RawEntry
from style_classifier import classify as classify_style

CHAPTER_HEADING_PATTERN = re.compile(
    r"^\s*(chapter|cap[ií]tulo|cap\.?)\s*\d+.*$",
    re.IGNORECASE,
)

SUPPORTED_EXTENSIONS = (".txt", ".pdf")


def _split_into_chapters(full_text: str) -> list[tuple[str, list[str]]]:
    """Devolve [(título, [parágrafos]), ...]. Sem cabeçalho reconhecível
    em lugar nenhum, devolve um único capítulo com todo o conteúdo."""
    lines = full_text.splitlines()
    chapters: list[tuple[str, list[str]]] = []
    current_title: str | None = None
    current_paragraphs: list[str] = []
    buffer: list[str] = []

    def flush_paragraph():
        if buffer:
            text = " ".join(buffer).strip()
            if text:
                current_paragraphs.append(text)
            buffer.clear()

    def flush_chapter():
        flush_paragraph()
        if current_paragraphs:
            title = current_title or f"Capítulo {len(chapters) + 1}"
            chapters.append((title, list(current_paragraphs)))
        current_paragraphs.clear()

    for line in lines:
        stripped = line.strip()
        if CHAPTER_HEADING_PATTERN.match(stripped):
            flush_chapter()
            current_title = stripped
            continue
        if not stripped:
            flush_paragraph()
            continue
        buffer.append(stripped)
    flush_chapter()

    if not chapters:
        # nenhum cabeçalho de capítulo reconhecido: separa só por
        # parágrafo (linha em branco) e trata tudo como 1 capítulo
        paragraphs = [p.strip().replace("\n", " ")
                      for p in re.split(r"\n\s*\n", full_text) if p.strip()]
        if paragraphs:
            chapters = [("Capítulo único", paragraphs)]

    return chapters


class PlainTextReader:
    """Mesma interface pública do EpubReader, pra .txt e .pdf."""

    def __init__(self, path: str, excluded_item_names: set | None = None):
        self.path = path
        self.book_id = self._make_book_id(path)

        ext = os.path.splitext(path)[1].lower()
        if ext == ".pdf":
            full_text = self._extract_pdf_text(path)
        else:
            full_text = self._read_txt(path)

        raw_chapters = _split_into_chapters(full_text)
        self.raw_entries: list[RawEntry] = []
        for i, (title, paragraphs) in enumerate(raw_chapters):
            blocks = [
                Block(kind="text", text=p, style=classify_style(p))
                for p in paragraphs
            ]
            preview = paragraphs[0][:140] if paragraphs else ""
            self.raw_entries.append(RawEntry(
                name=f"chunk-{i}", title=title, blocks=blocks, item=None,
                auto_front_matter=False, preview=preview,
            ))

        if excluded_item_names is None:
            excluded_item_names = set()
        self.excluded_item_names: set = set(excluded_item_names)

        self.chapters: list[Chapter] = self._build_chapters()
        self.cover_bytes: bytes | None = None  # .txt/.pdf não têm capa
        self.image_bytes: list = []             # nem imagens internas

    @staticmethod
    def _make_book_id(path: str) -> str:
        name = os.path.basename(path)
        return hashlib.sha1(name.encode("utf-8")).hexdigest()[:12]

    @staticmethod
    def _read_txt(path: str) -> str:
        try:
            with open(path, "r", encoding="utf-8") as f:
                return f.read()
        except UnicodeDecodeError:
            # arquivo .txt salvo num encoding antigo (comum em textos
            # baixados de sites mais velhos) — tenta um fallback comum
            with open(path, "r", encoding="latin-1") as f:
                return f.read()

    @staticmethod
    def _extract_pdf_text(path: str) -> str:
        try:
            from pypdf import PdfReader as _PyPdfReader
        except ImportError as exc:
            raise RuntimeError(
                "A biblioteca 'pypdf' não está instalada. Rode: pip install pypdf"
            ) from exc
        reader = _PyPdfReader(path)
        pages_text = [page.extract_text() or "" for page in reader.pages]
        return "\n\n".join(pages_text)

    def _build_chapters(self) -> list[Chapter]:
        chapters = []
        index = 0
        for entry in self.raw_entries:
            if entry.name in self.excluded_item_names:
                continue
            chapters.append(Chapter(index, entry.title, entry.blocks, entry.item))
            index += 1
        return chapters

    def set_excluded(self, excluded_item_names: set):
        self.excluded_item_names = set(excluded_item_names)
        self.chapters = self._build_chapters()

    def get_chapter(self, index: int) -> Chapter:
        return self.chapters[index]

    def chapter_count(self) -> int:
        return len(self.chapters)

    def book_title(self) -> str:
        return os.path.splitext(os.path.basename(self.path))[0]

    def book_author(self) -> str:
        return ""
