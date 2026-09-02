# NovelAI Reader — Mobile

Leitor de EPUB/TXT/PDF com tradução automática embutida, em Flutter
(Android).

## Funcionalidades

- Abre **EPUB**, **TXT** e **PDF**; detecção automática de capítulos,
  com gerenciador manual pra corrigir quando a detecção erra
- Tradução automática por capítulo (Google Translate), com cache
  local em SQLite
- Idioma de destino configurável (45+ idiomas)
- Glossário de termos com sugestão automática de candidatos
- Corrigir uma tradução específica direto na leitura (toque simples
  num parágrafo já traduzido)
- Grifos com comentário (toque e segure num parágrafo) e destaque
  visual; compartilhar um grifo como imagem
- Favoritos, notas por capítulo, biblioteca com histórico
- Modo lado a lado (original + tradução) e modo foco
- Tema visual gerado a partir da cor dominante da capa do livro
- Exportar o livro traduzido como um EPUB novo
- Backup/restaurar tudo num único arquivo
- Funciona majoritariamente offline — só depende de internet pra
  traduzir um trecho pela primeira vez

## Baixar o APK pronto

Veja a aba **Releases** deste repositório.

## Rodando a partir do código-fonte

Requisitos: [Flutter SDK](https://docs.flutter.dev/get-started/install)
+ Android SDK (via Android Studio) instalados e configurados
(`flutter doctor` sem erros na parte de Android).

```bash
cd mobile
flutter pub get
flutter run
```

Se for a primeira vez rodando um app Flutter neste computador, ative
o modo desenvolvedor + depuração USB no celular e conecte por cabo
antes do `flutter run` (`flutter devices` deve listar o aparelho).

## Gerando um APK de release

```bash
flutter build apk --release
```

O arquivo fica em `build/app/outputs/flutter-apk/app-release.apk` —
pode instalar direto no celular ou anexar numa Release do GitHub.

## PDF: observação importante

A leitura de PDF usa `syncfusion_flutter_pdf`. Nem todo PDF tem texto
extraível de forma limpa — PDFs escaneados (imagem, sem OCR) ou com
fontes incorporadas sem mapeamento de caracteres podem abrir sem
texto ou com texto ilegível. O app detecta esses casos e avisa,
sugerindo converter o arquivo para EPUB antes (ex.: com o
[Calibre](https://calibre-ebook.com/), gratuito). PDFs com texto
"normal" funcionam bem.

Quebra de linha em PDF é reconstruída em parágrafo por heurística de
pontuação (uma linha só termina o parágrafo se acabar em `.`, `!`,
`?` etc.) — funciona bem na maioria dos casos, mas pode ocasionalmente
juntar ou separar um parágrafo errado em PDFs com formatação incomum.

## Estrutura do código

| Pasta | Conteúdo |
|---|---|
| `lib/models/` | Modelos de dados (livro, capítulo, bloco de conteúdo) |
| `lib/data/` | Parsers (EPUB/TXT/PDF), cache, glossário, config, exportação |
| `lib/services/` | Tradução |
| `lib/screens/` | Telas do app |
| `lib/widgets/` | Componentes reutilizáveis |
| `lib/theme/` | Paleta e tema visual |

## Limitações conhecidas

- Sem suporte a iOS (nunca testado; o projeto não tem `ios/`
  configurado além do que o Flutter gera por padrão)
- Ver observação sobre PDF acima
