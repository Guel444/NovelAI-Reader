"""
translator.py — Motor de tradução (Fase 2), agora com 3 provedores.

Suporta 3 motores de tradução, escolhidos pelo usuário nas
configurações:
- Google Translate (via deep-translator, gratuito, sem chave, sem limite conhecido)
- DeepL (API oficial, tier gratuito com cota mensal de caracteres)
- Gemini (API oficial do Google, tier gratuito com cota diária de requisições —
  entende contexto/expressões idiomáticas melhor por ser um modelo de linguagem)

Se o motor escolhido não tiver chave configurada, ou estourar a cota
gratuita (detectado pelo HTTP de "sem créditos" de cada provedor), o
Translator cai automaticamente pro Google Translate e expõe um aviso
em `pending_fallback_notice` pra tela mostrar ao usuário (leia com
`take_fallback_notice()`). O esgotamento fica registrado no Config (se
fornecido), por provedor, com timestamp — pra não ficar tentando o
provedor esgotado de novo antes da cota ter chance de renovar.

Continua tudo passando primeiro pelo glossário e pelo cache. Parágrafos
que ainda não estão no cache são agrupados em blocos e traduzidos numa
ÚNICA chamada por bloco (com um separador que sobrevive à tradução),
em vez de uma chamada por parágrafo — evita bloqueio por excesso de
requisições em livros longos.
"""

import json
import time

# Lista curada de idiomas suportados — usada no seletor de idioma de
# destino em Configurações. É uma lista estática (não depende de
# chamar a API pra listar idiomas), então funciona mesmo sem internet
# até a hora de traduzir de verdade.
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

try:
    import requests
except ImportError:
    requests = None

# ---------- provedores ----------

PROVIDER_GOOGLE = "google"
PROVIDER_DEEPL = "deepl"
PROVIDER_GEMINI = "gemini"

PROVIDERS = [PROVIDER_GOOGLE, PROVIDER_DEEPL, PROVIDER_GEMINI]

PROVIDER_DISPLAY_NAMES = {
    PROVIDER_GOOGLE: "Google Translate",
    PROVIDER_DEEPL: "DeepL",
    PROVIDER_GEMINI: "Gemini",
}

PROVIDER_DESCRIPTIONS = {
    PROVIDER_GOOGLE: (
        "Gratuito, sem limite conhecido. Traduz frase a frase — expressões "
        "idiomáticas às vezes saem ao pé da letra."
    ),
    PROVIDER_DEEPL: (
        "Grátis até um teto de caracteres por mês (definido pela própria DeepL). "
        "Qualidade geralmente melhor que o Google."
    ),
    PROVIDER_GEMINI: (
        "Grátis com limite diário de requisições. Por ser um modelo de linguagem, "
        "entende melhor contexto e expressões idiomáticas."
    ),
}

PROVIDER_NEEDS_KEY = {PROVIDER_GOOGLE: False, PROVIDER_DEEPL: True, PROVIDER_GEMINI: True}

# Tempo aproximado até a cota gratuita renovar — usado só pra decidir
# quando vale tentar o provedor esgotado de novo, evitando bater na
# mesma parede a cada capítulo aberto. Não é garantia de quando o
# provedor renova de fato; é só uma folga razoável.
PROVIDER_QUOTA_RESET_SECONDS = {
    PROVIDER_DEEPL: 30 * 24 * 3600,
    PROVIDER_GEMINI: 24 * 3600,
}

# Mapeamento pros códigos de idioma que a API do DeepL espera (diferem
# em parte dos códigos acima). Idiomas ausentes daqui não são
# suportados pelo DeepL — o Translator cai pro Google automaticamente
# nesse caso. Cheque a documentação da DeepL de tempos em tempos, essa
# lista de idiomas suportados muda.
DEEPL_LANG_CODES = {
    "pt": "PT-BR", "en": "EN-US", "es": "ES", "fr": "FR", "de": "DE",
    "it": "IT", "ja": "JA", "ko": "KO", "zh-CN": "ZH", "ru": "RU",
    "nl": "NL", "pl": "PL", "tr": "TR", "id": "ID", "sv": "SV",
    "no": "NB", "da": "DA", "fi": "FI", "el": "EL", "uk": "UK",
    "cs": "CS", "ro": "RO", "hu": "HU", "bg": "BG", "sk": "SK",
    "lt": "LT", "lv": "LV", "et": "ET", "sl": "SL",
}

