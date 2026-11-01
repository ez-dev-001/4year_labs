"""Медіаплеєр. ЛР №2 з РМС, варіант 1. Python + PySide6 (Qt Multimedia, бекенд FFmpeg)."""
import sys
from pathlib import Path

from PySide6.QtCore import QByteArray, QEvent, QPoint, QSize, QStandardPaths, Qt, QUrl
from PySide6.QtGui import QIcon, QKeySequence, QPainter, QPixmap, QShortcut
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtSvg import QSvgRenderer
from PySide6.QtWidgets import (QAbstractSlider, QApplication, QFileDialog, QFrame, QGridLayout,
                               QHBoxLayout, QInputDialog, QLabel, QListWidget, QPushButton, QSlider,
                               QStackedWidget, QStyle, QStyleOptionSlider, QToolTip, QVBoxLayout,
                               QWidget)

SKIP_MS = 5000  # крок перемотування
SPEEDS = (1.0, 1.25, 1.5, 2.0, 0.5, 0.75)  # порядок перемикання кнопкою швидкості
MEDIA_FILTER = ("Медіафайли (*.mp3 *.wav *.ogg *.flac *.m4a *.mp4 *.mkv *.avi *.webm *.mov);;"
                "Усі файли (*)")
EMPTY_HINT = "Перетягніть сюди відео чи аудіо\nабо відкрийте файл: Ctrl+O"
# Людські пояснення помилок Qt; для решти показуємо текст від самого Qt
ERRORS = {
    QMediaPlayer.ResourceError: "файл не знайдено або він пошкоджений",
    QMediaPlayer.FormatError: "це не медіафайл або його формат не підтримується",
    QMediaPlayer.NetworkError: "посилання недоступне",
    QMediaPlayer.AccessDeniedError: "немає доступу до файлу",
}

# Палітра: темна, щоб не сперечатися з відео; бурштин — Play, прогрес і увімкнені перемикачі
WINDOW, PANEL, LINE = "#1A2030", "#242B3D", "#39425A"
TEXT, MUTED, ACCENT, ACCENT_HOVER = "#E6E9F0", "#8C95AB", "#F4A63A", "#F7BA62"

# Контури іконок (Material Icons, Apache 2.0), viewBox 24×24
ICONS = {
    "play": "M8 5v14l11-7z",
    "pause": "M6 5h4v14H6zm8 0h4v14h-4z",
    "stop": "M6 6h12v12H6z",
    "back": "M11 18V6l-8.5 6zm.5-6 8.5 6V6z",
    "forward": "M4 18l8.5-6L4 6zm9-12v12l8.5-6z",
    "prev": "M6 6h2v12H6zm3.5 6 8.5 6V6z",
    "next": "M6 18l8.5-6L6 6zM16 6v12h2V6z",
    "file": "M10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8z",
    "link": "M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 "
            "0-3.1-1.39-3.1-3.1zM8 13h8v-2H8zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 "
            "3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z",
    "list": "M15 6H3v2h12zm0 4H3v2h12zM3 16h8v-2H3zM17 6v8.18A3 3 0 0 0 16 14a3 3 0 1 0 3 3V8h3V6z",
    "repeat": "M7 7h10v3l4-4-4-4v3H5v6h2zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2z",
    "camera": "M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4zM9 2 7.17 4H4c-1.1 0-2 .9-2 2v12c0 "
              "1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2h-3.17L15 2z",
    "fullscreen": "M7 14H5v5h5v-2H7zm-2-4h2V7h3V5H5zm12 7h-3v2h5v-5h-2zM14 5v2h3v3h2V5z",
    "windowed": "M5 16h3v3h2v-5H5zm3-8H5v2h5V5H8zm6 11h2v-3h3v-2h-5zm2-11V5h-2v5h5V8z",
    "music": "M12 3v10.55A4 4 0 1 0 14 17V7h4V3z",
    "volume": "M3 9v6h4l5 5V4L7 9zm13.5 3A4.5 4.5 0 0 0 14 7.97v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 "
              "3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z",
    "muted": "M16.5 12A4.5 4.5 0 0 0 14 7.97v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 "
             "1.82-.54 2.64l1.51 1.51A8.8 8.8 0 0 0 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 "
             "3.54 5 6.71zM4.27 3 3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 "
             "1.18v2.06a9 9 0 0 0 3.69-1.81L19.73 21 21 19.73l-9-9zM12 4 9.91 6.09 12 8.18z",
}

