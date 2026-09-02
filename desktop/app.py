"""
app.py — Interface gráfica do NovelAI Reader (Fase 3, 4, tema visual e Fase 8 parcial).

Roda com: python app.py

Novidades desta versão:
  - Sidebar com a capa do livro, título e autor.
  - Tema visual: a cor de destaque da interface é extraída da própria
    capa do EPUB (theme.py), do jeito que sites de leitura costumam
    fazer, além do tema claro/escuro de base.
  - Galeria de artes: mostra as imagens internas do EPUB (ilustrações).
  - Visual modernizado via QSS (bordas arredondadas, espaçamento,
    tipografia), em vez dos widgets padrão do Qt "crus".
  - Bugs de capítulo fora de ordem / texto embaralhado corrigidos em
    reader.py (agora usa a ordem real do spine e não duplica texto de
    <div> aninhado).
  - Tradutor com retry automático e mensagens de erro mais claras
    quando a tradução falha (translator.py).
"""

import base64
import io
import os
import sys

from PIL import Image
from PySide6.QtCore import Qt, QThread, Signal, QSize, QUrl, QTimer
from PySide6.QtGui import (
    QColor, QFont, QIcon, QImage, QKeySequence, QPainter, QPixmap, QShortcut,
    QTextDocument,
)
from PySide6.QtWidgets import (
    QApplication, QDialog, QFileDialog, QFormLayout, QComboBox, QSpinBox,
    QDoubleSpinBox, QCheckBox, QDialogButtonBox, QLabel, QLineEdit,
    QListWidget, QListWidgetItem, QMainWindow, QMessageBox, QProgressBar,
    QPushButton, QScrollArea, QStatusBar, QTextEdit, QToolBar,
    QVBoxLayout, QHBoxLayout, QWidget, QGridLayout, QFrame,
    QTableWidget, QTableWidgetItem, QHeaderView, QAbstractItemView,
)

from cache import TranslationCache
from config import Config
from export import export_translated_epub
from glossary import Glossary
from reader import EpubReader
from theme import Palette, palette_from_cover
from translator import Translator, SUPPORTED_LANGUAGES


PLACEHOLDER_COVER_STYLE = """
    background-color: {surface};
    border: 1px dashed {accent};
    border-radius: 8px;
    color: {accent};
"""

# tradução em segundo plano: pausa entre capítulos da fila (evita
# bater rápido demais no limite de chamadas do tradutor) e número de
# falhas seguidas antes de desistir e avisar o usuário
BACKGROUND_THROTTLE_MS = 1500
BACKGROUND_FAILURE_LIMIT = 3


class TranslateWorker(QThread):
    progress = Signal(int, int)
    finished_ok = Signal(int, list)
    failed = Signal(str)

    def __init__(self, translator: Translator, book_id: str,
                 chapter_index: int, paragraphs: list[str], parent=None):
        # IMPORTANTE: recebe um `parent` (a MainWindow) — sem isso, o
        # Python pode derrubar o objeto C++ da thread assim que solta a
        # última referência, mesmo que a thread já tenha avisado que
        # terminou (é exatamente o "QThread: Destroyed while thread is
        # still running"). Com um parent, quem decide a hora certa de
        # destruir é o Qt (via deleteLater), não o coletor de lixo do Python.
        super().__init__(parent)
        self.translator = translator
        self.book_id = book_id
        self.chapter_index = chapter_index
        self.paragraphs = paragraphs

    def run(self):
        try:
            result = self.translator.translate_chapter(
                self.paragraphs, self.book_id, self.chapter_index,
                on_progress=lambda i, total: self.progress.emit(i, total),
            )
            self.finished_ok.emit(self.chapter_index, result)
        except Exception as exc:  # noqa: BLE001
            self.failed.emit(str(exc))


class SettingsDialog(QDialog):
    """Fase 4 — Configurações de leitura."""

    def __init__(self, config: Config, parent=None):
        super().__init__(parent)
        self.config = config
        self.setWindowTitle("Configurações")
        self.setMinimumWidth(360)

        self.theme_box = QComboBox()
        self.theme_box.addItems(["dark", "light"])
        self.theme_box.setCurrentText(config.get("theme"))

        self.font_box = QComboBox()
        self.font_box.addItems(
            ["Arial", "Segoe UI", "Verdana", "Georgia", "Times New Roman", "Courier New"]
        )
        self.font_box.setCurrentText(config.get("font_family"))

        self.size_box = QSpinBox()
        self.size_box.setRange(10, 28)
        self.size_box.setValue(config.get("font_size"))

        self.spacing_box = QDoubleSpinBox()
        self.spacing_box.setRange(1.0, 3.0)
        self.spacing_box.setSingleStep(0.1)
        self.spacing_box.setValue(config.get("line_spacing"))

        self.margin_box = QSpinBox()
        self.margin_box.setRange(0, 200)
        self.margin_box.setValue(config.get("margin"))

        self.auto_translate_box = QCheckBox("Traduzir automaticamente ao abrir capítulo")
        self.auto_translate_box.setChecked(config.get("auto_translate"))

        self.cover_theme_box = QCheckBox("Usar cor da capa como destaque da interface")
        self.cover_theme_box.setChecked(config.get("use_cover_theme", True))

        self.wpm_box = QSpinBox()
        self.wpm_box.setRange(50, 600)
        self.wpm_box.setSingleStep(10)
        self.wpm_box.setValue(config.get("reading_wpm", 200))

        self.target_lang_box = QComboBox()
        current_lang = config.get("target_language", "pt")
        selected_index = 0
        for i, (code, name) in enumerate(SUPPORTED_LANGUAGES):
            self.target_lang_box.addItem(f"{name} ({code})", code)
            if code == current_lang:
                selected_index = i
        self.target_lang_box.setCurrentIndex(selected_index)

        form = QFormLayout()
        form.addRow("Tema", self.theme_box)
        form.addRow("Fonte", self.font_box)
        form.addRow("Tamanho da letra", self.size_box)
        form.addRow("Espaçamento entre linhas", self.spacing_box)
        form.addRow("Margens (px)", self.margin_box)
        form.addRow(self.auto_translate_box)
        form.addRow(self.cover_theme_box)
        form.addRow("Velocidade de leitura (palavras/min)", self.wpm_box)
        form.addRow("Traduzir para", self.target_lang_box)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(buttons)

    def apply(self):
        self.config.set("theme", self.theme_box.currentText())
        self.config.set("font_family", self.font_box.currentText())
        self.config.set("font_size", self.size_box.value())
        self.config.set("line_spacing", self.spacing_box.value())
        self.config.set("margin", self.margin_box.value())
        self.config.set("auto_translate", self.auto_translate_box.isChecked())
        self.config.set("use_cover_theme", self.cover_theme_box.isChecked())
        self.config.set("reading_wpm", self.wpm_box.value())
        self.config.set("target_language", self.target_lang_box.currentData())


class LibraryDialog(QDialog):
    """Estante visual: grade com as capas dos livros já abertos antes,
    pra reabrir com um clique em vez de navegar no seletor de arquivo."""

    COVER_SIZE = QSize(120, 176)

    def __init__(self, config: Config, parent=None):
        super().__init__(parent)
        self.config = config
        self.chosen_path: str | None = None
        self.setWindowTitle("Biblioteca")
        self.resize(560, 560)

        self.list_widget = QListWidget()
        self.list_widget.setViewMode(QListWidget.IconMode)
        self.list_widget.setIconSize(self.COVER_SIZE)
        self.list_widget.setGridSize(QSize(150, 230))
        self.list_widget.setResizeMode(QListWidget.Adjust)
        self.list_widget.setMovement(QListWidget.Static)
        self.list_widget.setSpacing(12)
        self.list_widget.setWordWrap(True)
        self.list_widget.setUniformItemSizes(True)
        self._reload()
        self.list_widget.itemDoubleClicked.connect(self._choose_and_accept)

        open_btn = QPushButton("Abrir selecionado")
        open_btn.clicked.connect(self._choose_and_accept)
        remove_btn = QPushButton("Remover da biblioteca")
        remove_btn.clicked.connect(self._remove_selected)

        buttons_row = QHBoxLayout()
        buttons_row.addWidget(open_btn)
        buttons_row.addWidget(remove_btn)

        layout = QVBoxLayout(self)
        layout.addWidget(QLabel("Livros já abertos:"))
        layout.addWidget(self.list_widget, 1)
        layout.addLayout(buttons_row)

        if self.list_widget.count() == 0:
            layout.addWidget(QLabel("Nenhum livro na biblioteca ainda — abra um EPUB primeiro."))

    def _reload(self):
        self.list_widget.clear()
        for entry in self.config.get_library():
            label = entry["title"]
            if entry.get("author"):
                label += f"\n{entry['author']}"
            item = QListWidgetItem(label)
            item.setData(Qt.UserRole, entry)
            item.setTextAlignment(Qt.AlignHCenter | Qt.AlignTop)

            pixmap = None
            thumb = entry.get("cover_thumb")
            if thumb:
                candidate = QPixmap()
                candidate.loadFromData(base64.b64decode(thumb))
                if not candidate.isNull():
                    pixmap = candidate
            if pixmap is None:
                pixmap = self._placeholder_cover(entry["title"])
            item.setIcon(QIcon(pixmap))
            self.list_widget.addItem(item)

    def _placeholder_cover(self, title: str) -> QPixmap:
        """Gera uma 'lombada' simples pra livro sem capa, pra estante
        não ficar com buracos em branco."""
        w, h = self.COVER_SIZE.width(), self.COVER_SIZE.height()
        pixmap = QPixmap(w, h)
        pixmap.fill(Qt.transparent)
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setBrush(QColor("#33384a"))
        painter.setPen(QColor("#5a6180"))
        painter.drawRoundedRect(1, 1, w - 2, h - 2, 8, 8)
        painter.setPen(QColor("#c8cbe0"))
        painter.setFont(QFont("Arial", 9, QFont.DemiBold))
        text_rect = pixmap.rect().adjusted(8, 8, -8, -8)
        painter.drawText(text_rect, Qt.AlignCenter | Qt.TextWordWrap, title[:60])
        painter.end()
        return pixmap

    def _choose_and_accept(self):
        item = self.list_widget.currentItem()
        if not item:
            return
        entry = item.data(Qt.UserRole)
        self.chosen_path = entry["path"]
        self.accept()

    def _remove_selected(self):
        item = self.list_widget.currentItem()
        if not item:
            return
        entry = item.data(Qt.UserRole)
        self.config.remove_from_library(entry["book_id"])
        self._reload()