GEMINI_MODEL = "gemini-3-flash"
GEMINI_ENDPOINT = (
    f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"
)
DEEPL_ENDPOINT = "https://api-free.deepl.com/v2/translate"

MAX_RETRIES = 3
RETRY_DELAY_SECONDS = 1.5
CHUNK_SIZE = 4000  # limite prático por chamada
PARAGRAPH_SEPARATOR = "\n@@P@@\n"
SEPARATOR_TOKEN = "@@P@@"  # usado pra dividir de volta, tolerando espaços diferentes

# Sinais de que a resposta NÃO é uma tradução de verdade, e sim uma
# página de erro (ex.: bloqueio por excesso de chamadas) que a
# biblioteca/API engoliu sem lançar exceção.
ERROR_SIGNATURES = [
    "error 500", "server error", "that's an error",
    "that's all we know", "502 bad gateway",
    "503 service unavailable", "429 too many requests", "<!doctype html",
    "<html", "access denied", "please try again later",
]


class TranslationError(Exception):
    pass


class _QuotaExceededError(Exception):
    """Sinaliza especificamente "provedor sem créditos/cota agora" —
    tratado à parte de outros erros porque não adianta tentar de novo
    com o mesmo provedor: o Translator cai pro Google imediatamente."""

    def __init__(self, provider: str):
        super().__init__(provider)
        self.provider = provider


def _looks_like_error_page(text: str) -> bool:
    lowered = text.lower()
    return any(sig in lowered for sig in ERROR_SIGNATURES)


def _language_name_for(code: str) -> str:
    for c, name in SUPPORTED_LANGUAGES:
        if c == code:
            return name
    return code