STYLE = f"""
QWidget {{ background: {WINDOW}; color: {TEXT}; font-family: "Segoe UI", "Noto Sans", sans-serif;
          font-size: 10pt; }}
#screen, #screen QWidget {{ background: #000; }}
#hint {{ color: {MUTED}; font-size: 11pt; }}
#cover {{ font-size: 15pt; font-weight: 600; }}
#bar {{ background: {PANEL}; border-radius: 14px; }}
#bar QWidget {{ background: transparent; }}
#time {{ color: {MUTED}; font-family: Consolas, "DejaVu Sans Mono", monospace; }}
#status {{ color: {MUTED}; padding: 0 4px; }}
QListWidget {{ background: {PANEL}; border: none; border-radius: 12px; padding: 6px; outline: none; }}
QListWidget::item {{ padding: 7px 8px; border-radius: 6px; }}
QListWidget::item:hover {{ background: {LINE}; }}
QListWidget::item:selected {{ background: {LINE}; color: {ACCENT}; }}
QPushButton {{ border: 2px solid transparent; border-radius: 20px; min-width: 36px; min-height: 36px; }}
QPushButton:hover, #bar QPushButton:hover, #bar QPushButton:checked {{ background: {LINE}; }}
QPushButton:focus {{ border-color: {ACCENT}; }}
QPushButton#play {{ background: {ACCENT}; border-radius: 26px; min-width: 48px; min-height: 48px; }}
QPushButton#play:hover, #bar QPushButton#play:hover {{ background: {ACCENT_HOVER}; }}
QPushButton#play:focus {{ border-color: {TEXT}; }}
QPushButton#speed {{ min-width: 46px; color: {MUTED}; font-weight: 600; }}
QSlider::groove:horizontal {{ height: 4px; background: {LINE}; border-radius: 2px; }}
QSlider::sub-page:horizontal {{ background: {ACCENT}; border-radius: 2px; }}
QSlider#volume::sub-page:horizontal {{ background: {MUTED}; }}
QSlider::handle:horizontal {{ background: {TEXT}; width: 14px; margin: -5px 0; border-radius: 7px; }}
QSlider::handle:horizontal:hover {{ background: {ACCENT_HOVER}; }}
QLineEdit {{ background: {PANEL}; border: 1px solid {LINE}; border-radius: 6px; padding: 6px; }}
QToolTip {{ background: {PANEL}; color: {TEXT}; border: 1px solid {LINE}; padding: 4px; }}
"""


def icon(name: str, color: str = TEXT) -> QIcon:
    """SVG-контур -> чітка іконка потрібного кольору (рендер 64×64 для HiDPI)."""
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="{color}" d="{ICONS[name]}"/></svg>'
    pm = QPixmap(64, 64)
    pm.fill(Qt.transparent)
    painter = QPainter(pm)
    QSvgRenderer(QByteArray(svg.encode())).render(painter)
    painter.end()
    return QIcon(pm)


def fmt_time(ms: int) -> str:
    """Мілісекунди -> 'мм:сс' або 'г:мм:сс'."""
    s = max(ms, 0) // 1000
    h, rest = divmod(s, 3600)
    m, s = divmod(rest, 60)
    return f"{h}:{m:02}:{s:02}" if h else f"{m:02}:{s:02}"


