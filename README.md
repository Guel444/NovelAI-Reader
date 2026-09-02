# NovelAI Reader

Leitor de novels (EPUB, TXT e PDF) com tradução automática embutida,
cache de tradução, glossário de termos, grifos, notas, favoritos e
estatísticas de leitura — sem depender de traduções prontas de
terceiros.

<p align="center">
  <a href="https://github.com/Guel444/novelai-reader/releases/latest">
    <img src="https://img.shields.io/badge/Download-Windows%20(.exe)-0078D6?style=for-the-badge&logo=windows&logoColor=white" alt="Baixar para Windows">
  </a>
  <a href="https://github.com/Guel444/novelai-reader/releases/latest">
    <img src="https://img.shields.io/badge/Download-Android%20(.apk)-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Baixar para Android">
  </a>
  <a href="https://discord.gg/vf22meZj9A">
    <img src="https://img.shields.io/badge/Discord-Entrar%20na%20comunidade-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Entrar no Discord">
  </a>
</p>

<p align="center">
  <a href="https://github.com/Guel444/novelai-reader/releases/latest">
    <img src="https://img.shields.io/github/v/release/Guel444/novelai-reader?style=flat-square&label=vers%C3%A3o" alt="Última versão">
  </a>
  <img src="https://img.shields.io/badge/plataformas-Windows%20%7C%20Android-informational?style=flat-square" alt="Plataformas">
  <img src="https://img.shields.io/badge/licença-MIT-lightgrey?style=flat-square" alt="Licença MIT">
</p>

## Duas versões, mesmas funcionalidades

| | Plataforma | Tecnologia | Código-fonte |
|---|---|---|---|
| 🖥️ **Desktop** | Windows / Linux / macOS* | Python + PySide6 (Qt) | [`desktop/`](desktop/) |
| 📱 **Mobile** | Android | Flutter / Dart | [`mobile/`](mobile/) |

<sub>* testado só em Windows; Linux/macOS devem funcionar (PySide6 é
multiplataforma) mas ainda não foram validados.</sub>

Cada pasta tem seu próprio README com instruções de instalação, uso e
como gerar o executável a partir do código — são projetos irmãos, não
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

Use os botões no topo desta página, ou vá direto na aba
**[Releases](https://github.com/Guel444/novelai-reader/releases/latest)**
deste repositório, pra baixar o `.exe` (Windows) ou `.apk` (Android)
mais recentes — sem precisar instalar nada além disso.

No Android, pode ser necessário permitir "instalar de fontes
desconhecidas" já que o app não vem da Play Store.

Se preferir rodar a partir do código-fonte (ou contribuir com o
projeto), siga o README da pasta correspondente.

## Comunidade

Dúvidas, sugestões, relatos de bug ou só pra bater papo sobre as
novels que você está lendo: [entre no Discord](https://discord.gg/vf22meZj9A).

## Limitações conhecidas

- PDF escaneado (imagem, sem OCR) ou com fontes incorporadas sem
  mapeamento de caracteres pode não extrair texto corretamente —
  nesses casos, converta pra EPUB antes (ex.: com o
  [Calibre](https://calibre-ebook.com/))
- Sem suporte a iOS por enquanto
- Build desktop validada só em Windows

## Licença

[MIT](LICENSE)
