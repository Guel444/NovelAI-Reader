# NovelAI Reader

Leitor de novels (EPUB, TXT e PDF) com tradução automática embutida,
cache de tradução, glossário de termos, grifos, notas, favoritos e
estatísticas de leitura — sem depender de traduções prontas de
terceiros.

Duas versões independentes neste repositório:

| | Plataforma | Tecnologia | Pasta |
|---|---|---|---|
| 🖥️ **Desktop** | Windows / Linux / macOS | Python + PySide6 (Qt) | [`desktop/`](desktop/) |
| 📱 **Mobile** | Android | Flutter / Dart | [`mobile/`](mobile/) |

Cada uma tem seu próprio README com instruções de instalação, uso e
como gerar o executável (`.exe` / `.apk`) — são projetos irmãos, não
compartilham código, mas cobrem o mesmo conjunto de funcionalidades.

## O que o app faz

- Abre **EPUB**, **TXT** e **PDF**, detectando os capítulos
  automaticamente (com gerenciador manual pra corrigir quando erra)
- Traduz cada capítulo automaticamente para o idioma que você
  escolher (45+ idiomas), com cache local — cada trecho só é
  traduzido uma vez
- Glossário de termos: fixa a tradução de nomes próprios e termos
  específicos da novel, pra ficar consistente entre capítulos
- Grifos com comentário, notas por capítulo, favoritos, biblioteca
  com histórico, estatísticas de leitura
- Tema visual que se adapta à cor da capa do livro
- Exporta o livro já traduzido como um EPUB novo
- Funciona majoritariamente offline — só precisa de internet pra
  traduzir um trecho pela primeira vez; depois de traduzido, fica
  salvo permanentemente

## Baixar pronto pra usar

Veja a aba **Releases** deste repositório para baixar o `.exe`
(Windows) ou `.apk` (Android) mais recentes, sem precisar instalar
nada além disso. Se preferir rodar a partir do código-fonte, siga o
README da pasta correspondente.

## Licença

[MIT](LICENSE) — ajuste se preferir outra licença.