def to_url(text: str) -> QUrl:
    """Рядок з поля вводу -> QUrl: усе з '://' — посилання (http, rtsp, file...), решта — локальний шлях."""
    text = text.strip()
    # не QUrl(text).scheme(): шлях 'C:\video.mp4' Qt розбирає як посилання зі схемою 'c'
    return QUrl(text) if "://" in text else QUrl.fromLocalFile(text)


class SeekSlider(QSlider):
    """Смуга прогресу: під курсором показує таймкод, клік переносить відтворення в цю точку."""

    def __init__(self):
        super().__init__(Qt.Horizontal, accessibleName="Позиція відтворення")
        self.setMouseTracking(True)  # події руху миші й без натиснутої кнопки
        self.setMaximum(0)  # у QSlider за замовчуванням 0..99, а до відкриття файлу тривалість 0

    def value_at(self, x: int) -> int:
        """Координата x у віджеті -> позиція в мс, з урахуванням ширини повзунка."""
        opt = QStyleOptionSlider()
        self.initStyleOption(opt)
        groove = self.style().subControlRect(QStyle.CC_Slider, opt, QStyle.SC_SliderGroove, self)
        handle = self.style().subControlRect(QStyle.CC_Slider, opt, QStyle.SC_SliderHandle, self)
        span = groove.width() - handle.width()
        return QStyle.sliderValueFromPosition(self.minimum(), self.maximum(),
                                              x - groove.x() - handle.width() // 2, span)

    def show_time(self, x: int):
        if self.maximum() > 0:  # поки медіа не відкрите, показувати нічого
            # Над смугою. Qt сам додає зсув +16…21 px донизу; якщо підказка ляже під курсор,
            # Qt одразу її сховає, тому піднімаємо з запасом
            QToolTip.showText(self.mapToGlobal(QPoint(x - 22, -62)), fmt_time(self.value_at(x)), self)

    def mouseMoveEvent(self, event):
        self.show_time(int(event.position().x()))
        super().mouseMoveEvent(event)

    def event(self, event):
        # Qt через ~0,7 с надсилає власну подію підказки і ховає нашу, бо toolTip() порожній
        if event.type() == QEvent.ToolTip:
            self.show_time(event.pos().x())
            return True
        return super().event(event)

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton and self.maximum() > 0:
            self.setSliderPosition(self.value_at(int(event.position().x())))
            self.triggerAction(QAbstractSlider.SliderMove)  # -> плеєр перемотує сюди
        super().mousePressEvent(event)  # повзунок тепер під курсором, тож його можна одразу тягнути


class Player(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Медіаплеєр")
        self.resize(1040, 640)
        self.setMinimumSize(900, 460)
        self.setAcceptDrops(True)
        self.setStyleSheet(STYLE)
        self.playlist: list[QUrl] = []
        self.index = -1

        self.player = QMediaPlayer(self)
        self.audio = QAudioOutput(self)
        self.player.setAudioOutput(self.audio)
        self.video = QVideoWidget()
        self.player.setVideoOutput(self.video)

        # Екран: відео або заставка (порожній стан / обкладинка аудіо / помилка)
        self.cover_icon = QLabel(alignment=Qt.AlignCenter)
        self.cover_icon.setPixmap(icon("music", LINE).pixmap(96, 96))
        self.cover = QLabel(objectName="cover", alignment=Qt.AlignCenter, wordWrap=True)
        self.hint = QLabel(EMPTY_HINT, objectName="hint", alignment=Qt.AlignCenter, wordWrap=True)
        self.placeholder = QWidget()
        ph = QVBoxLayout(self.placeholder)
        ph.addStretch()
        for w in (self.cover_icon, self.cover, self.hint):
            ph.addWidget(w)
        ph.addStretch()
        self.cover.hide()
        self.stack = QStackedWidget(objectName="screen")
        self.stack.addWidget(self.placeholder)
        self.stack.addWidget(self.video)
        self.list = QListWidget(accessibleName="Список відтворення")
        self.list.setFixedWidth(240)
        self.list.hide()

        self.open_btn = self._button("file", "Відкрити файли (Ctrl+O)")
        self.url_btn = self._button("link", "Відкрити посилання (Ctrl+U)")
        self.list_btn = self._button("list", "Список відтворення (L)", checkable=True)
        self.prev_btn = self._button("prev", "Попередній (P)")
        self.back_btn = self._button("back", f"Назад на {SKIP_MS // 1000} с (←)")
        self.play_btn = self._button("play", "Відтворити (пробіл)", obj="play")
        self.play_btn.setIcon(icon("play", WINDOW))
        self.stop_btn = self._button("stop", "Зупинити")
        self.fwd_btn = self._button("forward", f"Вперед на {SKIP_MS // 1000} с (→)")
        self.next_btn = self._button("next", "Наступний (N)")
        self.speed_btn = QPushButton("1×", objectName="speed", toolTip="Швидкість відтворення",
                                     accessibleName="Швидкість відтворення", cursor=Qt.PointingHandCursor)
        self.repeat_btn = self._button("repeat", "Повтор (R)", checkable=True)
        self.shot_btn = self._button("camera", "Зберегти кадр (Ctrl+S)")
        self.full_btn = self._button("fullscreen", "На весь екран (F)")
        self.mute_btn = self._button("volume", "Вимкнути звук (M)")
        self.pos_slider = SeekSlider()
        self.vol_slider = QSlider(Qt.Horizontal, objectName="volume", accessibleName="Гучність")
        self.vol_slider.setRange(0, 100)
        self.vol_slider.setFixedWidth(90)
        self.cur_label = QLabel(fmt_time(0), objectName="time")
        self.total_label = QLabel(fmt_time(0), objectName="time")
        self.status = QLabel(objectName="status")

        screen_row = QHBoxLayout()
        screen_row.setSpacing(10)
        screen_row.addWidget(self.stack, 1)
        screen_row.addWidget(self.list)
        seek_row = QHBoxLayout()
        seek_row.addWidget(self.cur_label)
        seek_row.addWidget(self.pos_slider, 1)
        seek_row.addWidget(self.total_label)
        # Три рівні зони, щоб транспорт стояв точно по центру
        controls = QGridLayout()
        for col in range(3):
            controls.setColumnStretch(col, 1)
        zones = (
            (self.open_btn, self.url_btn, self.list_btn, None),
            (self.prev_btn, self.back_btn, self.play_btn, self.stop_btn, self.fwd_btn, self.next_btn),
            (None, self.speed_btn, self.repeat_btn, self.shot_btn, self.full_btn, self.mute_btn, self.vol_slider),
        )
        for col, widgets in enumerate(zones):
            box = QHBoxLayout()
            for w in widgets:
                box.addWidget(w) if w else box.addStretch()
            controls.addLayout(box, 0, col, Qt.AlignVCenter)
        bar = QFrame(objectName="bar")
        bar_layout = QVBoxLayout(bar)
        bar_layout.setContentsMargins(16, 10, 16, 12)
        bar_layout.addLayout(seek_row)
        bar_layout.addLayout(controls)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 14, 14, 10)
        layout.setSpacing(10)
        layout.addLayout(screen_row, 1)
        layout.addWidget(bar)
        layout.addWidget(self.status)

        self.open_btn.clicked.connect(self.open_file_dialog)
        self.url_btn.clicked.connect(self.open_url_dialog)
        self.list_btn.toggled.connect(self.list.setVisible)
        self.list.itemActivated.connect(lambda item: self.play_index(self.list.row(item)))
        self.prev_btn.clicked.connect(lambda: self.play_index(self.index - 1))
        self.next_btn.clicked.connect(lambda: self.play_index(self.index + 1))
        self.play_btn.clicked.connect(self.toggle_play)
        self.stop_btn.clicked.connect(self.player.stop)
        self.back_btn.clicked.connect(lambda: self.seek(-SKIP_MS))
        self.fwd_btn.clicked.connect(lambda: self.seek(SKIP_MS))
        self.speed_btn.clicked.connect(self.cycle_speed)
        self.repeat_btn.toggled.connect(
            lambda on: self.player.setLoops(QMediaPlayer.Infinite if on else QMediaPlayer.Once))
        self.shot_btn.clicked.connect(self.snapshot)
        self.full_btn.clicked.connect(self.toggle_fullscreen)
        self.mute_btn.clicked.connect(lambda: self.audio.setMuted(not self.audio.isMuted()))
        # actionTriggered ловить і перетягування повзунка, і клік по смузі, і клавіші
        self.pos_slider.actionTriggered.connect(
            lambda _: self.player.setPosition(self.pos_slider.sliderPosition()))
        self.vol_slider.valueChanged.connect(lambda v: self.audio.setVolume(v / 100))
        self.audio.mutedChanged.connect(self.on_muted)
        self.player.positionChanged.connect(self.on_position)
        self.player.durationChanged.connect(self.on_duration)
        self.player.playbackStateChanged.connect(self.on_state)
        self.player.mediaStatusChanged.connect(self.on_media_status)
        self.player.hasVideoChanged.connect(lambda has: self.stack.setCurrentWidget(
            self.video if has else self.placeholder))
        self.player.errorOccurred.connect(self.on_error)

        for key, slot in ((Qt.Key_Space, self.toggle_play), (Qt.Key_Left, lambda: self.seek(-SKIP_MS)),
                          (Qt.Key_Right, lambda: self.seek(SKIP_MS)), ("Ctrl+O", self.open_file_dialog),
                          ("Ctrl+U", self.open_url_dialog), (Qt.Key_M, self.mute_btn.click),
                          (Qt.Key_N, self.next_btn.click), (Qt.Key_P, self.prev_btn.click),
                          (Qt.Key_L, self.list_btn.click), (Qt.Key_R, self.repeat_btn.click),
                          (Qt.Key_F, self.toggle_fullscreen), ("Ctrl+S", self.snapshot),
                          (Qt.Key_Escape, lambda: self.isFullScreen() and self.toggle_fullscreen())):
            QShortcut(QKeySequence(key), self, activated=slot)

        self.vol_slider.setValue(70)

    def _button(self, icon_name, tip, obj=None, checkable=False):
        btn = QPushButton(icon(icon_name), "", toolTip=tip, accessibleName=tip, checkable=checkable,
                          cursor=Qt.PointingHandCursor)
        btn.setIconSize(QSize(24, 24) if obj == "play" else QSize(20, 20))
        if checkable:  # увімкнений перемикач світиться акцентом
            btn.toggled.connect(lambda on: btn.setIcon(icon(icon_name, ACCENT if on else TEXT)))
        if obj:
            btn.setObjectName(obj)
        return btn

    # ---------- джерела та список відтворення ----------

    def add_sources(self, texts):
        """Додати файли/посилання в кінець списку і почати відтворення першого з доданих."""
        urls = [to_url(t) for t in texts if t.strip()]
        if not urls:
            return
        first = len(self.playlist)
        for url in urls:
            self.playlist.append(url)
            self.list.addItem(url.fileName() or url.toDisplayString())
        if len(self.playlist) > 1:
            self.list_btn.setChecked(True)
        self.play_index(first)

    def open_source(self, text: str):
        """Відкрити один локальний файл або URL і одразу почати відтворення."""
        self.add_sources([text])

    def play_index(self, i: int):
        if not 0 <= i < len(self.playlist):
            return
        self.index = i
        url = self.playlist[i]
        name = self.list.item(i).text()
        self.list.setCurrentRow(i)
        self.player.setSource(url)
        self.setWindowTitle(f"{name} — Медіаплеєр")
        self.cover.setText(name)
        self.cover.show()
        self.hint.hide()
        self.status.setText(f"Відкрито: {url.toDisplayString()}")
        self.player.play()

    def open_file_dialog(self):
        paths, _ = QFileDialog.getOpenFileNames(self, "Відкрити медіафайли", "", MEDIA_FILTER)
        self.add_sources(paths)

    def open_url_dialog(self):
        text, ok = QInputDialog.getText(self, "Відкрити посилання", "Посилання на відео чи аудіо (http, https, rtsp):")
        if ok:
            self.open_source(text)

    # ---------- керування ----------

    def toggle_play(self):
        if self.player.playbackState() == QMediaPlayer.PlayingState:
            self.player.pause()
        else:
            self.player.play()

    def seek(self, delta_ms: int):
        # QMediaPlayer сам обмежує позицію діапазоном [0, duration]
        self.player.setPosition(self.player.position() + delta_ms)

    def cycle_speed(self):
        rate = SPEEDS[(SPEEDS.index(self.player.playbackRate()) + 1) % len(SPEEDS)]
        self.player.setPlaybackRate(rate)
        self.speed_btn.setText(f"{rate:g}×")

    def toggle_fullscreen(self):
        full = not self.isFullScreen()
        self.showFullScreen() if full else self.showNormal()
        self.full_btn.setIcon(icon("windowed" if full else "fullscreen"))

    def snapshot(self):
        """Зберегти поточний кадр відео в PNG у папку «Зображення». Повертає шлях або None."""
        frame = self.video.videoSink().videoFrame()
        if not (self.player.hasVideo() and frame.isValid()):
            self.status.setText("Немає кадру: спершу відкрийте відео")
            return None
        stem = Path(self.playlist[self.index].fileName()).stem or "кадр"
        folder = QStandardPaths.writableLocation(QStandardPaths.PicturesLocation)
        path = str(Path(folder) / f"{stem}_{fmt_time(self.player.position()).replace(':', '-')}.png")
        if not frame.toImage().save(path):
            self.status.setText(f"Помилка: не вдалося зберегти кадр у {path}")
            return None
        self.status.setText(f"Кадр збережено: {path}")
        return path

    # ---------- реакція на сигнали плеєра ----------

    def on_position(self, ms: int):
        if not self.pos_slider.isSliderDown():  # не смикати повзунок, поки його тягнуть
            self.pos_slider.setValue(ms)
        self.cur_label.setText(fmt_time(ms))

    def on_duration(self, ms: int):
        self.pos_slider.setRange(0, ms)
        self.total_label.setText(fmt_time(ms))

    def on_state(self, state):
        playing = state == QMediaPlayer.PlayingState
        self.play_btn.setIcon(icon("pause" if playing else "play", WINDOW))
        self.play_btn.setToolTip("Пауза (пробіл)" if playing else "Відтворити (пробіл)")

    def on_media_status(self, status):
        if status == QMediaPlayer.EndOfMedia:  # з увімкненим повтором Qt сюди не доходить
            self.play_index(self.index + 1)  # саме синхронно: відкладений setSource тут зависає в Qt FFmpeg

    def on_error(self, error, message: str):
        reason = ERRORS.get(error, message)
        if error == QMediaPlayer.ResourceError and not self.player.source().isLocalFile():
            reason = "посилання недоступне або за ним немає файлу"
        self.status.setText(f"Помилка: {reason}")
        self.status.setToolTip(message)  # технічна деталь від Qt/FFmpeg
        # на заставку екран перемикає hasVideoChanged: Qt сам скидає відео при непридатному джерелі
        self.hint.setText(f"Не вдалося відтворити: {reason}")
        self.hint.show()

    def on_muted(self, muted: bool):
        self.mute_btn.setIcon(icon("muted" if muted else "volume"))
        self.mute_btn.setToolTip("Увімкнути звук (M)" if muted else "Вимкнути звук (M)")

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event):
        self.add_sources([url.toString() for url in event.mimeData().urls()])


if __name__ == "__main__":
    app = QApplication(sys.argv)
    w = Player()
    w.show()
    w.add_sources(sys.argv[1:])
    sys.exit(app.exec())
