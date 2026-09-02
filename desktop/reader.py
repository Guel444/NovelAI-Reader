"""
reader.py — Leitura de EPUB (Fase 1 — MVP), v3.

Abre um arquivo .epub com ebooklib, lista os capítulos na ORDEM REAL de
leitura (spine) e converte o HTML de cada capítulo em uma sequência
ordenada de "blocos": parágrafos de texto e imagens, na posição exata
em que aparecem no capítulo (pra arte aparecer no lugar certo na
leitura, não solta numa galeria separada).

Também filtra páginas que não são capítulo de verdade (capa, folha de
rosto, índice, copyright...) usando três sinais:
  1. item marcado como não-linear no spine (linear="no")
  2. tipo do item no <guide> do EPUB (cover, toc, title-page etc.)
  3. título/conteúdo curto batendo com palavras-chave de página de rosto
"""

import hashlib
import os
import posixpath

import ebooklib
from bs4 import BeautifulSoup
from ebooklib import epub

from style_classifier import classify as classify_style

# tags que contam como "bloco de texto" — nunca <div>, pra não duplicar
# o texto dos filhos que já foram capturados separadamente
TEXT_TAGS = ["p", "h1", "h2", "h3", "h4", "blockquote", "li"]
BLOCK_TAGS = TEXT_TAGS + ["img", "image"]

GUIDE_SKIP_TYPES = {
    "cover", "toc", "title-page", "titlepage", "copyright-page",
    "copyright", "dedication", "epigraph", "foreword", "preface",
    "loi", "lot", "notes", "bibliography", "glossary", "index",
    "colophon", "acknowledgements",
}

FRONT_MATTER_KEYWORDS = [
    "índice", "indice", "sumário", "sumario", "copyright",
    "direitos autorais", "informações", "informacoes",
    "table of contents", "contents", "title page", "folha de rosto",
    "sobre este livro", "sobre esta obra", "ficha catalográfica",
]
FRONT_MATTER_MAX_PARAGRAPHS = 8  # só descarta por palavra-chave se for curto


class Block:
    """Um pedaço de conteúdo do capítulo, na ordem em que aparece."""

    def __init__(self, kind: str, text: str = "", image: bytes | None = None,
                 style: str = "narration"):
        self.kind = kind  # "text" ou "image"
        self.text = text
        self.image = image
        self.style = style  # "narration" | "dialogue" | "thought" | "system"


class Chapter:
    def __init__(self, index: int, title: str, blocks: list[Block], item):
        self.index = index
        self.title = title
        self.blocks = blocks
        self.item = item  # item original do ebooklib, usado depois na exportação

    @property
    def paragraphs(self) -> list[str]:
        """Só o texto, na ordem — usado pelo tradutor, cache e exportação."""
        return [b.text for b in self.blocks if b.kind == "text"]


class RawEntry:
    """Um item candidato a capítulo, antes do filtro manual do usuário."""

    def __init__(self, name: str, title: str, blocks: list, item,
                 auto_front_matter: bool, preview: str):
        self.name = name  # href do item — identificador estável entre sessões
        self.title = title
        self.blocks = blocks
        self.item = item
        self.auto_front_matter = auto_front_matter
        self.preview = preview


