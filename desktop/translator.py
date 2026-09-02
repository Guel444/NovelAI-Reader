"""
translator.py — Motor de tradução (Fase 2), v3: tradução em LOTE.

Traduz parágrafos passando primeiro pelo glossário (Fase 6) e pelo
cache (Fase 5). Usa deep-translator (Google Translate) como backend
padrão, mas foi pensado pra trocar de backend no futuro sem mexer no
resto do app.

Mudança importante desta versão: antes, cada parágrafo virava UMA
chamada de API separada — um capítulo com 40 parágrafos = 40
chamadas. Em livros grandes (centenas de capítulos), isso soma
milhares de chamadas rapidamente e o Google Translate bloqueia
temporariamente por excesso de uso — o que na prática parecia o app
"travar" sem explicação nenhuma no meio da tradução em lote.

Agora os parágrafos que ainda não estão no cache são agrupados em
blocos (respeitando o limite de caracteres por chamada) e traduzidos
numa ÚNICA chamada por bloco, usando um separador que sobrevive à
tradução. Isso reduz drasticamente o número de chamadas de API.
"""

import time

# Lista curada de idiomas suportados pelo Google Translate (código, nome
# em português) — usada no seletor de idioma de destino em Configurações.
# É uma lista estática (não depende de chamar a API pra listar idiomas),
# então funciona mesmo sem internet até a hora de traduzir de verdade.
SUPPORTED_LANGUAGES = [
    ("pt", "Português"), ("en", "Inglês"), ("es", "Espanhol"),
    ("fr", "Francês"), ("de", "Alemão"), ("it", "Italiano"),
    ("ja", "Japonês"), ("ko", "Coreano"), ("zh-CN", "Chinês (simplificado)"),
    ("zh-TW", "Chinês (tradicional)"), ("ru", "Russo"), ("ar", "Árabe"),
    ("hi", "Hindi"), ("nl", "Holandês"), ("pl", "Polonês"),
    ("tr", "Turco"), ("vi", "Vietnamita"), ("th", "Tailandês"),
    ("id", "Indonésio"), ("sv", "Sueco"), ("no", "Norueguês"),
    ("da", "Dinamarquês"), ("fi", "Finlandês"), ("el", "Grego"),
    ("he", "Hebraico"), ("uk", "Ucraniano"), ("cs", "Tcheco"),
    ("ro", "Romeno"), ("hu", "Húngaro"), ("bg", "Búlgaro"),
    ("fa", "Persa"), ("ms", "Malaio"), ("bn", "Bengali"),
    ("ta", "Tâmil"), ("ur", "Urdu"), ("sr", "Sérvio"),
    ("hr", "Croata"), ("sk", "Eslovaco"), ("lt", "Lituano"),
    ("lv", "Letão"), ("et", "Estoniano"), ("sl", "Esloveno"),
    ("af", "Africâner"), ("sw", "Suaíli"), ("tl", "Filipino"),
]

from cache import TranslationCache
from glossary import Glossary

try:
    from deep_translator import GoogleTranslator
except ImportError:
    GoogleTranslator = None

MAX_RETRIES = 3
RETRY_DELAY_SECONDS = 1.5
CHUNK_SIZE = 4000  # limite prático da API gratuita do Google Translate
PARAGRAPH_SEPARATOR = "\n@@P@@\n"
SEPARATOR_TOKEN = "@@P@@"  # usado pra dividir de volta, tolerando espaços diferentes

# Sinais de que a resposta NÃO é uma tradução de verdade, e sim uma
# página de erro (ex.: Google bloqueando por excesso de chamadas) que
# a biblioteca engoliu sem lançar exceção.
ERROR_SIGNATURES = [
    "error 500", "server error", "that's an error", "that’s an error",
    "that's all we know", "that’s all we know", "502 bad gateway",
    "503 service unavailable", "429 too many requests", "<!doctype html",
    "<html", "access denied", "please try again later",
]


class TranslationError(Exception):
    pass


def _looks_like_error_page(text: str) -> bool:
    lowered = text.lower()
    return any(sig in lowered for sig in ERROR_SIGNATURES)