class Translator:
    def __init__(self, target_lang: str = "pt", cache: TranslationCache | None = None,
                 glossary: Glossary | None = None, provider: str = PROVIDER_GOOGLE,
                 api_key: str | None = None, config=None):
        self.target_lang = target_lang
        self.cache = cache or TranslationCache()
        self.glossary = glossary or Glossary()
        self.provider = provider
        self.api_key = api_key
        # opcional — se fornecido (instância de config.Config), o
        # Translator consulta/atualiza aqui quando o provedor escolhido
        # estourar a cota, pra não insistir nele de novo antes da
        # janela de renovação passar.
        self.config = config
        self.last_error: str | None = None
        self._backend_available = GoogleTranslator is not None

        # Preenchido quando a última chamada precisou cair pro Google
        # por falta de chave/cota do motor escolhido. A tela lê isso
        # (com take_fallback_notice) pra avisar o usuário uma vez.
        self.pending_fallback_notice: str | None = None
        # Já caiu pro Google nesta instância nesta "sessão" de uso —
        # evita ficar testando de novo um provedor que a gente já sabe
        # que vai falhar, dentro do mesmo lote de tradução.
        self._session_fallback = False

    @classmethod
    def from_config(cls, config, cache: TranslationCache | None = None,
                     glossary: Glossary | None = None) -> "Translator":
        """Cria um Translator já configurado com o motor, idioma e
        chave de API escolhidos pelo usuário nas configurações."""
        provider = config.get("translation_provider", PROVIDER_GOOGLE)
        api_key = None
        if provider == PROVIDER_DEEPL:
            api_key = config.get("deepl_api_key", "") or None
        elif provider == PROVIDER_GEMINI:
            api_key = config.get("gemini_api_key", "") or None
        return cls(
            target_lang=config.get("target_language", "pt"),
            cache=cache, glossary=glossary,
            provider=provider, api_key=api_key, config=config,
        )

    def take_fallback_notice(self) -> str | None:
        """Lê e limpa o aviso de fallback pendente, se houver."""
        notice = self.pending_fallback_notice
        self.pending_fallback_notice = None
        return notice

    def reset_session_fallback(self):
        """Permite tentar o motor escolhido de novo (ex.: depois que o
        usuário trocou de provedor ou colou uma chave nova nas
        configurações), mesmo que esta instância já tivesse caído pro
        Google antes."""
        self._session_fallback = False

    def _new_backend(self):
        """Cria um cliente de tradução NOVO a cada chamada — este
        Translator é usado por mais de uma thread ao mesmo tempo
        (capítulo aberto + pré-tradução + fila do 'traduzir tudo'), e
        reaproveitar o MESMO cliente de rede entre threads não é seguro."""
        return GoogleTranslator(source="auto", target=self.target_lang)

    def _recently_exhausted(self, provider: str) -> bool:
        window = PROVIDER_QUOTA_RESET_SECONDS.get(provider)
        if window is None or self.config is None:
            return False
        exhausted_at = self.config.get_quota_exhausted_at(provider)
        if not exhausted_at:
            return False
        return (time.time() - exhausted_at) < window

    def _validate(self, result: str | None) -> str:
        if result is None or not result.strip():
            raise TranslationError("A API de tradução devolveu vazio.")
        if _looks_like_error_page(result):
            raise TranslationError(
                "O serviço de tradução respondeu com uma página de erro "
                "(provavelmente bloqueio temporário por excesso de requisições)."
            )
        return result

    def _call_google(self, text: str) -> str:
        if not self._backend_available:
            raise TranslationError(
                "A biblioteca 'deep-translator' não está instalada. "
                "Rode: pip install deep-translator"
            )
        backend = self._new_backend()
        return backend.translate(text)

    def _call_deepl(self, text: str) -> str:
        if requests is None:
            raise TranslationError(
                "A biblioteca 'requests' não está instalada. Rode: pip install requests"
            )
        deepl_target = DEEPL_LANG_CODES.get(self.target_lang)
        if deepl_target is None:
            # Idioma não suportado pela DeepL — não é questão de cota,
            # mas trata do mesmo jeito (cai pro Google) pra não travar
            # a leitura.
            self.pending_fallback_notice = (
                f"{_language_name_for(self.target_lang)} não é suportado pelo DeepL. "
                "Usando o Google Translate para este idioma."
            )
            self._session_fallback = True
            return self._call_google(text)

        response = requests.post(
            DEEPL_ENDPOINT,
            headers={"Authorization": f"DeepL-Auth-Key {self.api_key}"},
            data={"text": text, "target_lang": deepl_target},
            timeout=30,
        )
        if response.status_code in (456, 429):
            raise _QuotaExceededError(PROVIDER_DEEPL)
        if response.status_code == 403:
            raise TranslationError("Chave de API do DeepL inválida ou não autorizada.")
        if response.status_code != 200:
            raise TranslationError(f"DeepL respondeu HTTP {response.status_code}.")
        data = response.json()
        translations = data.get("translations") or []
        if not translations:
            raise TranslationError("DeepL não retornou nenhuma tradução.")
        return translations[0].get("text", "")

    def _call_gemini(self, text: str) -> str:
        if requests is None:
            raise TranslationError(
                "A biblioteca 'requests' não está instalada. Rode: pip install requests"
            )
        language_name = _language_name_for(self.target_lang)
        prompt = (
            f"Traduza o texto a seguir para {language_name}, mantendo o tom e o registro "
            "do original (inclusive gírias e expressões idiomáticas — adapte pro "
            f"equivalente natural em {language_name}, não traduza ao pé da letra). "
            "Preserve exatamente, sem traduzir ou alterar: quebras de linha, o marcador "
            f'"{SEPARATOR_TOKEN}" e qualquer trecho no formato XPROTECTnX (ex: XPROTECT0X, '
            "XPROTECT12X). Responda só com o texto traduzido, sem nenhum comentário, "
            f"explicação ou marcação extra.\n\n{text}"
        )
        response = requests.post(
            GEMINI_ENDPOINT,
            headers={"Content-Type": "application/json", "x-goog-api-key": self.api_key or ""},
            data=json.dumps({"contents": [{"parts": [{"text": prompt}]}]}),
            timeout=60,
        )
        if response.status_code == 429:
            raise _QuotaExceededError(PROVIDER_GEMINI)
        if response.status_code in (401, 403):
            raise TranslationError("Chave de API do Gemini inválida ou não autorizada.")
        if response.status_code != 200:
            raise TranslationError(f"Gemini respondeu HTTP {response.status_code}.")
        data = response.json()
        candidates = data.get("candidates") or []
        if not candidates:
            raise TranslationError("Gemini não retornou nenhum candidato de tradução.")
        parts = (candidates[0].get("content") or {}).get("parts") or []
        if not parts:
            raise TranslationError("Gemini retornou uma resposta vazia.")
        return parts[0].get("text", "")

    def _call_provider(self, provider: str, text: str) -> str:
        if provider == PROVIDER_DEEPL:
            return self._call_deepl(text)
        if provider == PROVIDER_GEMINI:
            return self._call_gemini(text)
        return self._call_google(text)

    def _translate_chunk(self, text: str) -> str:
        effective_provider = self.provider

        if self._session_fallback:
            effective_provider = PROVIDER_GOOGLE
        elif PROVIDER_NEEDS_KEY.get(self.provider) and not (self.api_key and self.api_key.strip()):
            effective_provider = PROVIDER_GOOGLE
            display = PROVIDER_DISPLAY_NAMES[self.provider]
            self.pending_fallback_notice = (
                f"Nenhuma chave configurada para {display}. Usando o Google Translate "
                f"por enquanto — adicione a chave nas configurações pra usar {display}."
            )
            self._session_fallback = True
        elif PROVIDER_NEEDS_KEY.get(self.provider) and self._recently_exhausted(self.provider):
            effective_provider = PROVIDER_GOOGLE
            display = PROVIDER_DISPLAY_NAMES[self.provider]
            self.pending_fallback_notice = (
                f"Os créditos gratuitos do {display} ainda não devem ter renovado. "
                "Usando o Google Translate por enquanto."
            )
            self._session_fallback = True

        last_exc = None
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                result = self._call_provider(effective_provider, text)
                return self._validate(result)
            except _QuotaExceededError as exc:
                # Não adianta insistir no mesmo provedor: registra o
                # esgotamento, avisa a tela e cai pro Google já nesta
                # mesma tentativa (sem contar como uma tentativa "gasta").
                if self.config is not None:
                    self.config.set_quota_exhausted(exc.provider)
                display = PROVIDER_DISPLAY_NAMES[exc.provider]
                self.pending_fallback_notice = (
                    f"Os créditos gratuitos do {display} acabaram por agora. Troquei "
                    "para o Google Translate automaticamente."
                )
                self._session_fallback = True
                effective_provider = PROVIDER_GOOGLE
                try:
                    result = self._call_provider(PROVIDER_GOOGLE, text)
                    return self._validate(result)
                except Exception as exc2:  # noqa: BLE001
                    last_exc = exc2
            except Exception as exc:  # noqa: BLE001 — qualquer falha de rede/API
                last_exc = exc
                time.sleep(RETRY_DELAY_SECONDS * attempt)
        raise TranslationError(
            f"Não consegui traduzir depois de {MAX_RETRIES} tentativas "
            f"(verifique sua conexão, ou espere um pouco — o serviço de tradução "
            f"às vezes bloqueia temporariamente por excesso de chamadas). "
            f"Detalhe: {last_exc}"
        )

    def _call_backend(self, text: str) -> str:
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
