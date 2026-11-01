import socket
import subprocess
import sys
import time

import pytest
from PySide6.QtCore import QMimeData, QPoint, QPointF, Qt, QUrl
from PySide6.QtGui import QDragEnterEvent, QDropEvent, QImage
from PySide6.QtMultimedia import QMediaPlayer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QAbstractSlider, QToolTip

from conftest import MEDIA
from player import ERRORS, SKIP_MS, SPEEDS, fmt_time, to_url

DURATION = 12_000  # усі тестові файли по 12 с
TOL = 600  # мс: допуск на декодування/буферизацію


def wait_until(cond, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return
        QTest.qWait(20)
    raise AssertionError("умова не виконалась за відведений час")


@pytest.fixture(scope="module")
def http_port():
    """Локальний HTTP-сервер з tests/media. Окремий процес: у потоці Python він ділить GIL
    з Qt, і FFmpeg може взаємно заблокуватися з ним."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    srv = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1",
                            "--directory", str(MEDIA)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def up():
        with socket.socket() as probe:
            return probe.connect_ex(("127.0.0.1", port)) == 0
    wait_until(up)
    yield port
    srv.kill()
    srv.wait()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start(win, path=MEDIA / "sample.mp4"):
    win.open_source(str(path))
    wait_until(lambda: win.player.playbackState() == QMediaPlayer.PlayingState
               and win.player.duration() > 0 and win.player.position() > 0)


# ---------- чисті функції ----------

@pytest.mark.parametrize("ms, text", [
    (0, "00:00"), (999, "00:00"), (1000, "00:01"), (59_999, "00:59"), (61_000, "01:01"),
    (3_599_000, "59:59"), (3_600_000, "1:00:00"), (3_725_000, "1:02:05"), (-5000, "00:00"),
])
def test_fmt_time(ms, text):
    assert fmt_time(ms) == text


@pytest.mark.parametrize("text", [
    "http://example.com/a.mp4", "https://example.com/s.mp3", "rtsp://cam/stream",
    "HTTPS://EXAMPLE.COM/A.MP4", "ftp://example.com/a.mp4",
])
def test_to_url_network(text):
    url = to_url(text)
    assert not url.isLocalFile() and url.toString().lower() == text.lower()


@pytest.mark.parametrize("text, path", [
    ("/home/u/song.mp3", "/home/u/song.mp3"),
    ("  /tmp/v.mkv  ", "/tmp/v.mkv"),
    ("C:/Users/u/v.mp4", "C:/Users/u/v.mp4"),
    ("C:\\Users\\u\\v.mp4", "C:\\Users\\u\\v.mp4"),
    ("відео з пробілами.mp4", "відео з пробілами.mp4"),
    ("file:///tmp/a.wav", "/tmp/a.wav"),
])
def test_to_url_local(text, path):
    url = to_url(text)
    assert url.isLocalFile() and url == QUrl.fromLocalFile(path)


# ---------- відтворення форматів ----------

@pytest.mark.parametrize("name", ["sample.wav", "sample.mp3", "sample.mp4", "sample.webm", "sample.mkv",
                                  "запис з пробілами.wav"])
def test_plays_format(win, name):
    start(win, MEDIA / name)
    assert abs(win.player.duration() - DURATION) < TOL
    assert win.total_label.text() == "00:12"
    assert win.pos_slider.maximum() == win.player.duration()
    assert win.play_btn.toolTip() == "Пауза (пробіл)"
    assert win.player.error() == QMediaPlayer.NoError


def test_empty_state(win):
    assert win.stack.currentWidget() is win.placeholder
    assert win.hint.isVisibleTo(win) and not win.cover.isVisibleTo(win)
    assert win.windowTitle() == "Медіаплеєр"


def test_screen_shows_video_or_audio_cover(win):
    start(win, MEDIA / "sample.mp4")
    assert win.player.hasVideo()
    wait_until(lambda: win.stack.currentWidget() is win.video)
    assert win.windowTitle() == "sample.mp4 — Медіаплеєр"
    start(win, MEDIA / "sample.mp3")
    wait_until(lambda: not win.player.hasVideo() and win.stack.currentWidget() is win.placeholder)
    assert win.cover.text() == "sample.mp3" and win.cover.isVisibleTo(win)
    assert not win.hint.isVisibleTo(win)


def test_plays_from_url(win, http_port):
    url = f"http://127.0.0.1:{http_port}/sample.mp4"
    start(win, url)
    assert win.player.source() == QUrl(url)
    assert abs(win.player.duration() - DURATION) < TOL
    win.player.setSource(QUrl())


# ---------- керування ----------

def test_play_pause_toggle(win):
    start(win)
    win.play_btn.click()
    assert win.player.playbackState() == QMediaPlayer.PausedState
    assert win.play_btn.toolTip() == "Відтворити (пробіл)"
    paused_at = win.player.position()
    QTest.qWait(300)
    assert win.player.position() == paused_at  # на паузі позиція стоїть
    win.play_btn.click()
    assert win.player.playbackState() == QMediaPlayer.PlayingState
    assert win.play_btn.toolTip() == "Пауза (пробіл)"


def test_stop_resets(win):
    start(win)
    win.stop_btn.click()
    assert win.player.playbackState() == QMediaPlayer.StoppedState
    wait_until(lambda: win.player.position() == 0)
    assert win.play_btn.toolTip() == "Відтворити (пробіл)"


def test_seek_forward_and_back(win):
    start(win)
    win.play_btn.click()  # пауза, щоб позиція не пливла
    base = win.player.position()
    win.fwd_btn.click()
    assert abs(win.player.position() - (base + SKIP_MS)) < TOL
    win.back_btn.click()
    assert abs(win.player.position() - base) < TOL


def test_seek_clamps_to_bounds(win):
    start(win)
    win.play_btn.click()
    win.player.setPosition(1000)
    win.back_btn.click()
    assert win.player.position() == 0
    win.player.setPosition(DURATION - 2000)
    win.fwd_btn.click()
    assert win.player.position() == win.player.duration()


def test_progress_bar_seeks(win):
    start(win)
    win.play_btn.click()
    win.pos_slider.setSliderPosition(7000)
    win.pos_slider.triggerAction(QAbstractSlider.SliderMove)
    assert abs(win.player.position() - 7000) < TOL
    wait_until(lambda: win.cur_label.text() == "00:07")


def test_hover_shows_timecode(win):
    start(win)
    s = win.pos_slider
    for frac in (0.25, 0.75):
        x = int(s.width() * frac)
        QTest.mouseMove(s, QPoint(x, s.height() // 2))
        expected = fmt_time(s.value_at(x))
        wait_until(lambda: QToolTip.text() == expected)
        assert abs(s.value_at(x) - frac * win.player.duration()) < 700  # час відповідає місцю на смузі


def test_hover_without_media_shows_nothing(win):
    QToolTip.hideText()
    wait_until(lambda: not QToolTip.isVisible())  # підказка глобальна: прибрати залишок з інших тестів
    QTest.mouseMove(win.pos_slider, QPoint(50, win.pos_slider.height() // 2))
    QTest.qWait(300)
    assert not QToolTip.isVisible(), QToolTip.text()


def test_value_at_edges(win):
    win.on_duration(DURATION)
    s = win.pos_slider
    assert s.value_at(0) == 0
    assert s.value_at(s.width() - 1) == DURATION
    assert abs(s.value_at(s.width() // 2) - DURATION // 2) < 200


def test_click_on_progress_bar_jumps(win):
    start(win)
    win.play_btn.click()
    s = win.pos_slider
    x = int(s.width() * 0.8)
    QTest.mouseClick(s, Qt.LeftButton, Qt.NoModifier, QPoint(x, s.height() // 2))
    assert abs(win.player.position() - s.value_at(x)) < TOL
    assert abs(win.player.position() - 0.8 * DURATION) < 700


def test_progress_bar_follows_playback(win):
    start(win)
    wait_until(lambda: win.player.position() > 1200)
    assert abs(win.pos_slider.value() - win.player.position()) < TOL
    assert win.cur_label.text() == fmt_time(win.player.position())


def test_slider_not_moved_while_dragged(win):
    win.on_duration(DURATION)
    win.pos_slider.setValue(3000)
    win.pos_slider.setSliderDown(True)
    win.on_position(9000)
    assert win.pos_slider.value() == 3000
    assert win.cur_label.text() == "00:09"  # час показуємо все одно
    win.pos_slider.setSliderDown(False)
    win.on_position(9000)
    assert win.pos_slider.value() == 9000


def test_mute_toggle(win):
    assert not win.audio.isMuted()
    win.mute_btn.click()
    assert win.audio.isMuted() and win.mute_btn.toolTip() == "Увімкнути звук (M)"
    assert win.vol_slider.value() == 70  # гучність не губиться
    win.mute_btn.click()
    assert not win.audio.isMuted() and win.mute_btn.toolTip() == "Вимкнути звук (M)"


def test_volume(win):
    assert win.audio.volume() == pytest.approx(0.7, abs=0.01)
    win.vol_slider.setValue(25)
    assert win.audio.volume() == pytest.approx(0.25, abs=0.01)
    win.vol_slider.setValue(0)
    assert win.audio.volume() == 0


# ---------- помилки та додаткові можливості ----------

FORMAT = ERRORS[QMediaPlayer.FormatError]


@pytest.mark.parametrize("name, reason", [
    ("nope.mp4", ERRORS[QMediaPlayer.ResourceError]),  # файлу немає
    ("bad/empty.mp4", FORMAT),                          # 0 байт
    ("bad/garbage.mp4", FORMAT),                        # випадкові байти з розширенням .mp4
    ("bad/text.mp3", FORMAT),                           # текст з розширенням .mp3
    ("bad/notes.txt", FORMAT),                          # звичайний текстовий файл
])
def test_invalid_file_shows_error(win, name, reason):
    win.open_source(str(MEDIA / name))
    wait_until(lambda: win.status.text() == f"Помилка: {reason}")
    assert win.stack.currentWidget() is win.placeholder
    assert win.hint.isVisibleTo(win) and win.hint.text() == f"Не вдалося відтворити: {reason}"
    assert win.status.toolTip()  # технічна деталь від Qt лишається в підказці


def test_unreachable_url_shows_error(win, http_port):
    for url in (f"http://127.0.0.1:{http_port}/missing.mp4", f"http://127.0.0.1:{free_port()}/x.mp4"):
        win.open_source(url)
        wait_until(lambda: win.status.text() == "Помилка: посилання недоступне або за ним немає файлу")


def test_error_after_video_hides_video(win):
    start(win, MEDIA / "sample.mp4")
    wait_until(lambda: win.stack.currentWidget() is win.video)
    win.open_source(str(MEDIA / "bad/garbage.mp4"))
    wait_until(lambda: win.status.text().startswith("Помилка"))
    wait_until(lambda: win.stack.currentWidget() is win.placeholder)  # старий кадр не лишається


def test_recovers_after_error(win):
    win.open_source(str(MEDIA / "bad/garbage.mp4"))
    wait_until(lambda: win.status.text().startswith("Помилка"))
    start(win, MEDIA / "sample.mp4")
    assert not win.hint.isVisibleTo(win)
    wait_until(lambda: win.stack.currentWidget() is win.video)


def test_truncated_file_plays_what_is_left(win):
    start(win, MEDIA / "bad/truncated.mp4")  # обрізано до ~37 %: заголовок цілий, даних менше
    assert win.player.error() == QMediaPlayer.NoError


def test_empty_source_ignored(win):
    before = win.status.text()
    win.open_source("   ")
    assert win.player.source().isEmpty()
    assert win.status.text() == before


def test_url_dialog_cancel_does_nothing(win, monkeypatch):
    monkeypatch.setattr("player.QInputDialog.getText", lambda *a, **k: (str(MEDIA / "sample.mp3"), False))
    win.url_btn.click()
    assert win.player.source().isEmpty()


def test_dialogs_open_media(win, monkeypatch):
    files = [str(MEDIA / "sample.wav"), str(MEDIA / "sample.mp4")]
    monkeypatch.setattr("player.QFileDialog.getOpenFileNames", lambda *a, **k: (files, ""))
    win.open_btn.click()
    assert win.player.source() == QUrl.fromLocalFile(files[0])
    assert win.list.count() == 2
    monkeypatch.setattr("player.QFileDialog.getOpenFileNames", lambda *a, **k: ([], ""))
    win.open_btn.click()  # скасування діалогу нічого не змінює
    assert win.list.count() == 2
    url = QUrl.fromLocalFile(str(MEDIA / "sample.mp3")).toString()  # без мережі: інакше гонка в Qt при teardown
    monkeypatch.setattr("player.QInputDialog.getText", lambda *a, **k: (url, True))
    win.url_btn.click()
    assert win.player.source() == QUrl(url)


def test_drag_and_drop(win):
    assert win.acceptDrops()
    mime = QMimeData()
    mime.setUrls([QUrl.fromLocalFile(str(MEDIA / "sample.webm")), QUrl.fromLocalFile(str(MEDIA / "sample.mp3"))])
    enter = QDragEnterEvent(QPoint(10, 10), Qt.CopyAction, mime, Qt.LeftButton, Qt.NoModifier)
    enter.ignore()
    win.dragEnterEvent(enter)
    assert enter.isAccepted()
    ev = QDropEvent(QPointF(10, 10), Qt.CopyAction, mime, Qt.LeftButton, Qt.NoModifier)
    win.dropEvent(ev)
    assert win.player.source() == QUrl.fromLocalFile(str(MEDIA / "sample.webm"))
    assert [win.list.item(i).text() for i in range(win.list.count())] == ["sample.webm", "sample.mp3"]


def test_keyboard_shortcuts(win):
    start(win)
    win.activateWindow()
    QTest.keyClick(win, Qt.Key_Space)
    assert win.player.playbackState() == QMediaPlayer.PausedState
    base = win.player.position()
    QTest.keyClick(win, Qt.Key_Right)
    assert abs(win.player.position() - (base + SKIP_MS)) < TOL
    QTest.keyClick(win, Qt.Key_Left)
    assert abs(win.player.position() - base) < TOL
    QTest.keyClick(win, Qt.Key_M)
    assert win.audio.isMuted()
    QTest.keyClick(win, Qt.Key_R)
    assert win.repeat_btn.isChecked()
    QTest.keyClick(win, Qt.Key_L)
    assert win.list_btn.isChecked()


def test_playlist_keys(win):
    win.add_sources([str(MEDIA / "sample.wav"), str(MEDIA / "sample.mp3")])
    win.activateWindow()
    QTest.keyClick(win, Qt.Key_N)
    assert win.index == 1
    QTest.keyClick(win, Qt.Key_P)
    assert win.index == 0


# ---------- список відтворення ----------

def names(win):
    return [win.list.item(i).text() for i in range(win.list.count())]


def test_playlist_add_and_navigate(win):
    win.add_sources([str(MEDIA / n) for n in ("sample.wav", "sample.mp3", "sample.mp4")] + ["  "])
    assert names(win) == ["sample.wav", "sample.mp3", "sample.mp4"]  # порожні рядки відкинуто
    assert win.list_btn.isChecked() and win.list.isVisibleTo(win)
    assert win.index == 0 and win.list.currentRow() == 0
    win.next_btn.click()
    assert win.index == 1 and win.player.source() == QUrl.fromLocalFile(str(MEDIA / "sample.mp3"))
    assert win.windowTitle() == "sample.mp3 — Медіаплеєр"
    win.prev_btn.click()
    win.prev_btn.click()  # на першому треку «назад» нікуди не веде
    assert win.index == 0
    win.list.itemActivated.emit(win.list.item(2))
    assert win.index == 2 and win.list.currentRow() == 2
    win.next_btn.click()  # на останньому — теж
    assert win.index == 2


def test_single_file_keeps_list_hidden(win):
    start(win, MEDIA / "sample.mp3")
    assert not win.list_btn.isChecked() and not win.list.isVisibleTo(win)
    win.list_btn.click()
    assert win.list.isVisibleTo(win)


def test_open_appends_to_playlist(win):
    start(win, MEDIA / "sample.wav")
    start(win, MEDIA / "sample.mp3")
    assert names(win) == ["sample.wav", "sample.mp3"] and win.index == 1


def test_auto_advance_at_end(win):
    win.add_sources([str(MEDIA / "sample.wav"), str(MEDIA / "sample.mp3")])
    wait_until(lambda: win.player.position() > 0)
    win.player.setPosition(DURATION - 600)
    wait_until(lambda: win.index == 1)
    assert win.player.source() == QUrl.fromLocalFile(str(MEDIA / "sample.mp3"))
    # дочекатися, поки наступний трек справді заграє: знищення плеєра посеред завантаження,
    # почате з сигналу EndOfMedia, валить Qt FFmpeg у тестовому середовищі
    wait_until(lambda: win.player.position() > 0)


def test_repeat_loops_same_file(win):
    win.add_sources([str(MEDIA / "sample.wav"), str(MEDIA / "sample.mp3")])
    wait_until(lambda: win.player.position() > 0)
    win.repeat_btn.click()
    assert win.player.loops() == QMediaPlayer.Infinite
    win.player.setPosition(DURATION - 600)
    wait_until(lambda: 0 < win.player.position() < 3000)  # почалося спочатку
    assert win.index == 0
    win.repeat_btn.click()
    assert win.player.loops() == QMediaPlayer.Once


# ---------- швидкість, повний екран, кадр ----------

def test_speed_cycles(win):
    assert win.player.playbackRate() == 1.0 and win.speed_btn.text() == "1×"
    seen = []
    for _ in SPEEDS:
        win.speed_btn.click()
        seen.append((win.player.playbackRate(), win.speed_btn.text()))
    assert seen == [(1.25, "1.25×"), (1.5, "1.5×"), (2.0, "2×"), (0.5, "0.5×"), (0.75, "0.75×"), (1.0, "1×")]


def test_fullscreen_toggle(win):
    win.full_btn.click()
    wait_until(win.isFullScreen)
    win.activateWindow()
    QTest.keyClick(win, Qt.Key_Escape)
    wait_until(lambda: not win.isFullScreen())
    QTest.keyClick(win, Qt.Key_Escape)  # Esc у звичайному вікні нічого не робить
    QTest.qWait(100)
    assert not win.isFullScreen()


def test_snapshot_saves_frame(win, monkeypatch, tmp_path):
    monkeypatch.setattr("player.QStandardPaths.writableLocation", lambda *_: str(tmp_path))
    start(win, MEDIA / "sample.mp4")
    wait_until(lambda: win.video.videoSink().videoFrame().isValid())
    win.play_btn.click()
    path = win.snapshot()
    assert path and path.startswith(str(tmp_path)) and path.endswith(".png")
    assert QImage(path).size().width() == 160  # розмір кадру тестового відео
    assert win.status.text() == f"Кадр збережено: {path}"


def test_snapshot_without_video(win, monkeypatch, tmp_path):
    monkeypatch.setattr("player.QStandardPaths.writableLocation", lambda *_: str(tmp_path))
    assert win.snapshot() is None  # нічого не відкрито
    start(win, MEDIA / "sample.mp3")
    assert win.snapshot() is None
    assert win.status.text() == "Немає кадру: спершу відкрийте відео"
    assert not list(tmp_path.iterdir())
