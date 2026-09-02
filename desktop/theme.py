"""
theme.py — Tema visual por livro.

Extrai a cor dominante da capa do EPUB (via Pillow) e gera uma paleta
pra interface lembrar visualmente a novel aberta — do jeito que sites
de leitura costumam fazer.

Depois de testar, o ajuste é este: o "dinâmico por livro" fica no
FUNDO (um preto/branco levemente tingido do tom da capa, quase
imperceptível — não um flat cinza igual pra todo livro) e em detalhes
decorativos (botões, linha embaixo do título). O TEXTO da leitura em
si fica sempre uniforme (branco no escuro, preto no claro) — nada de
colorir palavras, que é ilegível e feio. Diferenciação de fala/sistema
é só negrito + itálico + centralização, sem cor.
"""

import colorsys
import io
from dataclasses import dataclass

from PIL import Image


@dataclass
class Palette:
    accent: str          # cor de destaque decorativa (botões, linha do título)
    accent_dark: str      # variante escura do destaque (bordas sutis)
    bg: str                # fundo da leitura — preto/branco com leve tingimento do livro
    surface: str            # fundo dos painéis (sidebar, toolbar) — um pouco mais claro que bg
    text: str                # cor do texto principal — SEMPRE uniforme, nunca colorida


DEFAULT_DARK = Palette(
    accent="#7c8cff", accent_dark="#4a55b3",
    bg="#0d0f14", surface="#171922", text="#e8e8ea",
)
DEFAULT_LIGHT = Palette(
    accent="#4a55b3", accent_dark="#333d8f",
    bg="#f7f7fb", surface="#ffffff", text="#1a1a1a",
)


def _dominant_color(image_bytes: bytes) -> tuple[int, int, int] | None:
    try:
        img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception:  # noqa: BLE001 — imagem corrompida ou formato exótico
        return None

    img = img.resize((64, 64))
    colors = img.getcolors(64 * 64) or []
    if not colors:
        return None

    # ignora tons quase-brancos/quase-pretos (bordas e fundos neutros de capa)
    def is_neutral(rgb):
        r, g, b = rgb
        return (max(r, g, b) - min(r, g, b)) < 18

    vivid = [(count, rgb) for count, rgb in colors if not is_neutral(rgb)]
    pool = vivid if vivid else colors
    pool.sort(reverse=True)
    return pool[0][1]


def _clamp(value: int) -> int:
    return max(0, min(255, value))


def _to_hex(rgb: tuple[int, int, int]) -> str:
    return "#{:02x}{:02x}{:02x}".format(*[_clamp(c) for c in rgb])


def _darken(rgb: tuple[int, int, int], factor: float = 0.6) -> tuple[int, int, int]:
    return tuple(_clamp(int(c * factor)) for c in rgb)


def _hsv_to_rgb255(h: float, s: float, v: float) -> tuple[int, int, int]:
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    return (_clamp(round(r * 255)), _clamp(round(g * 255)), _clamp(round(b * 255)))


def _tinted_backgrounds(rgb: tuple[int, int, int], dark_mode: bool) -> tuple[str, str]:
    """Fundo (bg) e painel (surface) quase pretos/brancos, com uma
    pitada bem sutil do tom da capa — o "dinâmico por livro" fica aqui,
    não na cor do texto. A saturação e o brilho ficam bem baixos (modo
    escuro) ou bem altos (modo claro) de propósito, pra continuar
    parecendo "preto"/"branco" à primeira vista, só um pouco diferente
    de livro pra livro."""
    r, g, b = (c / 255 for c in rgb)
    h, _, _ = colorsys.rgb_to_hsv(r, g, b)
    if dark_mode:
        bg = _hsv_to_rgb255(h, 0.22, 0.065)
        surface = _hsv_to_rgb255(h, 0.18, 0.11)
    else:
        bg = _hsv_to_rgb255(h, 0.05, 0.98)
        surface = _hsv_to_rgb255(h, 0.03, 1.0)
    return _to_hex(bg), _to_hex(surface)


def palette_from_cover(cover_bytes: bytes | None, dark_mode: bool) -> Palette:
    base = DEFAULT_DARK if dark_mode else DEFAULT_LIGHT
    if not cover_bytes:
        return base

    dominant = _dominant_color(cover_bytes)
    if dominant is None:
        return base

    accent = _to_hex(dominant)
    accent_dark = _to_hex(_darken(dominant, 0.55))
    bg, surface = _tinted_backgrounds(dominant, dark_mode)

    return Palette(
        accent=accent,
        accent_dark=accent_dark,
        bg=bg,
        surface=surface,
        text=base.text,
    )
