"""
style_classifier.py — Classifica cada parágrafo em só DUAS categorias
visuais, de propósito:

  - "highlighted": texto entre colchetes especiais (『』「」【】 ou
    colchete reto [...]) — comum em web novels tanto pra fala de
    Constelação/sistema quanto pra fala de personagem. Só marca
    "isso está destacado no original", SEM tentar adivinhar quem está
    falando — essa distinção não dá pra fazer de forma confiável só
    com pontuação, e errar isso confunde mais do que ajuda.
  - "narration": todo o resto — texto corrido normal.

Um terceiro caso, "italic", é preservado à parte: só quando o próprio
EPUB original já marcava o trecho como itálico (tag <em>/<i>) — isso é
reproduzir a formatação que já existia no livro, não um palpite novo.

Antes esse módulo tentava separar fala/pensamento/sistema por
pontuação e palavras-chave — na prática isso classificava fala de
personagem como se fosse "sistema/Dokkaebi falando", o que confundia
a leitura. Foi simplificado de propósito.
"""

import re

CORNER_BRACKETS = [("『", "』"), ("「", "」"), ("【", "】")]
BRACKET_PATTERN = re.compile(r"^[\[\(<].+[\]\)>]$")

STYLES = ("narration", "highlighted", "italic")


def classify(text: str, original_tag: str = "") -> str:
    stripped = text.strip()
    if not stripped:
        return "narration"

    for open_b, close_b in CORNER_BRACKETS:
        if stripped.startswith(open_b) and stripped.endswith(close_b):
            return "highlighted"

    if BRACKET_PATTERN.match(stripped):
        return "highlighted"

    if original_tag.lower() in ("em", "i", "cite"):
        return "italic"

    return "narration"