class EpubReader:
    def __init__(self, path: str, excluded_item_names: set | None = None):
        self.path = path
        self.book_id = self._make_book_id(path)
        self.book = epub.read_epub(path)
        self._skip_hrefs = self._guide_skip_hrefs()
        self.raw_entries: list[RawEntry] = self._load_raw_entries()

        if excluded_item_names is None:
            excluded_item_names = {e.name for e in self.raw_entries if e.auto_front_matter}
        self.excluded_item_names: set = set(excluded_item_names)

        self.chapters: list[Chapter] = self._build_chapters()
        self.cover_bytes: bytes | None = self._extract_cover()
        self.image_bytes: list[bytes] = self._extract_all_images()

    @staticmethod
    def _make_book_id(path: str) -> str:
        name = os.path.basename(path)
        return hashlib.sha1(name.encode("utf-8")).hexdigest()[:12]

    # ---------- capítulos: candidatos + filtro (automático + manual) ----------

    def _guide_skip_hrefs(self) -> set[str]:
        """Hrefs marcados no <guide> do EPUB como capa/toc/rosto/etc."""
        skip = set()
        guide = getattr(self.book, "guide", None) or []
        for entry in guide:
            gtype = (entry.get("type") or "").lower()
            href = (entry.get("href") or "").split("#")[0]
            if gtype in GUIDE_SKIP_TYPES and href:
                skip.add(href)
        return skip

    def _load_raw_entries(self) -> list:
        """Todos os itens do spine com texto, na ordem de leitura, cada um
        já marcado se PARECE (heurística) página de rosto/índice/etc. —
        mas nenhum é descartado aqui; o descarte de fato é decidido por
        excluded_item_names (padrão = os marcados automaticamente)."""
        entries = []
        for item in self._spine_documents():
            if self._is_structurally_excluded(item):
                continue  # nav do EPUB, ou não-linear: nunca é capítulo de verdade

            html = item.get_content()
            soup = BeautifulSoup(html, "html.parser")
            blocks = self._extract_blocks(soup, item)
            text_blocks = [b for b in blocks if b.kind == "text"]
            if not text_blocks:
                continue  # página sem texto nenhum (ex.: só imagem de capa)

            title = self._guess_title(soup)
            auto_front_matter = (
                item.get_name() in self._skip_hrefs
                or self._looks_like_front_matter(title or "", text_blocks)
            )
            preview = " ".join(b.text for b in text_blocks[:2])[:140]
            entries.append(RawEntry(
                name=item.get_name(), title=title, blocks=blocks, item=item,
                auto_front_matter=auto_front_matter, preview=preview,
            ))
        return entries

    def _build_chapters(self) -> list:
        """Monta a lista final de capítulos, na ordem, atribuindo um
        título de reserva ('Capítulo N') SÓ com base na posição final
        (depois de excluir o que não é capítulo de verdade) — nunca na
        posição bruta do EPUB, senão excluir a página de informações não
        conserta a numeração dos capítulos que vêm depois dela."""
        chapters = []
        index = 0
        for entry in self.raw_entries:
            if entry.name in self.excluded_item_names:
                continue
            title = entry.title or f"Capítulo {index + 1}"
            chapters.append(Chapter(index, title, entry.blocks, entry.item))
            index += 1
        return chapters

    def set_excluded(self, excluded_item_names: set):
        """Reaplica o filtro de capítulos com uma escolha manual do
        usuário (ver ChapterManagerDialog no app.py)."""
        self.excluded_item_names = set(excluded_item_names)
        self.chapters = self._build_chapters()
        self.image_bytes = self._extract_all_images()

    def _spine_documents(self):
        """Itens de documento na ordem real de leitura (spine), pulando
        os marcados como não-lineares (linear='no': notas, extras etc.)."""
        id_to_item = {item.get_id(): item for item in self.book.get_items()}
        for spine_id, linear in self.book.spine:
            if linear == "no":
                continue
            item = id_to_item.get(spine_id)
            if item is not None and item.get_type() == ebooklib.ITEM_DOCUMENT:
                yield item

    @staticmethod
    def _is_structurally_excluded(item) -> bool:
        """Itens que NUNCA são capítulo de verdade (não entram nem na
        lista de gerenciamento manual): nav do EPUB3."""
        properties = getattr(item, "properties", []) or []
        if "nav" in properties:
            return True
        name = (item.get_name() or "").lower()
        return "nav" in name

    @staticmethod
    def _looks_like_front_matter(title: str, text_blocks: list) -> bool:
        if len(text_blocks) > FRONT_MATTER_MAX_PARAGRAPHS:
            return False  # capítulo "de verdade" costuma ter mais texto
        haystack = title.lower() + " " + " ".join(b.text.lower() for b in text_blocks[:3])
        return any(keyword in haystack for keyword in FRONT_MATTER_KEYWORDS)

    def _extract_blocks(self, soup: BeautifulSoup, item) -> list:
        body = soup.find("body") or soup
        elements = body.find_all(BLOCK_TAGS)
        blocks = []
        for el in elements:
            if el.name in ("img", "image"):
                data = self._resolve_image(el, item)
                if data:
                    blocks.append(Block(kind="image", image=data))
                continue
            # ignora um bloco de texto que só engloba outro já capturado
            if el.find(TEXT_TAGS):
                continue
            text = el.get_text(" ", strip=True)
            if not text:
                continue
            effective_tag = el.name
            if effective_tag not in ("em", "i"):
                # texto inteiro embrulhado num <em>/<i> interno (comum em
                # "pensamentos" marcados em itálico dentro de um <p>)
                em_child = el.find(["em", "i"])
                if em_child and em_child.get_text(" ", strip=True) == text:
                    effective_tag = em_child.name
            blocks.append(Block(kind="text", text=text, style=classify_style(text, effective_tag)))
        return blocks

    def _resolve_image(self, el, chapter_item) -> bytes | None:
        src = el.get("src") or el.get("xlink:href") or el.get("href")
        if not src:
            return None
        chapter_dir = posixpath.dirname(chapter_item.get_name())
        resolved = posixpath.normpath(posixpath.join(chapter_dir, src))
        img_item = self.book.get_item_with_href(resolved)
        if img_item is None:
            # alguns EPUBs guardam o href sem normalizar — tenta pelo nome puro
            base = posixpath.basename(src)
            for candidate in self.book.get_items_of_type(ebooklib.ITEM_IMAGE):
                if posixpath.basename(candidate.get_name()) == base:
                    img_item = candidate
                    break
        return img_item.get_content() if img_item else None

    @staticmethod
    def _guess_title(soup: BeautifulSoup) -> str | None:
        """Só usa um título de verdade encontrado no HTML — devolve None
        se não achar (o fallback numerado é decidido depois, na posição
        final da lista de capítulos, não aqui)."""
        for tag in ("h1", "h2", "title"):
            found = soup.find(tag)
            if found and found.get_text(strip=True):
                return found.get_text(strip=True)
        return None

    def get_chapter(self, index: int) -> Chapter:
        return self.chapters[index]

    def chapter_count(self) -> int:
        return len(self.chapters)

    def book_title(self) -> str:
        meta = self.book.get_metadata("DC", "title")
        if meta:
            return meta[0][0]
        return os.path.splitext(os.path.basename(self.path))[0]

    def book_author(self) -> str:
        meta = self.book.get_metadata("DC", "creator")
        if meta:
            return meta[0][0]
        return ""

    # ---------- capa e artes (pra tema visual e galeria) ----------

    def _extract_cover(self) -> bytes | None:
        for item in self.book.get_items_of_type(ebooklib.ITEM_COVER):
            return item.get_content()
        cover_meta = self.book.get_metadata("OPF", "cover")
        cover_id = cover_meta[0][1].get("content") if cover_meta else None
        if cover_id:
            item = self.book.get_item_with_id(cover_id)
            if item is not None:
                return item.get_content()
        for item in self.book.get_items_of_type(ebooklib.ITEM_IMAGE):
            if "cover" in (item.get_name() or "").lower():
                return item.get_content()
        return None

    def _extract_all_images(self) -> list:
        """Todas as imagens do livro, na ordem em que aparecem nos
        capítulos (não na ordem arbitrária do manifesto)."""
        seen = set()
        ordered = []
        for chapter in self.chapters:
            for block in chapter.blocks:
                if block.kind == "image" and block.image is not None:
                    key = hashlib.md5(block.image).hexdigest()
                    if key not in seen:
                        seen.add(key)
                        ordered.append(block.image)
        return ordered
