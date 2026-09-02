"""
share_card.py — Gera uma imagem "cartão" com uma citação grifada, pra
compartilhar em rede social (like Kindle faz). Usa Pillow, que já é
dependência do app (theme.py já usa pra cor da capa).

Estilo fixo (não segue o tema do app de propósito) — um cartão de
citação bonito funciona melhor com um visual próprio, elegante e
consistente, independente da cor da capa do livro que você estiver
lendo no momento.
"""

import io
import textwrap

from PIL import Image, ImageDraw, ImageFont

CARD_SIZE = (1080, 1080)
BG_COLOR = "#12131a"
ACCENT_COLOR = "#c9a34e"
TEXT_COLOR = "#f2f2f2"

FONT_CANDIDATES_REGULAR = [
    "arial.ttf", "Arial.ttf", "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]
FONT_CANDIDATES_ITALIC = [
    "ariali.ttf", "Arial Italic.ttf", "C:/Windows/Fonts/ariali.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Oblique.ttf",
]


def _load_font(candidates: list[str], size: int):
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except Exception:  # noqa: BLE001 — fonte não encontrada nesse sistema, tenta a próxima
            continue
    return ImageFont.load_default()


def generate_highlight_card(quote: str, book_title: str, author: str = "") -> Image.Image:
    img = Image.new("RGB", CARD_SIZE, BG_COLOR)
    draw = ImageDraw.Draw(img)

    quote_font = _load_font(FONT_CANDIDATES_REGULAR, 46)
    mark_font = _load_font(FONT_CANDIDATES_REGULAR, 140)
    meta_font = _load_font(FONT_CANDIDATES_ITALIC, 30)

    # aspas decorativas grandes, discretas, no canto superior
    draw.text((70, 40), "\u201c", font=mark_font, fill=ACCENT_COLOR)

    wrapped = textwrap.fill(quote.strip(), width=32)
    bbox = draw.multiline_textbbox((0, 0), wrapped, font=quote_font, spacing=16)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    x = (CARD_SIZE[0] - text_w) // 2
    y = (CARD_SIZE[1] - text_h) // 2 - 30
    draw.multiline_text((x, y), wrapped, font=quote_font, fill=TEXT_COLOR,
                         align="center", spacing=16)

    meta = f"— {book_title}"
    if author:
        meta += f", {author}"
    mbbox = draw.textbbox((0, 0), meta, font=meta_font)
    mx = (CARD_SIZE[0] - (mbbox[2] - mbbox[0])) // 2
    draw.text((mx, CARD_SIZE[1] - 150), meta, font=meta_font, fill=ACCENT_COLOR)

    # linha decorativa fina embaixo da citação
    line_y = CARD_SIZE[1] - 190
    draw.line((CARD_SIZE[0] // 2 - 60, line_y, CARD_SIZE[0] // 2 + 60, line_y),
              fill=ACCENT_COLOR, width=2)

    return img


def image_to_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()