class EditTranslationDialog(QDialog):
    """Corrige manualmente a tradução de um parágrafo específico — a
    correção fica salva no cache pra sempre, sem precisar de IA paga."""

    def __init__(self, original_text: str, translated_text: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Corrigir tradução")
        self.resize(480, 340)

        original_label = QLabel(f"Original: \u201c{original_text[:200]}"
                                 f"{'…' if len(original_text) > 200 else ''}\u201d")
        original_label.setWordWrap(True)
        original_label.setStyleSheet("font-style: italic; opacity: 0.75;")

        self.translation_edit = QTextEdit()
        self.translation_edit.setPlainText(translated_text)

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addWidget(original_label)
        layout.addWidget(QLabel("Tradução (edite como quiser):"))
        layout.addWidget(self.translation_edit, 1)
        layout.addWidget(buttons)

    def translated_text(self) -> str:
        return self.translation_edit.toPlainText()


class HighlightCommentDialog(QDialog):
    """Confirma um trecho selecionado como grifo, com comentário opcional."""

    def __init__(self, selected_text: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Grifar trecho")
        self.resize(420, 280)

        preview = QLabel(f"\u201c{selected_text[:220]}"
                          f"{'…' if len(selected_text) > 220 else ''}\u201d")
        preview.setWordWrap(True)
        preview.setStyleSheet("font-style: italic;")

        self.comment_edit = QTextEdit()
        self.comment_edit.setPlaceholderText("Comentário sobre esse trecho (opcional)…")

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addWidget(QLabel("Trecho selecionado:"))
        layout.addWidget(preview)
        layout.addWidget(self.comment_edit, 1)
        layout.addWidget(buttons)

    def comment_text(self) -> str:
        return self.comment_edit.toPlainText()


class HighlightsDialog(QDialog):
    """Lista todos os grifos + comentários do livro aberto, com opção
    de pular pro capítulo ou remover."""

    def __init__(self, config: Config, epub_reader, parent=None):
        super().__init__(parent)
        self.config = config
        self.epub_reader = epub_reader
        self.selected_chapter: int | None = None
        self.setWindowTitle("Grifos e comentários")
        self.resize(480, 520)

        self.list_widget = QListWidget()
        self._reload()

        jump_btn = QPushButton("Ir para o capítulo")
        jump_btn.clicked.connect(self._jump_to)
        remove_btn = QPushButton("Remover")
        remove_btn.clicked.connect(self._remove_selected)
        share_btn = QPushButton("🖼️ Compartilhar como imagem")
        share_btn.clicked.connect(self._share_selected)

        row = QHBoxLayout()
        row.addWidget(jump_btn)
        row.addWidget(remove_btn)
        row.addWidget(share_btn)

        layout = QVBoxLayout(self)
        layout.addWidget(self.list_widget, 1)
        layout.addLayout(row)

    def _reload(self):
        self.list_widget.clear()
        all_highlights = self.config.get_all_highlights(self.epub_reader.book_id)
        for chapter_index_str, items in all_highlights.items():
            chapter_index = int(chapter_index_str)
            if chapter_index >= self.epub_reader.chapter_count():
                continue
            chapter = self.epub_reader.get_chapter(chapter_index)
            for position, h in enumerate(items):
                label = f"{chapter.title}\n\u201c{h['text'][:70]}\u201d"
                if h.get("comment"):
                    label += f"\n💬 {h['comment'][:100]}"
                item = QListWidgetItem(label)
                item.setData(Qt.UserRole, (chapter_index, position))
                self.list_widget.addItem(item)
        if self.list_widget.count() == 0:
            placeholder = QListWidgetItem(
                "Nenhum grifo ainda — selecione um trecho na leitura e clique em 🖍 Grifar."
            )
            placeholder.setFlags(Qt.NoItemFlags)
            self.list_widget.addItem(placeholder)

    def _current_data(self):
        item = self.list_widget.currentItem()
        if not item:
            return None
        return item.data(Qt.UserRole)

    def _jump_to(self):
        data = self._current_data()
        if not data:
            return
        chapter_index, _position = data
        self.selected_chapter = chapter_index
        self.accept()

    def _remove_selected(self):
        data = self._current_data()
        if not data:
            return
        chapter_index, position = data
        self.config.remove_highlight(self.epub_reader.book_id, chapter_index, position)
        self._reload()

    def _share_selected(self):
        data = self._current_data()
        if not data:
            QMessageBox.information(self, "Nada selecionado", "Selecione um grifo primeiro.")
            return
        chapter_index, position = data
        highlights = self.config.get_highlights(self.epub_reader.book_id, chapter_index)
        if position >= len(highlights):
            return
        highlight = highlights[position]

        from share_card import generate_highlight_card
        img = generate_highlight_card(
            highlight["text"], self.epub_reader.book_title(), self.epub_reader.book_author(),
        )

        path, _ = QFileDialog.getSaveFileName(
            self, "Salvar imagem do grifo", "grifo.png", "PNG (*.png)"
        )
        if not path:
            return
        try:
            img.save(path)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Erro ao salvar imagem", str(exc))
            return
        QMessageBox.information(self, "Imagem salva", f"Cartão do grifo salvo em:\n{path}")


class NoteDialog(QDialog):
    """Nota livre presa a um capítulo específico."""

    def __init__(self, chapter_title: str, existing_text: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"Nota — {chapter_title}")
        self.resize(420, 260)

        self.text_edit = QTextEdit()
        self.text_edit.setPlainText(existing_text)
        self.text_edit.setPlaceholderText("Escreva uma nota sobre este capítulo…")

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addWidget(self.text_edit)
        layout.addWidget(buttons)

    def note_text(self) -> str:
        return self.text_edit.toPlainText()


class SummaryDialog(QDialog):
    """Visão geral do livro inteiro: todos os capítulos numa tabela só,
    com status de lido/favorito/nota/grifos — pra achar rápido algo
    específico sem navegar capítulo por capítulo."""

    COLUMNS = ["#", "Capítulo", "✓ Lido", "⭐ Favorito", "📝 Nota", "🖍 Grifos"]

    def __init__(self, config: Config, epub_reader, parent=None):
        super().__init__(parent)
        self.config = config
        self.epub_reader = epub_reader
        self.selected_chapter: int | None = None
        self.setWindowTitle(f"Sumário — {epub_reader.book_title()}")
        self.resize(620, 560)

        book_id = epub_reader.book_id
        total = epub_reader.chapter_count()
        read = self.config.get_read_count(book_id)
        favorites = len(self.config.get_favorites(book_id))
        highlights_total = sum(
            len(items) for items in self.config.get_all_highlights(book_id).values()
        )
        stats_label = QLabel(
            f"📊 {read}/{total} capítulos lidos  •  ⭐ {favorites} favoritos  •  "
            f"🖍 {highlights_total} grifos"
        )
        stats_label.setStyleSheet("font-weight: 600; padding: 4px 0;")

        self.table = QTableWidget(total, len(self.COLUMNS))
        self.table.setHorizontalHeaderLabels(self.COLUMNS)
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setSelectionBehavior(QAbstractItemView.SelectRows)
        self.table.verticalHeader().setVisible(False)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.Stretch)
        self.table.itemDoubleClicked.connect(self._jump_to)

        for row, chapter in enumerate(epub_reader.chapters):
            is_read = self.config.is_read(book_id, chapter.index)
            is_fav = self.config.is_favorite(book_id, chapter.index)
            has_note = self.config.has_note(book_id, chapter.index)
            n_highlights = len(self.config.get_highlights(book_id, chapter.index))

            values = [
                str(chapter.index + 1),
                chapter.title,
                "✓" if is_read else "",
                "⭐" if is_fav else "",
                "📝" if has_note else "",
                str(n_highlights) if n_highlights else "",
            ]
            for col, value in enumerate(values):
                item = QTableWidgetItem(value)
                if col in (0, 2, 3, 4, 5):
                    item.setTextAlignment(Qt.AlignCenter)
                item.setData(Qt.UserRole, chapter.index)
                self.table.setItem(row, col, item)

        jump_btn = QPushButton("Ir para o capítulo")
        jump_btn.clicked.connect(self._jump_to)

        layout = QVBoxLayout(self)
        layout.addWidget(stats_label)
        layout.addWidget(self.table, 1)
        layout.addWidget(jump_btn)

    def _jump_to(self):
        row = self.table.currentRow()
        if row < 0:
            return
        item = self.table.item(row, 0)
        if item is None:
            return
        self.selected_chapter = item.data(Qt.UserRole)
        self.accept()


class ChapterManagerDialog(QDialog):
    """
    Lista TODOS os itens de texto do EPUB (inclusive os que a heurística
    automática já descartou, tipo página de informações/índice) pra você
    marcar manualmente quais são capítulo de verdade. Resolve os casos
    em que a detecção automática erra pro seu livro específico.
    """

    def __init__(self, reader, parent=None):
        super().__init__(parent)
        self.reader = reader
        self.setWindowTitle("Gerenciar capítulos")
        self.resize(560, 560)

        self.list_widget = QListWidget()
        for entry in reader.raw_entries:
            label = entry.title or "(sem título — vira 'Capítulo N' automaticamente)"
            if entry.preview:
                label += f"  —  {entry.preview[:70]}…"
            item = QListWidgetItem(label)
            item.setFlags(item.flags() | Qt.ItemIsUserCheckable)
            included = entry.name not in reader.excluded_item_names
            item.setCheckState(Qt.Checked if included else Qt.Unchecked)
            item.setData(Qt.UserRole, entry.name)
            if entry.auto_front_matter:
                item.setToolTip("Descartado automaticamente (parece página de rosto/índice)")
            self.list_widget.addItem(item)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addWidget(QLabel(
            "Desmarque o que NÃO for capítulo de verdade (página de rosto, "
            "índice, créditos...) e marque o que a detecção automática "
            "descartou por engano:"
        ))
        layout.addWidget(self.list_widget, 1)
        layout.addWidget(buttons)

    def excluded_names(self) -> set:
        excluded = set()
        for i in range(self.list_widget.count()):
            item = self.list_widget.item(i)
            if item.checkState() != Qt.Checked:
                excluded.add(item.data(Qt.UserRole))
        return excluded


class GlossaryDialog(QDialog):
    """Gerencia o glossário (Fase 6) sem precisar editar o JSON na mão,
    com sugestão automática de nomes/termos do livro aberto."""

    def __init__(self, glossary: Glossary, epub_reader, parent=None):
        super().__init__(parent)
        self.glossary = glossary
        self.epub_reader = epub_reader
        self.setWindowTitle("Glossário de termos")
        self.resize(460, 520)

        self.term_list = QListWidget()
        self._reload_list()

        self.original_input = QLineEdit()
        self.original_input.setPlaceholderText("Termo original (ex.: Dokkaebi)")
        self.translated_input = QLineEdit()
        self.translated_input.setPlaceholderText("Manter como (ex.: Dokkaebi)")
        add_btn = QPushButton("Adicionar")
        add_btn.clicked.connect(self.add_term)

        add_row = QHBoxLayout()
        add_row.addWidget(self.original_input)
        add_row.addWidget(self.translated_input)
        add_row.addWidget(add_btn)

        remove_btn = QPushButton("Remover selecionado")
        remove_btn.clicked.connect(self.remove_selected)

        suggest_btn = QPushButton("🔍 Sugerir nomes do livro aberto")
        suggest_btn.clicked.connect(self.suggest_terms)

        note = QLabel(
            "Termos adicionados só valem pra traduções feitas a partir de agora. "
            "Se um capítulo já foi traduzido antes, use 🧹 Limpar cache pra "
            "traduzir de novo com o termo protegido."
        )
        note.setWordWrap(True)

        layout = QVBoxLayout(self)
        layout.addWidget(QLabel("Termos que o tradutor deve manter como estão:"))
        layout.addWidget(self.term_list, 1)
        layout.addLayout(add_row)
        layout.addWidget(remove_btn)
        layout.addWidget(suggest_btn)
        layout.addWidget(note)

    def _reload_list(self):
        self.term_list.clear()
        for original, translated in self.glossary.terms.items():
            self.term_list.addItem(f"{original}  →  {translated}")

    def add_term(self):
        original = self.original_input.text().strip()
        if not original:
            return
        translated = self.translated_input.text().strip() or original
        self.glossary.add_term(original, translated)
        self._reload_list()
        self.original_input.clear()
        self.translated_input.clear()

    def remove_selected(self):
        item = self.term_list.currentItem()
        if not item:
            return
        original = item.text().split("  →  ")[0]
        self.glossary.remove_term(original)
        self._reload_list()

    def suggest_terms(self):
        if self.epub_reader is None:
            QMessageBox.information(self, "Nenhum livro aberto", "Abra um EPUB primeiro.")
            return
        all_paragraphs = [p for ch in self.epub_reader.chapters for p in ch.paragraphs]
        suggestions = self.glossary.suggest_terms(all_paragraphs)
        if not suggestions:
            QMessageBox.information(
                self, "Nada encontrado",
                "Não encontrei candidatos novos (ou eles já estão no glossário).",
            )
            return
        picker = SuggestionPickerDialog(suggestions, self)
        if picker.exec() == QDialog.Accepted:
            for term in picker.selected_terms():
                self.glossary.add_term(term, term)
            self._reload_list()


class SuggestionPickerDialog(QDialog):
    """Lista de candidatos a termo do glossário, com checkbox pra escolher quais manter."""

    def __init__(self, suggestions: list[str], parent=None):
        super().__init__(parent)
        self.setWindowTitle("Escolha os termos para manter sem tradução")
        self.resize(360, 460)

        self.list_widget = QListWidget()
        for word in suggestions:
            item = QListWidgetItem(word)
            item.setFlags(item.flags() | Qt.ItemIsUserCheckable)
            item.setCheckState(Qt.Checked)
            self.list_widget.addItem(item)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        layout = QVBoxLayout(self)
        layout.addWidget(QLabel(
            "Encontrei estas palavras repetidas com maiúscula no meio da frase — "
            "provavelmente nomes de personagem/lugar. Desmarque o que não for:"
        ))
        layout.addWidget(self.list_widget, 1)
        layout.addWidget(buttons)

    def selected_terms(self) -> list[str]:
        result = []
        for i in range(self.list_widget.count()):
            item = self.list_widget.item(i)
            if item.checkState() == Qt.Checked:
                result.append(item.text())
        return result


class CharacterWikiDialog(QDialog):
    """Fichinha de cada termo do glossário: nome, primeira aparição no
    livro, e quantas vezes é mencionado — um 'quem é quem' gerado
    sozinho a partir do glossário, sem precisar cadastrar nada extra."""

    def __init__(self, glossary: Glossary, epub_reader, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"Wiki de personagens — {epub_reader.book_title()}")
        self.resize(520, 560)

        self.list_widget = QListWidget()
        entries = self._build_entries(glossary, epub_reader)
        for term, translated, first_chapter_title, count in entries:
            label = translated
            if translated.lower() != term.lower():
                label += f"  (original: {term})"
            label += f"\nPrimeira aparição: {first_chapter_title}\n{count}x mencionado no livro"
            self.list_widget.addItem(QListWidgetItem(label))
        if not entries:
            placeholder = QListWidgetItem(
                "Nenhum termo no glossário ainda, ou nenhum deles aparece no texto original. "
                "Adicione termos em 📚 Glossário primeiro."
            )
            placeholder.setFlags(Qt.NoItemFlags)
            self.list_widget.addItem(placeholder)

        layout = QVBoxLayout(self)
        layout.addWidget(QLabel(
            "Nomes e termos da obra, gerados a partir do glossário "
            "(mais mencionados primeiro):"
        ))
        layout.addWidget(self.list_widget, 1)

        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(self.reject)
        buttons.accepted.connect(self.accept)
        layout.addWidget(buttons)

    @staticmethod
    def _build_entries(glossary: Glossary, epub_reader) -> list[tuple[str, str, str, int]]:
        entries = []
        for term, translated in glossary.terms.items():
            term_lower = term.lower()
            first_chapter_title = None
            count = 0
            for chapter in epub_reader.chapters:
                chapter_count = sum(p.lower().count(term_lower) for p in chapter.paragraphs)
                if chapter_count:
                    count += chapter_count
                    if first_chapter_title is None:
                        first_chapter_title = chapter.title
            if first_chapter_title is not None:
                entries.append((term, translated, first_chapter_title, count))
        entries.sort(key=lambda e: -e[3])
        return entries


class GalleryDialog(QDialog):
    """Mostra as artes/ilustrações extraídas do EPUB."""

    def __init__(self, image_bytes_list: list[bytes], parent=None):
        super().__init__(parent)
        self.setWindowTitle("Artes da novel")
        self.resize(700, 600)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        container = QWidget()
        grid = QGridLayout(container)

        shown = 0
        for data in image_bytes_list:
            pixmap = QPixmap()
            if not pixmap.loadFromData(data):
                continue
            if pixmap.width() < 80 or pixmap.height() < 80:
                continue  # ignora ícones pequenos (bullets, separadores etc.)
            label = QLabel()
            label.setPixmap(
                pixmap.scaled(200, 280, Qt.KeepAspectRatio, Qt.SmoothTransformation)
            )
            label.setAlignment(Qt.AlignCenter)
            grid.addWidget(label, shown // 3, shown % 3)
            shown += 1

        layout = QVBoxLayout(self)
        if shown == 0:
            layout.addWidget(QLabel("Este EPUB não tem imagens internas além da capa."))
        else:
            scroll.setWidget(container)
            layout.addWidget(scroll)


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("NovelAI Reader")
        self.resize(1180, 760)
        icon_path = os.path.join(os.path.dirname(__file__), "assets", "icon.ico")
        if os.path.exists(icon_path):
            self.setWindowIcon(QIcon(icon_path))

        self.config = Config()
        self.cache = TranslationCache()
        self.glossary = Glossary()
        self.translator = Translator(
            target_lang=self.config.get("target_language"), cache=self.cache,
            glossary=self.glossary,
        )

        self.epub_reader: EpubReader | None = None
        self.current_chapter_index = 0
        self.translated_chapters: dict[int, list[str]] = {}
        self.worker: TranslateWorker | None = None
        self.background_worker: TranslateWorker | None = None
        self.background_queue: list = []
        self.background_consecutive_failures = 0
        self.block_to_paragraph_index: dict[int, int] = {}
        self.palette_: Palette = palette_from_cover(None, self.config.get("theme") == "dark")

        self._build_ui()
        self._apply_theme()

    # ---------- construção da interface ----------

    def _build_ui(self):
        toolbar = QToolBar("Principal")
        toolbar.setMovable(False)
        toolbar.setIconSize(QSize(18, 18))
        self.addToolBar(toolbar)
        self.toolbar = toolbar

        toolbar.addAction("📖 Abrir livro", self.open_epub)
        toolbar.addAction("🗂 Biblioteca", self.open_library)
        toolbar.addAction("🧭 Capítulos", self.open_chapter_manager)
        toolbar.addAction("🧾 Sumário", self.open_summary)
        toolbar.addAction("📔 Wiki", self.open_wiki)
        toolbar.addAction("🎨 Artes", self.open_gallery)
        toolbar.addAction("📚 Glossário", self.open_glossary)
        toolbar.addAction("🖍 Grifar", self.highlight_selection)
        toolbar.addAction("✏️ Corrigir tradução", self.correct_translation)
        toolbar.addAction("🎯 Modo foco", self.toggle_focus_mode)
        toolbar.addAction("📌 Grifos", self.open_highlights)
        toolbar.addAction("⚙ Configurações", self.open_settings)
        toolbar.addAction("🔀 Lado a lado", self.toggle_side_by_side)
        toolbar.addAction("⬇ Exportar EPUB", self.export_epub)
        toolbar.addAction("⏩ Traduzir tudo", self.translate_whole_book)
        toolbar.addAction("🧹 Limpar cache", self.clear_translation_cache)
        toolbar.addAction("💾 Backup", self.export_backup)
        toolbar.addAction("📂 Restaurar", self.import_backup)

        self.search_box = QLineEdit()
        self.search_box.setPlaceholderText("Pesquisar no capítulo…")
        self.search_box.setMaximumWidth(260)
        self.search_box.returnPressed.connect(self.search_in_chapter)
        toolbar.addWidget(self.search_box)

        # ----- sidebar: capa + título + lista de capítulos -----
        self.cover_label = QLabel("Sem capa")
        self.cover_label.setAlignment(Qt.AlignCenter)
        self.cover_label.setFixedSize(160, 220)
        self.cover_label.setObjectName("coverLabel")

        self.book_title_label = QLabel("Nenhum livro aberto")
        self.book_title_label.setObjectName("bookTitle")
        self.book_title_label.setWordWrap(True)
        self.book_title_label.setAlignment(Qt.AlignCenter)

        self.book_author_label = QLabel("")
        self.book_author_label.setObjectName("bookAuthor")
        self.book_author_label.setAlignment(Qt.AlignCenter)

        cover_box = QVBoxLayout()
        cover_box.addWidget(self.cover_label, alignment=Qt.AlignCenter)
        cover_box.addWidget(self.book_title_label)
        cover_box.addWidget(self.book_author_label)

        self.chapter_list = QListWidget()
        self.chapter_list.setObjectName("chapterList")
        self.chapter_list.currentRowChanged.connect(self.load_chapter)

        self.reading_progress_label = QLabel("")
        self.reading_progress_label.setObjectName("readingProgressLabel")
        self.reading_progress_bar = QProgressBar()
        self.reading_progress_bar.setObjectName("readingProgressBar")
        self.reading_progress_bar.setTextVisible(False)
        self.reading_progress_bar.setFixedHeight(6)

        sidebar = QWidget()
        sidebar.setObjectName("sidebar")
        sidebar_layout = QVBoxLayout(sidebar)
        sidebar_layout.addLayout(cover_box)
        sep = QFrame()
        sep.setFrameShape(QFrame.HLine)
        sep.setObjectName("sidebarSeparator")
        self.chapter_search_box = QLineEdit()
        self.chapter_search_box.setObjectName("chapterSearchBox")
        self.chapter_search_box.setPlaceholderText("Buscar capítulo…")
        self.chapter_search_box.textChanged.connect(self._filter_chapter_list)

        sidebar_layout.addWidget(sep)
        sidebar_layout.addWidget(self.reading_progress_label)
        sidebar_layout.addWidget(self.reading_progress_bar)
        sidebar_layout.addWidget(QLabel("Capítulos"), 0)
        sidebar_layout.addWidget(self.chapter_search_box)
        sidebar_layout.addWidget(self.chapter_list, 1)
        sidebar.setFixedWidth(240)

        # ----- área de leitura -----
        self.text_view = QTextEdit()
        self.text_view.setReadOnly(True)
        self.text_view.setObjectName("textView")

        self.progress_bar = QProgressBar()
        self.progress_bar.setVisible(False)
        self.progress_bar.setTextVisible(False)
        self.progress_bar.setFixedHeight(6)

        self.time_remaining_label = QLabel("")
        self.time_remaining_label.setObjectName("timeRemainingLabel")

        self.favorite_btn = QPushButton("☆ Favoritar")
        self.favorite_btn.setObjectName("navButton")
        self.favorite_btn.clicked.connect(self.toggle_favorite_chapter)

        self.note_btn = QPushButton("📝 Nota")
        self.note_btn.setObjectName("navButton")
        self.note_btn.clicked.connect(self.edit_chapter_note)

        self.read_btn = QPushButton("○ Marcar como lido")
        self.read_btn.setObjectName("navButton")
        self.read_btn.clicked.connect(self.toggle_read_chapter)

        prev_btn = QPushButton("◀  Anterior")
        prev_btn.setObjectName("navButton")
        prev_btn.clicked.connect(self.previous_chapter)
        next_btn = QPushButton("Próximo  ▶")
        next_btn.setObjectName("navButton")
        next_btn.clicked.connect(self.next_chapter)

        nav_row = QHBoxLayout()
        nav_row.addWidget(prev_btn)
        nav_row.addWidget(self.favorite_btn)
        nav_row.addWidget(self.note_btn)
        nav_row.addWidget(self.read_btn)
        nav_row.addStretch(1)
        nav_row.addWidget(next_btn)
        self.nav_bar = QWidget()
        self.nav_bar.setLayout(nav_row)

        reading_area = QWidget()
        reading_layout = QVBoxLayout(reading_area)
        reading_layout.addWidget(self.progress_bar)
        reading_layout.addWidget(self.time_remaining_label)
        reading_layout.addWidget(self.text_view, 1)
        reading_layout.addWidget(self.nav_bar)

        self.sidebar = sidebar

        central = QWidget()
        root_layout = QHBoxLayout(central)
        root_layout.setContentsMargins(0, 0, 0, 0)
        root_layout.setSpacing(0)
        root_layout.addWidget(sidebar)
        root_layout.addWidget(reading_area, 1)

        self.setCentralWidget(central)
        self.setStatusBar(QStatusBar())

        QShortcut(QKeySequence("F11"), self, activated=self.toggle_fullscreen)
        QShortcut(QKeySequence(Qt.Key_Right), self, activated=self.next_chapter)
        QShortcut(QKeySequence(Qt.Key_Left), self, activated=self.previous_chapter)
        QShortcut(QKeySequence("Ctrl+H"), self, activated=self.highlight_selection)
        QShortcut(QKeySequence("Ctrl+E"), self, activated=self.correct_translation)
        QShortcut(QKeySequence("F9"), self, activated=self.toggle_focus_mode)

    # ---------- tema visual ----------

    def _apply_theme(self):
        p = self.palette_
        font_family = self.config.get("font_family")
        font_size = self.config.get("font_size")
        spacing = self.config.get("line_spacing")
        margin = self.config.get("margin")

        self.setStyleSheet(f"""
            QMainWindow {{ background-color: {p.bg}; }}
            QToolBar {{
                background-color: {p.surface};
                border: none;
                padding: 6px;
                spacing: 8px;
            }}
            QToolBar QToolButton {{
                color: {p.text};
                padding: 6px 10px;
                border-radius: 6px;
            }}
            QToolBar QToolButton:hover {{ background-color: {p.accent}; color: white; }}
            QLineEdit {{
                background-color: {p.bg};
                color: {p.text};
                border: 1px solid {p.accent_dark};
                border-radius: 6px;
                padding: 4px 8px;
            }}
            #sidebar {{ background-color: {p.surface}; }}
            #sidebarSeparator {{ background-color: {p.accent_dark}; max-height: 1px; }}
            #coverLabel {{
                {PLACEHOLDER_COVER_STYLE.format(surface=p.bg, accent=p.text)}
            }}
            #bookTitle {{ color: {p.text}; font-size: 14px; font-weight: 600; margin-top: 6px; }}
            #bookAuthor {{ color: {p.text}; font-size: 12px; margin-bottom: 6px; }}
            #chapterList {{
                background-color: {p.surface};
                color: {p.text};
                border: none;
                outline: none;
            }}
            #chapterList::item {{
                padding: 8px 6px;
                border-radius: 6px;
            }}
            #chapterList::item:selected {{
                background-color: {p.accent};
                color: white;
            }}
            #textView {{
                background-color: {p.bg};
                color: {p.text};
                border: none;
                padding: {margin}px;
            }}
            #navButton {{
                background-color: {p.surface};
                color: {p.text};
                border: 1px solid {p.accent_dark};
                border-radius: 8px;
                padding: 8px 16px;
            }}
            #navButton:hover {{ background-color: {p.accent}; color: white; }}
            QProgressBar {{
                background-color: {p.surface};
                border: none;
                border-radius: 3px;
            }}
            QProgressBar::chunk {{ background-color: {p.accent}; border-radius: 3px; }}
            #readingProgressLabel {{ color: {p.text}; font-size: 11px; margin-top: 4px; }}
            #timeRemainingLabel {{ color: {p.text}; font-size: 11px; opacity: 0.8; margin-bottom: 6px; }}
            QStatusBar {{ background-color: {p.surface}; color: {p.text}; }}
            QLabel {{ color: {p.text}; }}
        """)
        self.text_view.setFont(QFont(font_family, font_size))
        self.text_view.document().setDefaultStyleSheet(self._block_style_stylesheet())

    def _refresh_theme_for_book(self):
        use_cover = self.config.get("use_cover_theme", True)
        cover = self.epub_reader.cover_bytes if (self.epub_reader and use_cover) else None
        self.palette_ = palette_from_cover(cover, self.config.get("theme") == "dark")
        self._apply_theme()

    # ---------- abrir livro / navegar capítulos ----------

    def open_epub(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Abrir livro", "",
            "Livros suportados (*.epub *.txt *.pdf);;EPUB (*.epub);;Texto (*.txt);;PDF (*.pdf)",
        )
        if not path:
            return
        self._open_book_at_path(path)

    def open_library(self):
        dialog = LibraryDialog(self.config, self)
        if dialog.exec() == QDialog.Accepted and dialog.chosen_path:
            if not os.path.exists(dialog.chosen_path):
                QMessageBox.warning(
                    self, "Arquivo não encontrado",
                    f"O arquivo não está mais em:\n{dialog.chosen_path}\n\n"
                    "Pode ter sido movido ou apagado.",
                )
                return
            self._open_book_at_path(dialog.chosen_path)

    def _open_book_at_path(self, path: str):
        ext = os.path.splitext(path)[1].lower()
        try:
            if ext == ".epub":
                reader = EpubReader(path)
            elif ext in (".txt", ".pdf"):
                from plaintext_reader import PlainTextReader
                reader = PlainTextReader(path)
            else:
                QMessageBox.warning(
                    self, "Formato não suportado",
                    f"'{ext}' não é um formato suportado. Abra um .epub, .txt ou .pdf.",
                )
                return
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Erro ao abrir o livro", str(exc))
            return

        # se chegou ao fim do capítulo atual do livro ANTERIOR, marca como
        # lido antes de trocar (mesma regra da troca normal de capítulo)
        if self.epub_reader is not None:
            self._mark_current_chapter_read_if_finished()

        # se o usuário já ajustou manualmente os capítulos deste livro
        # antes, usa a escolha salva em vez da detecção automática
        saved_excluded = self.config.get_excluded_chapters(reader.book_id)
        if saved_excluded is not None:
            reader.set_excluded(set(saved_excluded))
        self.epub_reader = reader
        self.current_chapter_index = -1  # reseta pra não confundir com o livro anterior
        self.background_queue.clear()

        if not self.epub_reader.chapters:
            QMessageBox.warning(
                self, "Nenhum capítulo encontrado",
                "Não consegui identificar capítulos com texto neste arquivo, ou "
                "todos foram descartados. Abra 🧭 Capítulos pra revisar.",
            )

        self.translated_chapters.clear()
        self._refresh_book_ui(path)
        self._save_to_library(path)

    def _save_to_library(self, path: str):
        thumb_b64 = None
        if self.epub_reader.cover_bytes:
            try:
                img = Image.open(io.BytesIO(self.epub_reader.cover_bytes)).convert("RGB")
                img.thumbnail((120, 176))
                buf = io.BytesIO()
                img.save(buf, format="JPEG", quality=80)
                thumb_b64 = base64.b64encode(buf.getvalue()).decode("ascii")
            except Exception:  # noqa: BLE001 — capa corrompida/formato exótico: sem miniatura mesmo
                thumb_b64 = None
        self.config.add_to_library(
            self.epub_reader.book_id, path,
            self.epub_reader.book_title(), self.epub_reader.book_author(),
            thumb_b64,
        )

    def _refresh_book_ui(self, path: str):
        self.setWindowTitle(f"NovelAI Reader — {self.epub_reader.book_title()}")
        self.book_title_label.setText(self.epub_reader.book_title())
        self.book_author_label.setText(self.epub_reader.book_author())

        self.cover_label.clear()
        if self.epub_reader.cover_bytes:
            pixmap = QPixmap()
            pixmap.loadFromData(self.epub_reader.cover_bytes)
            self.cover_label.setPixmap(
                pixmap.scaled(160, 220, Qt.KeepAspectRatio, Qt.SmoothTransformation)
            )
        else:
            self.cover_label.setText("Sem capa")

        self._refresh_theme_for_book()
        self._reload_chapter_list()

        self.config.set("last_book", path)
        last_index = self.config.get_last_chapter(self.epub_reader.book_id)
        last_index = min(last_index, self.chapter_list.count() - 1)
        self.chapter_list.setCurrentRow(max(last_index, 0) if self.chapter_list.count() else -1)

    def _reload_chapter_list(self):
        self.chapter_list.clear()
        for chapter in self.epub_reader.chapters:
            self.chapter_list.addItem(QListWidgetItem(self._chapter_label(chapter)))
        self.chapter_search_box.blockSignals(True)
        self.chapter_search_box.clear()
        self.chapter_search_box.blockSignals(False)

    def _filter_chapter_list(self, text: str):
        text_lower = text.lower().strip()
        for i in range(self.chapter_list.count()):
            item = self.chapter_list.item(i)
            if item is None:
                continue
            item.setHidden(bool(text_lower) and text_lower not in item.text().lower())

    def _chapter_label(self, chapter) -> str:
        prefix = ""
        if self.config.is_read(self.epub_reader.book_id, chapter.index):
            prefix += "✓ "
        if self.config.is_favorite(self.epub_reader.book_id, chapter.index):
            prefix += "⭐ "
        if self.config.has_note(self.epub_reader.book_id, chapter.index):
            prefix += "📝 "
        return prefix + chapter.title

    def open_chapter_manager(self):
        if self.epub_reader is None:
            QMessageBox.information(self, "Nenhum livro aberto", "Abra um EPUB primeiro.")
            return
        dialog = ChapterManagerDialog(self.epub_reader, self)
        if dialog.exec() == QDialog.Accepted:
            excluded = dialog.excluded_names()
            self.epub_reader.set_excluded(excluded)
            self.config.set_excluded_chapters(self.epub_reader.book_id, list(excluded))
            self.translated_chapters.clear()
            self._refresh_book_ui(self.epub_reader.path)

    def open_summary(self):
        if self.epub_reader is None:
            QMessageBox.information(self, "Nenhum livro aberto", "Abra um EPUB primeiro.")
            return
        dialog = SummaryDialog(self.config, self.epub_reader, self)
        if dialog.exec() == QDialog.Accepted and dialog.selected_chapter is not None:
            self.chapter_list.setCurrentRow(dialog.selected_chapter)

    def open_wiki(self):
        if self.epub_reader is None:
            QMessageBox.information(self, "Nenhum livro aberto", "Abra um EPUB primeiro.")
            return
        CharacterWikiDialog(self.glossary, self.epub_reader, self).exec()

    def open_glossary(self):
        GlossaryDialog(self.glossary, self.epub_reader, self).exec()

    def open_gallery(self):
        if self.epub_reader is None:
            QMessageBox.information(self, "Nenhum livro aberto", "Abra um EPUB primeiro.")
            return
        GalleryDialog(self.epub_reader.image_bytes, self).exec()

    def clear_translation_cache(self):
        reply = QMessageBox.question(
            self, "Limpar cache de traduções",
            "Isso apaga todas as traduções já salvas (de todos os livros) e força "
            "traduzir tudo de novo na próxima vez que abrir um capítulo. "
            "Use isso se alguma tradução ficou estranha ou com erro salvo. Continuar?",
        )
        if reply != QMessageBox.Yes:
            return
        self.cache.clear_all()
        self.translated_chapters.clear()
        self.statusBar().showMessage("Cache de traduções limpo", 4000)
        if self.epub_reader is not None:
            self.load_chapter(self.current_chapter_index)

    def export_backup(self):
        path, _ = QFileDialog.getSaveFileName(
            self, "Exportar backup", "novelreader_backup.json", "JSON (*.json)"
        )
        if not path:
            return
        try:
            self.config.export_backup(path)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Erro ao exportar backup", str(exc))
            return
        QMessageBox.information(
            self, "Backup salvo",
            f"Biblioteca, favoritos, notas, grifos e configurações salvos em:\n{path}\n\n"
            "Isso NÃO inclui as traduções em si (fica no cache separado) nem os arquivos "
            ".epub — só as suas preferências e anotações.",
        )

    def import_backup(self):
        path, _ = QFileDialog.getOpenFileName(self, "Restaurar backup", "", "JSON (*.json)")
        if not path:
            return
        reply = QMessageBox.question(
            self, "Restaurar backup",
            "Isso substitui sua biblioteca, favoritos, notas, grifos e configurações "
            "pelos dados desse arquivo de backup. Continuar?",
        )
        if reply != QMessageBox.Yes:
            return
        try:
            self.config.import_backup(path)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Erro ao restaurar backup", str(exc))
            return
        QMessageBox.information(
            self, "Backup restaurado",
            "Backup restaurado com sucesso. Feche e abra o NovelAI Reader de novo pra "
            "tudo recarregar corretamente.",
        )

    def load_chapter(self, index: int):
        if self.epub_reader is None or index < 0:
            return
        if self.current_chapter_index != index:
            self._mark_current_chapter_read_if_finished()
        self.current_chapter_index = index
        self.config.set_last_chapter(self.epub_reader.book_id, index)
        self._refresh_chapter_buttons()
        self._update_reading_progress()

        chapter = self.epub_reader.get_chapter(index)

        if index in self.translated_chapters:
            self._show_chapter(chapter, self.translated_chapters[index])
            self._update_time_remaining(chapter, self.translated_chapters[index])
            self._prefetch_next_chapter()
            return

        if self.config.get("auto_translate"):
            self._update_time_remaining(chapter, None)
            self._translate_and_show(chapter)
        else:
            self._show_chapter(chapter, None)
            self._update_time_remaining(chapter, None)
            self._prefetch_next_chapter()

    def _mark_current_chapter_read_if_finished(self):
        """Só marca como lido automaticamente se a rolagem do capítulo
        que está sendo deixado chegou perto do fim — chapter curtinho
        que cabe todo na tela (sem barra de rolagem) já conta como lido
        também."""
        if self.epub_reader is None or self.current_chapter_index < 0:
            return
        scrollbar = self.text_view.verticalScrollBar()
        reached_end = scrollbar.maximum() == 0 or scrollbar.value() >= scrollbar.maximum() - 4
        if reached_end:
            self.config.mark_as_read(self.epub_reader.book_id, self.current_chapter_index)
            self._reload_chapter_list_labels()

    def _update_reading_progress(self):
        if self.epub_reader is None:
            return
        total = self.epub_reader.chapter_count()
        read = self.config.get_read_count(self.epub_reader.book_id)
        pct = int(read / total * 100) if total else 0
        self.reading_progress_label.setText(f"📊 {read}/{total} capítulos lidos ({pct}%)")
        self.reading_progress_bar.setMaximum(max(total, 1))
        self.reading_progress_bar.setValue(min(read, total))

    def _update_time_remaining(self, chapter, translated_texts):
        texts = translated_texts if translated_texts is not None else chapter.paragraphs
        word_count = sum(len(t.split()) for t in texts)
        if not word_count:
            self.time_remaining_label.setText("")
            return
        wpm = self.config.get("reading_wpm", 200)
        minutes = max(1, round(word_count / wpm))
        self.time_remaining_label.setText(f"⏱ ~{minutes} min de leitura neste capítulo")

    def _translate_and_show(self, chapter):
        already_cached = self.translator.chapter_is_cached(chapter.paragraphs)
        if already_cached:
            translated = [
                self.cache.get(p, self.translator.target_lang) or p
                for p in chapter.paragraphs
            ]
            self.translated_chapters[chapter.index] = translated
            self._show_chapter(chapter, translated)
            self._prefetch_next_chapter()
            return

        self.progress_bar.setVisible(True)
        self.progress_bar.setValue(0)
        self.statusBar().showMessage("Traduzindo capítulo…")

        worker = TranslateWorker(
            self.translator, self.epub_reader.book_id, chapter.index, chapter.paragraphs,
            parent=self,
        )
        worker.progress.connect(
            lambda done, total: self.progress_bar.setValue(int(done / total * 100))
        )
        worker.finished_ok.connect(self._on_translation_done)
        worker.failed.connect(self._on_translation_failed)
        # IMPORTANTE: `parent=self` (acima) garante que o Qt é dono do
        # objeto, não o Python — então soltar self.worker não derruba a
        # thread C++ antes da hora. deleteLater() agenda a limpeza de
        # verdade só depois que a thread encerra por completo.
        worker.finished.connect(worker.deleteLater)
        worker.finished.connect(self._on_worker_thread_finished)
        self.worker = worker
        worker.start()

    def _on_worker_thread_finished(self):
        self.worker = None
        self._advance_background_queue()

    def _on_translation_done(self, chapter_index: int, paragraphs: list[str]):
        self.translated_chapters[chapter_index] = paragraphs
        self.progress_bar.setVisible(False)
        self.statusBar().showMessage("Tradução concluída", 3000)
        if chapter_index == self.current_chapter_index:
            chapter = self.epub_reader.get_chapter(chapter_index)
            self._show_chapter(chapter, paragraphs)
            self._update_time_remaining(chapter, paragraphs)
            self._prefetch_next_chapter()

    def _on_translation_failed(self, message: str):
        self.progress_bar.setVisible(False)
        self.statusBar().showMessage("Falha na tradução — mostrando texto original", 6000)
        QMessageBox.warning(
            self, "Erro de tradução",
            f"{message}\n\nMostrando o capítulo no idioma original por enquanto.",
        )
        chapter = self.epub_reader.get_chapter(self.current_chapter_index)
        self._show_chapter(chapter, None)

    # ---------- tradução em segundo plano ----------

    def _start_background_worker(self, chapter):
        """Cria e inicia uma thread de tradução em segundo plano — com
        `parent=self` pra o Qt ser dono do objeto (não o Python), e
        deleteLater() pra limpar só depois que a thread realmente parar."""
        worker = TranslateWorker(
            self.translator, self.epub_reader.book_id, chapter.index, chapter.paragraphs,
            parent=self,
        )
        worker.finished_ok.connect(self._on_background_translation_done)
        worker.failed.connect(self._on_background_translation_failed)
        worker.finished.connect(worker.deleteLater)
        worker.finished.connect(self._on_background_worker_thread_finished)
        self.background_worker = worker
        worker.start()

    def _prefetch_next_chapter(self):
        """Traduz o PRÓXIMO capítulo silenciosamente, em segundo plano,
        enquanto o usuário lê o atual — assim, quando ele avançar, o
        capítulo já está pronto em vez de precisar esperar."""
        if self.worker is not None or self.background_worker is not None:
            return  # já tem tradução rolando; tenta de novo na próxima troca
        next_index = self.current_chapter_index + 1
        if next_index >= self.epub_reader.chapter_count():
            return
        chapter = self.epub_reader.get_chapter(next_index)
        if self.translator.chapter_is_cached(chapter.paragraphs):
            return  # já traduzido, nada a fazer
        self._start_background_worker(chapter)

    def _on_background_translation_done(self, chapter_index: int, paragraphs: list[str]):
        self.translated_chapters[chapter_index] = paragraphs
        self.background_consecutive_failures = 0
        self.statusBar().showMessage("Próximo capítulo pré-traduzido em segundo plano", 3000)
        if chapter_index == self.current_chapter_index:
            chapter = self.epub_reader.get_chapter(chapter_index)
            self._show_chapter(chapter, paragraphs)

    def _on_background_translation_failed(self, message: str):
        # NÃO fica mais em silêncio — antes essa falha desaparecia sem
        # avisar nada, então a fila parecia "travar" sem explicação
        # nenhuma quando o Google Translate bloqueava por excesso de uso.
        self.background_consecutive_failures += 1
        self.statusBar().showMessage(
            f"Falha ao traduzir em segundo plano ({self.background_consecutive_failures}"
            f"/{BACKGROUND_FAILURE_LIMIT}): {message}", 6000,
        )

    def _on_background_worker_thread_finished(self):
        self.background_worker = None

        if self.background_consecutive_failures >= BACKGROUND_FAILURE_LIMIT:
            # "disjuntor": várias falhas seguidas quase sempre é bloqueio
            # temporário do Google Translate por excesso de chamadas —
            # continuar tentando só bate na mesma parede. Para a fila e
            # avisa, em vez de ficar girando pra sempre sem progresso.
            had_queue = bool(self.background_queue)
            self.background_queue.clear()
            self.background_consecutive_failures = 0
            if had_queue:
                self.statusBar().showMessage(
                    "Tradução em segundo plano interrompida após falhas repetidas.", 8000
                )
                QMessageBox.warning(
                    self, "Tradução em segundo plano parou",
                    "Depois de várias falhas seguidas, parei a tradução em segundo "
                    "plano — o motivo mais provável é bloqueio temporário do Google "
                    "Translate por excesso de chamadas em pouco tempo.\n\n"
                    "O que já foi traduzido está salvo. Espere alguns minutos e "
                    "clique em ⏩ Traduzir tudo de novo pra continuar de onde parou.",
                )
            return

        if self.background_queue:
            # pequena pausa entre capítulos da fila, de propósito — ajuda
            # a não bater tão rápido no limite de chamadas do tradutor
            QTimer.singleShot(BACKGROUND_THROTTLE_MS, self._advance_background_queue)

    def translate_whole_book(self):
        if self.epub_reader is None:
            QMessageBox.information(self, "Nenhum livro aberto", "Abra um EPUB primeiro.")
            return
        pending = [
            ch for ch in self.epub_reader.chapters
            if not self.translator.chapter_is_cached(ch.paragraphs)
        ]
        if not pending:
            QMessageBox.information(
                self, "Já traduzido", "Todos os capítulos deste livro já estão traduzidos."
            )
            return
        reply = QMessageBox.question(
            self, "Traduzir livro inteiro",
            f"Isso vai traduzir {len(pending)} capítulo(s) restante(s) em segundo plano, "
            "um de cada vez, com uma pequena pausa entre eles pra não sobrecarregar o "
            "serviço de tradução. Você pode continuar lendo enquanto isso. Continuar?",
        )
        if reply != QMessageBox.Yes:
            return
        self.background_queue = [ch.index for ch in pending]
        self.background_consecutive_failures = 0
        self.statusBar().showMessage(
            f"Traduzindo o livro em segundo plano — {len(pending)} capítulo(s) na fila…"
        )
        if self.background_worker is None:
            self._advance_background_queue()

    def _advance_background_queue(self):
        if not self.background_queue or self.background_worker is not None:
            return
        if self.worker is not None:
            # tradução interativa rolando; tenta de novo em breve em vez
            # de simplesmente desistir dessa rodada
            QTimer.singleShot(BACKGROUND_THROTTLE_MS, self._advance_background_queue)
            return
        next_index = self.background_queue.pop(0)
        if next_index in self.translated_chapters:
            self._advance_background_queue()
            return
        chapter = self.epub_reader.get_chapter(next_index)
        if self.translator.chapter_is_cached(chapter.paragraphs):
            translated = [
                self.cache.get(p, self.translator.target_lang) or p
                for p in chapter.paragraphs
            ]
            self.translated_chapters[chapter.index] = translated
            self._advance_background_queue()
            return

        self._start_background_worker(chapter)
        remaining = len(self.background_queue)
        if remaining:
            self.statusBar().showMessage(f"Traduzindo em segundo plano — {remaining} restante(s)…")
        else:
            self.statusBar().showMessage("Traduzindo o último capítulo da fila…", 4000)

    # ---------- favoritos e notas ----------

    def _refresh_chapter_buttons(self):
        if self.epub_reader is None:
            return
        is_fav = self.config.is_favorite(self.epub_reader.book_id, self.current_chapter_index)
        self.favorite_btn.setText("★ Favoritado" if is_fav else "☆ Favoritar")
        has_note = self.config.has_note(self.epub_reader.book_id, self.current_chapter_index)
        self.note_btn.setText("📝 Nota ✓" if has_note else "📝 Nota")
        is_read = self.config.is_read(self.epub_reader.book_id, self.current_chapter_index)
        self.read_btn.setText("✓ Lido (clique pra desmarcar)" if is_read else "○ Marcar como lido")

    def toggle_favorite_chapter(self):
        if self.epub_reader is None:
            return
        self.config.toggle_favorite(self.epub_reader.book_id, self.current_chapter_index)
        self._refresh_chapter_buttons()
        self._reload_chapter_list_labels()

    def toggle_read_chapter(self):
        if self.epub_reader is None:
            return
        self.config.toggle_read(self.epub_reader.book_id, self.current_chapter_index)
        self._refresh_chapter_buttons()
        self._reload_chapter_list_labels()
        self._update_reading_progress()

    def edit_chapter_note(self):
        if self.epub_reader is None:
            return
        chapter = self.epub_reader.get_chapter(self.current_chapter_index)
        existing = self.config.get_note(self.epub_reader.book_id, self.current_chapter_index)
        dialog = NoteDialog(chapter.title, existing, self)
        if dialog.exec() == QDialog.Accepted:
            self.config.set_note(self.epub_reader.book_id, self.current_chapter_index,
                                  dialog.note_text())
            self._refresh_chapter_buttons()
            self._reload_chapter_list_labels()

    def _reload_chapter_list_labels(self):
        for i, chapter in enumerate(self.epub_reader.chapters):
            item = self.chapter_list.item(i)
            if item:
                item.setText(self._chapter_label(chapter))

    def _show_paragraphs(self, title: str, paragraphs: list[str]):
        """Mantido por compatibilidade — mostra só texto, sem imagens
        posicionadas (usado quando não há chapter.blocks disponível)."""
        html = f"<h2>{title}</h2>" + "".join(f"<p>{p}</p>" for p in paragraphs)
        self.text_view.setHtml(html)

    def _block_style_stylesheet(self) -> str:
        """CSS com só DUAS categorias visuais, de propósito (ver
        style_classifier.py pro motivo): texto normal, e texto
        "destacado" (entre colchetes especiais do original) — sem
        tentar sugerir QUEM está falando, pra não confundir. Continua
        tudo branco/uniforme; o "dinâmico por livro" fica no fundo
        (ver theme.py), não na cor da letra."""
        p = self.palette_
        spacing = self.config.get("line_spacing")
        font_size = self.config.get("font_size")
        return f"""
            h2 {{
                color: {p.text};
                font-size: {font_size + 5}px;
                font-weight: 700;
                letter-spacing: 0.3px;
                border-bottom: 2px solid {p.accent};
                padding-bottom: 8px;
                margin-bottom: 20px;
            }}
            p {{ line-height: {int(spacing * 100)}%; margin: 0 0 16px 0; color: {p.text}; }}
            .p-narration {{ color: {p.text}; }}
            .p-italic {{ color: {p.text}; font-style: italic; }}
            .p-highlighted {{
                color: {p.text};
                font-style: italic;
                font-weight: 700;
                text-align: center;
                margin: 18px auto;
            }}
            .p-original {{
                color: {p.text};
                opacity: 0.65;
                font-style: italic;
                font-size: {max(font_size - 2, 10)}px;
                margin: 0 0 4px 0;
                border-left: 2px solid {p.accent_dark};
                padding-left: 8px;
            }}
        """

    def _show_chapter(self, chapter, translated_texts: list[str] | None):
        """Mostra o capítulo intercalando texto (original ou traduzido)
        e imagens na posição exata em que aparecem no EPUB, com a
        formatação variando por tipo de conteúdo e os grifos do
        usuário destacados com fundo colorido. Se o modo 🔀 Lado a lado
        estiver ligado, mostra o parágrafo original (menor, apagado)
        logo acima da tradução — pra comparar quando ela parecer estranha.

        Também guarda, em self.block_to_paragraph_index, qual parágrafo
        (índice na lista de texts) corresponde a cada bloco/linha do
        documento do Qt — usado por 🖍 Grifar e ✏️ Corrigir tradução pra
        saber EXATAMENTE em qual parágrafo o cursor está, em vez de
        tentar adivinhar por busca de texto (que confundia parágrafos
        parecidos e obrigava selecionar a linha toda)."""
        texts = translated_texts if translated_texts is not None else chapter.paragraphs
        text_iter = iter(texts)
        doc = self.text_view.document()
        doc.setDefaultStyleSheet(self._block_style_stylesheet())
        highlights = self.config.get_highlights(self.epub_reader.book_id, chapter.index)
        side_by_side = self.config.get("side_by_side", False)

        self.block_to_paragraph_index = {}
        block_number = 1  # bloco 0 é o <h2> do título

        parts = [f"<h2>{chapter.title}</h2>"]
        img_counter = 0
        paragraph_index = -1
        for block in chapter.blocks:
            if block.kind == "text":
                paragraph_index += 1
                text = next(text_iter, block.text)
                if side_by_side and text.strip() and text != block.text:
                    parts.append(f'<p class="p-original">{block.text}</p>')
                    block_number += 1  # esse bloco extra não mapeia pra nenhum parágrafo
                text = self._apply_highlights(text, highlights)
                css_class = f"p-{block.style}"
                parts.append(f'<p class="{css_class}">{text}</p>')
                self.block_to_paragraph_index[block_number] = paragraph_index
                block_number += 1
            elif block.kind == "image" and block.image:
                image = QImage()
                if image.loadFromData(block.image):
                    name = f"chapter-image-{img_counter}"
                    doc.addResource(QTextDocument.ImageResource, QUrl(name), image)
                    parts.append(f'<p align="center"><img src="{name}" width="360"/></p>')
                    img_counter += 1
                    block_number += 1
        self.text_view.setHtml("".join(parts))

    def toggle_side_by_side(self):
        current = self.config.get("side_by_side", False)
        self.config.set("side_by_side", not current)
        state = "ativado" if not current else "desativado"
        self.statusBar().showMessage(f"Modo lado a lado (original + tradução) {state}", 3000)
        if self.epub_reader is not None and self.current_chapter_index >= 0:
            chapter = self.epub_reader.get_chapter(self.current_chapter_index)
            self._show_chapter(chapter, self.translated_chapters.get(self.current_chapter_index))

    @staticmethod
    def _apply_highlights(text: str, highlights: list[dict]) -> str:
        """Envolve cada trecho grifado com um <span> de fundo colorido.
        Casa por igualdade exata de texto — se o capítulo for
        retraduzido depois de grifado, um grifo pode parar de "pegar"
        (o texto traduzido mudou); é uma limitação conhecida."""
        for h in highlights:
            snippet = h.get("text", "")
            if not snippet or snippet not in text:
                continue
            comment = (h.get("comment") or "").replace('"', "&quot;").replace("\n", " ")
            title_attr = f' title="{comment}"' if comment else ""
            replacement = (
                f'<span style="background-color:#f2c14e; color:#1a1a1a; '
                f'border-radius:3px; padding:0 2px;"{title_attr}>{snippet}</span>'
            )
            text = text.replace(snippet, replacement, 1)
        return text

    def correct_translation(self):
        """Corrige manualmente a tradução do parágrafo onde está o
        cursor (ou o que estiver selecionado) — a correção substitui o
        cache pra sempre, sem precisar de IA paga."""
        if self.epub_reader is None or self.current_chapter_index < 0:
            return
        translated = self.translated_chapters.get(self.current_chapter_index)
        if translated is None:
            QMessageBox.information(
                self, "Capítulo ainda não traduzido",
                "Espere o capítulo terminar de traduzir antes de corrigir um parágrafo.",
            )
            return

        cursor = self.text_view.textCursor()
        match_index = self.block_to_paragraph_index.get(cursor.blockNumber())
        if match_index is None or match_index >= len(translated):
            QMessageBox.information(
                self, "Não consegui identificar o parágrafo",
                "Clique diretamente dentro do parágrafo de texto (não no título nem numa "
                "imagem) e tente de novo — não precisa selecionar nada, só clicar dentro "
                "do parágrafo já basta.",
            )
            return

        chapter = self.epub_reader.get_chapter(self.current_chapter_index)
        original_text = chapter.paragraphs[match_index] if match_index < len(chapter.paragraphs) else ""
        current_translation = translated[match_index]

        dialog = EditTranslationDialog(original_text, current_translation, self)
        if dialog.exec() == QDialog.Accepted:
            new_text = dialog.translated_text()
            translated[match_index] = new_text
            if original_text:
                self.cache.set(
                    original_text, new_text, self.translator.target_lang,
                    self.epub_reader.book_id, self.current_chapter_index,
                )
            self._show_chapter(chapter, translated)
            self.statusBar().showMessage("Tradução corrigida e salva", 3000)

    def highlight_selection(self):
        if self.epub_reader is None:
            return
        cursor = self.text_view.textCursor()
        selected = cursor.selectedText()
        if not selected.strip():
            QMessageBox.information(
                self, "Nada selecionado",
                "Selecione um trecho de texto na leitura antes de grifar.",
            )
            return
        if "\u2029" in selected:  # separador de parágrafo do Qt — seleção cruzou vários <p>
            QMessageBox.information(
                self, "Seleção muito grande",
                "Por enquanto só dá pra grifar um trecho dentro de um único parágrafo.",
            )
            return
        dialog = HighlightCommentDialog(selected, self)
        if dialog.exec() == QDialog.Accepted:
            self.config.add_highlight(
                self.epub_reader.book_id, self.current_chapter_index,
                selected, dialog.comment_text(),
            )
            chapter = self.epub_reader.get_chapter(self.current_chapter_index)
            self._show_chapter(chapter, self.translated_chapters.get(self.current_chapter_index))

    def open_highlights(self):
        if self.epub_reader is None:
            QMessageBox.information(self, "Nenhum livro aberto", "Abra um EPUB primeiro.")
            return
        dialog = HighlightsDialog(self.config, self.epub_reader, self)
        if dialog.exec() == QDialog.Accepted and dialog.selected_chapter is not None:
            self.chapter_list.setCurrentRow(dialog.selected_chapter)

    def previous_chapter(self):
        if self.chapter_list.currentRow() > 0:
            self.chapter_list.setCurrentRow(self.chapter_list.currentRow() - 1)

    def next_chapter(self):
        if self.chapter_list.currentRow() < self.chapter_list.count() - 1:
            self.chapter_list.setCurrentRow(self.chapter_list.currentRow() + 1)

    # ---------- pesquisa, configurações, exportação ----------

    def search_in_chapter(self):
        term = self.search_box.text()
        if not term:
            return
        found = self.text_view.find(term)
        if not found:
            cursor = self.text_view.textCursor()
            cursor.movePosition(cursor.MoveOperation.Start)
            self.text_view.setTextCursor(cursor)
            self.text_view.find(term)

    def open_settings(self):
        old_target_lang = self.translator.target_lang
        dialog = SettingsDialog(self.config, self)
        if dialog.exec() == QDialog.Accepted:
            dialog.apply()
            new_target_lang = self.config.get("target_language")
            self.translator.target_lang = new_target_lang
            self._refresh_theme_for_book()

            if new_target_lang != old_target_lang:
                # a tradução que já está na tela (e em memória) ainda é do
                # idioma antigo — o cache continua intacto (é indexado por
                # idioma, não se perde nada), só precisa recarregar o
                # capítulo atual pra buscar/traduzir no idioma novo
                self.translated_chapters.clear()
                self.background_queue.clear()
                self.statusBar().showMessage(
                    "Idioma de tradução trocado — recarregando capítulo atual…", 4000
                )
                if self.epub_reader is not None and self.current_chapter_index >= 0:
                    self.load_chapter(self.current_chapter_index)
                return

            if self.epub_reader is not None and self.current_chapter_index >= 0:
                chapter = self.epub_reader.get_chapter(self.current_chapter_index)
                self._update_time_remaining(
                    chapter, self.translated_chapters.get(self.current_chapter_index)
                )

    def export_epub(self):
        if self.epub_reader is None:
            QMessageBox.information(self, "Nada para exportar", "Abra um livro primeiro.")
            return
        if not hasattr(self.epub_reader, "book"):
            QMessageBox.information(
                self, "Exportação não disponível",
                "Exportar como EPUB traduzido só funciona pra livros abertos a partir "
                "de um .epub — arquivos .txt/.pdf não têm uma estrutura de EPUB "
                "original pra reaproveitar. Você ainda pode ler e traduzir esses "
                "arquivos normalmente, só não dá pra gerar um .epub a partir deles.",
            )
            return
        if not self.translated_chapters:
            QMessageBox.information(
                self, "Nada traduzido",
                "Nenhum capítulo foi traduzido ainda. Navegue pelos capítulos "
                "com tradução automática ligada antes de exportar.",
            )
            return
        try:
            output_path = export_translated_epub(self.epub_reader, self.translated_chapters)
        except Exception as exc:  # noqa: BLE001
            QMessageBox.critical(self, "Erro ao exportar", str(exc))
            return
        QMessageBox.information(self, "Exportado", f"Arquivo salvo em:\n{output_path}")

    def toggle_fullscreen(self):
        if self.isFullScreen():
            self.showNormal()
        else:
            self.showFullScreen()

    def toggle_focus_mode(self):
        """Esconde toolbar, sidebar e botões de navegação — só o texto
        na tela, pra ler sem distração nenhuma. Aperte F9 de novo pra
        voltar ao normal (a toolbar some, então o atalho de teclado é
        o único jeito de sair)."""
        entering_focus = self.toolbar.isVisible()
        self.toolbar.setVisible(not entering_focus)
        self.sidebar.setVisible(not entering_focus)
        self.nav_bar.setVisible(not entering_focus)
        if entering_focus:
            self.statusBar().showMessage("Modo foco ativado — aperte F9 pra voltar ao normal", 4000)
        else:
            self.statusBar().showMessage("Modo foco desativado", 2000)

    def closeEvent(self, event):
        """Se o app for fechado com alguma tradução ainda rodando em
        segundo plano, espera ela terminar (até 5s) antes de sair —
        fechar com uma QThread ainda ativa é outra forma de disparar o
        mesmo travamento (QThread: Destroyed while thread is still
        running). Também marca o capítulo atual como lido se você
        chegou ao fim dele antes de fechar."""
        if self.epub_reader is not None and self.current_chapter_index >= 0:
            self._mark_current_chapter_read_if_finished()
        for worker in (self.worker, self.background_worker):
            if worker is not None and worker.isRunning():
                worker.wait(5000)
        event.accept()


def main():
    app = QApplication(sys.argv)
    icon_path = os.path.join(os.path.dirname(__file__), "assets", "icon.ico")
    if os.path.exists(icon_path):
        app.setWindowIcon(QIcon(icon_path))
    window = MainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
