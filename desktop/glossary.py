"""
glossary.py — Glossário de termos (Fase 6).

Permite fixar a tradução de nomes próprios, lugares e termos específicos
de uma novel (ex.: "Dokkaebi" -> "Dokkaebi", "Constellation" -> "Constelação")
para que o tradutor automático não fique inconsistente entre capítulos.

Estratégia: antes de mandar o texto pro tradutor, cada termo do glossário
é trocado por um marcador único e ALFANUMÉRICO (sem símbolos incomuns,
tipo "XPROTECT7X"), porque tradutores automáticos às vezes alteram ou
"traduzem" símbolos exóticos como §§ — um marcador que parece uma palavra
qualquer tem muito mais chance de sobreviver intacto à tradução.
A comparação (tanto pra achar o termo no texto original quanto pra achar
o marcador de volta) ignora maiúsculas/minúsculas, porque um nome pode
aparecer com capitalização um pouco diferente em partes do texto.
"""

import json
import os
import re

GLOSSARY_PATH = os.path.join(os.path.dirname(__file__), "assets", "glossario.json")
MARKER_TEMPLATE = "XPROTECT{}X"


class Glossary:
    def __init__(self, path: str = GLOSSARY_PATH):
        self.path = path
        self.terms: dict[str, str] = {}
        self.load()

    def load(self):
        if os.path.exists(self.path):
            try:
                with open(self.path, "r", encoding="utf-8") as f:
                    self.terms = json.load(f)
            except (json.JSONDecodeError, OSError):
                self.terms = {}
        else:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            self.terms = {}
            self.save()

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(self.terms, f, ensure_ascii=False, indent=2)

    def add_term(self, original: str, translated: str):
        self.terms[original] = translated
        self.save()

    def remove_term(self, original: str):
        self.terms.pop(original, None)
        self.save()

    def suggest_terms(self, paragraphs: list[str], min_occurrences: int = 2,
                       max_suggestions: int = 40) -> list[str]:
        """
        Sugere possíveis nomes próprios/termos especiais pra manter sem
        tradução: palavras que começam com maiúscula E aparecem no MEIO
        de uma frase (não só no início, onde toda palavra vem maiúscula
        por gramática mesmo sem ser nome próprio), repetidas várias vezes.
        """
        counts: dict[str, int] = {}
        for paragraph in paragraphs:
            words = paragraph.split()
            for i, word in enumerate(words):
                cleaned = re.sub(r"^[^\w]+|[^\w]+$", "", word, flags=re.UNICODE)
                if not cleaned or i == 0 or len(cleaned) < 3:
                    continue
                if not cleaned[0].isupper() or cleaned.isupper():
                    continue  # ignora início de frase e siglas/tudo maiúsculo
                counts[cleaned] = counts.get(cleaned, 0) + 1

        already_known = {k.lower() for k in self.terms.keys()}
        candidates = [
            word for word, count in sorted(counts.items(), key=lambda kv: -kv[1])
            if count >= min_occurrences and word.lower() not in already_known
        ]
        return candidates[:max_suggestions]

    def protect(self, text: str) -> tuple[str, dict[str, str]]:
        """Substitui termos do glossário por marcadores antes da tradução
        (sem diferenciar maiúsculas/minúsculas na busca)."""
        placeholders = {}
        protected = text
        for i, (original, translated) in enumerate(self.terms.items()):
            pattern = re.compile(re.escape(original), re.IGNORECASE)
            if pattern.search(protected):
                marker = MARKER_TEMPLATE.format(i)
                placeholders[marker] = translated
                protected = pattern.sub(marker, protected)
        return protected, placeholders

    def restore(self, text: str, placeholders: dict[str, str]) -> str:
        """Troca os marcadores pelo termo já traduzido, após a tradução
        (sem diferenciar maiúsculas/minúsculas, caso o tradutor tenha
        alterado a capitalização do marcador)."""
        restored = text
        for marker, translated in placeholders.items():
            pattern = re.compile(re.escape(marker), re.IGNORECASE)
            restored = pattern.sub(translated, restored)
        return restored
