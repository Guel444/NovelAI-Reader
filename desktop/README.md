# NovelAI Reader — Desktop

Leitor de EPUB/TXT/PDF com tradução automática embutida, em Python +
PySide6 (Qt).

## Funcionalidades

- Abre **EPUB**, **TXT** e **PDF**; detecção automática de capítulos
  (via spine do EPUB ou cabeçalhos reconhecidos em texto puro)
- Tradução automática por capítulo (Google Translate via
  `deep-translator`), com cache local em SQLite — cada trecho só é
  traduzido uma vez, mesmo trocando de capítulo e voltando
- Idioma de destino configurável (45+ idiomas)
- Glossário de termos: fixa a tradução de nomes próprios/termos
  específicos, com sugestão automática de candidatos
- Corrigir uma tradução específica direto na leitura, sem editar o
  arquivo
- Grifos com comentário, favoritos, notas por capítulo, biblioteca
  com histórico e capa
- Estatísticas de leitura (capítulos lidos, tempo estimado)
- Modo lado a lado (original + tradução) e modo foco
- Tema visual gerado a partir da cor dominante da capa do livro
- Exportar o livro traduzido como um EPUB novo
- Compartilhar um grifo como imagem
- Backup/restaurar tudo (biblioteca, favoritos, notas, grifos,
  glossário, preferências) num único arquivo

## Requisitos

- Python 3.10+
- Dependências em `requirements.txt`:
  `PySide6`, `ebooklib`, `beautifulsoup4`, `deep-translator`,
  `Pillow`, `pypdf`

## Rodando a partir do código-fonte

```bash
cd desktop
pip install -r requirements.txt
python app.py
```

## Gerando um executável (.exe no Windows)

O jeito mais simples é com o [PyInstaller](https://pyinstaller.org/):

```bash
pip install pyinstaller
pyinstaller --onefile --windowed --name "NovelAI Reader" --icon=assets/icon.ico --add-data "assets;assets" app.py
```

(No Linux/macOS troque `;` por `:` no `--add-data`.)

O `.exe` final aparece em `dist/NovelAI Reader.exe`. Esse comando
precisa rodar **no sistema operacional de destino** — pra gerar um
`.exe` do Windows, rode no Windows; PyInstaller não faz cross-compile.

Se o PyInstaller reclamar de algum plugin do Qt faltando, tente
adicionar `--collect-all PySide6` ao comando.

## Estrutura do código

| Arquivo | Responsabilidade |
|---|---|
| `app.py` | Interface gráfica (Qt) |
| `reader.py` | Parsing de EPUB (spine, capítulos, blocos) |
| `plaintext_reader.py` | Parsing de TXT/PDF |
| `translator.py` | Tradução em lote + retry + detecção de erro |
| `cache.py` | Cache de tradução em SQLite |
| `glossary.py` | Glossário de termos |
| `style_classifier.py` | Classificação visual de parágrafo |
| `theme.py` | Extração de cor da capa → tema |
| `export.py` | Exportar EPUB traduzido |
| `share_card.py` | Gerar imagem de grifo pra compartilhar |
| `config.py` | Persistência (biblioteca, favoritos, notas, grifos…) |

## Limitações conhecidas

- Precisa de internet pra traduzir um trecho pela primeira vez; sem
  conexão, só mostra o que já estiver em cache
- PDF escaneado (imagem, sem texto selecionável) não extrai texto
- Exportar como EPUB traduzido só funciona pra livros abertos como
  EPUB (TXT/PDF não têm uma estrutura de EPUB original pra reaproveitar)
- EPUBs muito fora do padrão (ex.: raspados de sites, com HTML
  bagunçado) podem precisar de ajuste na extração de parágrafos
