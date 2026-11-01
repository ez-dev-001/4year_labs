import os
import sys
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")  # тести без показу вікон
if sys.platform.startswith("linux"):
    os.environ.setdefault("QT_AUDIO_BACKEND", "pulseaudio")  # без звукової карти pipewire падає

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pytest  # noqa: E402
from PySide6.QtCore import QCoreApplication, QEvent, QUrl  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

MEDIA = Path(__file__).parent / "media"


@pytest.fixture(scope="session")
def app():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def win(app):
    from player import Player
    w = Player()
    w.show()
    yield w
    w.player.setSource(QUrl())  # звільнити декодер FFmpeg
    w.close()
    w.deleteLater()
    # без цього старі плеєри накопичуються між тестами і Qt іноді зависає в stop()
    QCoreApplication.sendPostedEvents(None, QEvent.DeferredDelete)
