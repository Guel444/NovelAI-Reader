"""
export.py — Exportar EPUB traduzido (Fase 7).

Recebe o EPUB original e um dicionário {chapter_index: [parágrafos_traduzidos]}
e gera um novo arquivo .epub com o texto trocado, mantendo a estrutura,
capa e metadados do livro original sempre que possível.
"""

import os

from bs4 import BeautifulSoup
from ebooklib import epub

from reader import EpubReader, TEXT_TAGS

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "translations")


def _rebuild_chapter_html(original_html: bytes, translated_paragraphs: list[str]) -> bytes:
    soup = BeautifulSoup(original_html, "html.parser")
    body = soup.find("body") or soup
    blocks = body.find_all(TEXT_TAGS)

    # mesma lógica de reader.py._extract_paragraphs: só blocos "folha"
    # (que não engloba outro bloco de texto por dentro)
    text_blocks = [b for b in blocks if not b.find(TEXT_TAGS) and b.get_text(strip=True)]

    for block, translated in zip(text_blocks, translated_paragraphs):
        block.string = translated

    return str(soup).encode("utf-8")


def export_translated_epub(reader: EpubReader,
                            translations: dict[int, list[str]],
                            output_name: str | None = None) -> str:
    """
    reader: instância de EpubReader já carregada com o livro original.
    translations: {chapter_index: lista de parágrafos já traduzidos},
                   na mesma ordem retornada por reader.get_chapter(i).paragraphs.
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    for chapter in reader.chapters:
        if chapter.index not in translations:
            continue
        new_html = _rebuild_chapter_html(
            chapter.item.get_content(), translations[chapter.index]
        )
        chapter.item.set_content(new_html)

    if output_name is None:
        base = os.path.splitext(os.path.basename(reader.path))[0]
        output_name = f"{base}_ptbr.epub"

    output_path = os.path.join(OUTPUT_DIR, output_name)
    epub.write_epub(output_path, reader.book)
    return output_path