class Translator:
    def __init__(self, target_lang: str = "pt", cache: TranslationCache | None = None,
                 glossary: Glossary | None = None):
        self.target_lang = target_lang
        self.cache = cache or TranslationCache()
        self.glossary = glossary or Glossary()
        self.last_error: str | None = None
        self._backend_available = GoogleTranslator is not None

    def _new_backend(self):
        """Cria um cliente de tradução NOVO a cada chamada — este
        Translator é usado por mais de uma thread ao mesmo tempo
        (capítulo aberto + pré-tradução + fila do 'traduzir tudo'), e
        reaproveitar o MESMO cliente de rede entre threads não é seguro."""
        return GoogleTranslator(source="auto", target=self.target_lang)

    def _translate_chunk(self, text: str) -> str:
        last_exc = None
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                backend = self._new_backend()
                result = backend.translate(text)
                if result is None or not result.strip():
                    raise TranslationError("A API de tradução devolveu vazio.")
                if _looks_like_error_page(result):
                    raise TranslationError(
                        "O serviço de tradução respondeu com uma página de erro "
                        "(provavelmente bloqueio temporário por excesso de "
                        "requisições)."
                    )
                return result
            except Exception as exc:  # noqa: BLE001 — qualquer falha de rede/API
                last_exc = exc
                time.sleep(RETRY_DELAY_SECONDS * attempt)
        raise TranslationError(
            f"Não consegui traduzir depois de {MAX_RETRIES} tentativas "
            f"(verifique sua conexão, ou espere um pouco — o Google Translate "
            f"às vezes bloqueia temporariamente por excesso de chamadas). "
            f"Detalhe: {last_exc}"
        )

    def _call_backend(self, text: str) -> str:
        if not self._backend_available:
            raise TranslationError(
                "A biblioteca 'deep-translator' não está instalada. "
                "Rode: pip install deep-translator"
            )
        return self._translate_chunk(text)

    def _build_batches(self, texts: list[str]) -> list[list[str]]:
        """Agrupa textos em blocos que cabem no limite de caracteres por
        chamada, cada bloco virando UMA chamada de API em vez de uma
        por parágrafo."""
        batches: list[list[str]] = []
        current: list[str] = []
        current_len = 0
        for t in texts:
            t_len = len(t) + len(PARAGRAPH_SEPARATOR)
            if current and current_len + t_len > CHUNK_SIZE:
                batches.append(current)
                current = []
                current_len = 0
            current.append(t)
            current_len += t_len
        if current:
            batches.append(current)
        return batches

    def translate_paragraph(self, text: str, book_id: str = "",
                             chapter_index: int = -1) -> str:
        """Traduz um único parágrafo (usado fora do fluxo de capítulo,
        ex.: correção manual pontual). Pra capítulos inteiros, use
        translate_chapter — é bem mais eficiente em chamadas de API."""
        if not text.strip():
            return text

        cached = self.cache.get(text, self.target_lang)
        if cached is not None and not _looks_like_error_page(cached):
            return cached

        protected, placeholders = self.glossary.protect(text)
        translated = self._call_backend(protected)
        final = self.glossary.restore(translated, placeholders)

        self.cache.set(text, final, self.target_lang, book_id, chapter_index)
        return final

    def translate_chapter(self, paragraphs: list[str], book_id: str = "",
                           chapter_index: int = -1,
                           on_progress=None) -> list[str]:
        """
        Traduz uma lista de parágrafos, chamando on_progress(i, total)
        conforme avança. Parágrafos já em cache não geram chamada de
        API nenhuma; os que faltam são agrupados em blocos e traduzidos
        em poucas chamadas (em vez de uma por parágrafo). Se um bloco
        falhar, os parágrafos dele mantêm o texto original em vez de
        travar o capítulo inteiro.
        """
        total = len(paragraphs)
        results: list[str | None] = [None] * total
        pending_indices: list[int] = []
        pending_texts: list[str] = []

        for i, p in enumerate(paragraphs):
            if not p.strip():
                results[i] = p
                continue
            cached = self.cache.get(p, self.target_lang)
            if cached is not None and not _looks_like_error_page(cached):
                results[i] = cached
            else:
                pending_indices.append(i)
                pending_texts.append(p)

        done = total - len(pending_indices)
        if on_progress:
            on_progress(done, total)

        if not pending_texts:
            return results  # type: ignore[return-value]

        batches = self._build_batches(pending_texts)
        cursor = 0
        failures = 0
        last_error_local = None

        for batch in batches:
            protected_texts = []
            placeholders_list = []
            for t in batch:
                protected, placeholders = self.glossary.protect(t)
                protected_texts.append(protected)
                placeholders_list.append(placeholders)

            translated_parts: list[str | None]
            try:
                joined = PARAGRAPH_SEPARATOR.join(protected_texts)
                translated_joined = self._call_backend(joined)
                translated_parts = translated_joined.split(SEPARATOR_TOKEN)
                translated_parts = [p.strip() for p in translated_parts]
                if len(translated_parts) != len(batch):
                    # o separador não sobreviveu direitinho à tradução —
                    # cai pra tradução parágrafo a parágrafo SÓ deste bloco
                    translated_parts = []
                    for t in protected_texts:
                        try:
                            translated_parts.append(self._call_backend(t))
                        except TranslationError:
                            translated_parts.append(None)
            except TranslationError as exc:
                last_error_local = str(exc)
                translated_parts = [None] * len(batch)

            for original, placeholders, translated in zip(batch, placeholders_list, translated_parts):
                i = pending_indices[cursor]
                if translated is None:
                    results[i] = original
                    failures += 1
                else:
                    final = self.glossary.restore(translated, placeholders)
                    self.cache.set(original, final, self.target_lang, book_id, chapter_index)
                    results[i] = final
                cursor += 1
                done += 1
                if on_progress:
                    on_progress(done, total)

        if failures == len(pending_indices) and pending_indices:
            raise TranslationError(last_error_local or "Nenhum parágrafo foi traduzido.")

        return results  # type: ignore[return-value]

    def chapter_is_cached(self, paragraphs: list[str]) -> bool:
        for p in paragraphs:
            if not p.strip():
                continue
            cached = self.cache.get(p, self.target_lang)
            if cached is None or _looks_like_error_page(cached):
                return False
        return True
