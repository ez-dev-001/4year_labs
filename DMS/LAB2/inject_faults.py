"""Перевірка тестів методом ін'єкції помилок (мутаційне тестування).

Кожна мутація вносить у копію player.py одну навмисну помилку і запускає тести.
Мутант «вбитий», якщо тести впали; «вижив» — тести його не помітили.
Запуск: python inject_faults.py
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TIMEOUT = 60

# (опис, що замінити, на що замінити) — кожен фрагмент має зустрічатися в player.py рівно раз
MUTANTS = [
    ("fmt_time: від'ємний час не обрізається", "max(ms, 0) // 1000", "ms // 1000"),
    ("fmt_time: помилка в секундах на годину", "divmod(s, 3600)", "divmod(s, 360)"),
    ("fmt_time: 100 секунд у хвилині", "divmod(rest, 60)", "divmod(rest, 100)"),
    ("fmt_time: години показуються навпаки", "if h else", "if not h else"),
    ("fmt_time: хвилини без ведучого нуля", 'else f"{m:02}:{s:02}"', 'else f"{m}:{s:02}"'),
    ("to_url: посилання вважається локальним файлом", 'if "://" in text', 'if "//:" in text'),
    ("to_url: пробіли не обрізаються", "text = text.strip()", "text = text"),
    ("to_url: усе вважається посиланням", "else QUrl.fromLocalFile(text)", "else QUrl(text)"),
    ("seek: напрям перемотки навпаки", "position() + delta_ms", "position() - delta_ms"),
    ("seek: крок перемотки подвоєно", "position() + delta_ms", "position() + 2 * delta_ms"),
    ("кнопка «назад» мотає вперед", "back_btn.clicked.connect(lambda: self.seek(-SKIP_MS))",
     "back_btn.clicked.connect(lambda: self.seek(SKIP_MS))"),
    ("кнопка «вперед» не працює", "fwd_btn.clicked.connect(lambda: self.seek(SKIP_MS))",
     "fwd_btn.clicked.connect(lambda: self.seek(0))"),
    ("Stop працює як Pause", "connect(self.player.stop)", "connect(self.player.pause)"),
    ("Play/Pause: умова навпаки", "playbackState() == QMediaPlayer.PlayingState:",
     "playbackState() != QMediaPlayer.PlayingState:"),
    ("іконка/підказка Play/Pause навпаки", "playing = state == QMediaPlayer", "playing = state != QMediaPlayer"),
    ("progress bar не перемотує", "setPosition(self.pos_slider.sliderPosition())", "setPosition(0)"),
    ("progress bar смикається під час перетягування", "if not self.pos_slider.isSliderDown():",
     "if True:"),
    ("progress bar не рухається під час відтворення", "self.pos_slider.setValue(ms)", "pass"),
    ("поточний час не оновлюється", "self.cur_label.setText(fmt_time(ms))",
     "self.cur_label.setText(fmt_time(0))"),
    ("загальний час не оновлюється", "self.total_label.setText(fmt_time(ms))",
     "self.total_label.setText(fmt_time(0))"),
    ("неправильний діапазон progress bar", "setRange(0, ms)", "setRange(0, 1000)"),
    ("гучність у 10 разів більша", "setVolume(v / 100)", "setVolume(v / 10)"),
    ("гучність за замовчуванням 100%", "self.vol_slider.setValue(70)", "self.vol_slider.setValue(100)"),
    ("помилка відтворення не показується", 'self.status.setText(f"Помилка: {reason}")', 'pass'),
    ("технічна деталь помилки губиться", "self.status.setToolTip(message)", "pass"),
    ("пояснення помилки на екрані не з'являється", "        self.hint.show()\n\n    def on_muted", "\n    def on_muted"),
    ("усі помилки показуються технічним текстом Qt", "reason = ERRORS.get(error, message)", "reason = message"),
    ("недоступне посилання описане як відсутній файл", "and not self.player.source().isLocalFile():", "and False:"),
    ("порожній рядок не ігнорується", "for t in texts if t.strip()]", "for t in texts]"),
    ("порожній список джерел не ігнорується", "        if not urls:\n            return\n", ""),
    ("після відкриття не стартує відтворення",
     'toDisplayString()}")\n        self.player.play()', 'toDisplayString()}")'),
    ("скасування діалогу URL відкриває файл", "        if ok:\n", "        if True:\n"),
    ("Drag&Drop вимкнено", "self.setAcceptDrops(True)", "self.setAcceptDrops(False)"),
    ("dragEnter не приймає файли", "event.acceptProposedAction()", "event.ignore()"),
    ("drop нічого не відкриває", "self.add_sources([url.toString() for url in event.mimeData().urls()])", "pass"),
    ("drop бере лише перший файл", "for url in event.mimeData().urls()])", "for url in event.mimeData().urls()[:1]])"),
    ("клавіша → мотає назад", "(Qt.Key_Right, lambda: self.seek(SKIP_MS))",
     "(Qt.Key_Right, lambda: self.seek(-SKIP_MS))"),
    ("пробіл не керує відтворенням", "(Qt.Key_Space, self.toggle_play)", "(Qt.Key_S, self.toggle_play)"),
    ("кнопка звуку не вимикає звук", "self.audio.setMuted(not self.audio.isMuted())", "self.audio.setMuted(False)"),
    ("підказка кнопки звуку не оновлюється", "self.audio.mutedChanged.connect(self.on_muted)", "pass"),
    ("клавіша M не вимикає звук", "(Qt.Key_M, self.mute_btn.click)", "(Qt.Key_N, self.mute_btn.click)"),
    ("відео не показується на екрані", "self.video if has else self.placeholder", "self.placeholder"),
    ("для аудіо лишається чорний екран відео", "self.video if has else self.placeholder", "self.video"),
    ("немає назви файлу на обкладинці", "self.cover.setText(name)", "pass"),
    ("підказка порожнього стану не ховається", "self.hint.hide()", "pass"),
    ("смуга: таймкод не показується", "        self.show_time(int(event.position().x()))\n", ""),
    ("смуга: таймкод зникає через пів секунди", "            self.show_time(event.pos().x())\n            return True", "            return False"),
    ("смуга: таймкод без відкритого файлу", "        self.setMaximum(0)  #", "        pass  #"),
    ("смуга: таймкод не враховує ширину повзунка", "x - groove.x() - handle.width() // 2, span)", "x, self.width())"),
    ("смуга: клік не перемотує", "            self.triggerAction(QAbstractSlider.SliderMove)", "            pass"),
    ("смуга: клік ставить не туди", "self.setSliderPosition(self.value_at(int(event.position().x())))", "self.setSliderPosition(0)"),
    ("список: панель не з'являється для кількох файлів", "        if len(self.playlist) > 1:\n            self.list_btn.setChecked(True)\n", ""),
    ("список: панель з'являється навіть для одного файлу", "if len(self.playlist) > 1:", "if len(self.playlist) > 0:"),
    ("список: кнопка не показує панель", "self.list_btn.toggled.connect(self.list.setVisible)", "pass"),
    ("список: грає не перший з доданих", "self.play_index(first)", "self.play_index(len(self.playlist) - 1)"),
    ("список: назви не додаються", "self.list.addItem(url.fileName() or url.toDisplayString())", "self.list.addItem('')"),
    ("список: «наступний» не працює", "self.next_btn.clicked.connect(lambda: self.play_index(self.index + 1))", "pass"),
    ("список: «попередній» не працює", "self.prev_btn.clicked.connect(lambda: self.play_index(self.index - 1))", "pass"),
    ("список: вихід за межі", "if not 0 <= i < len(self.playlist):", "if i >= len(self.playlist):"),
    ("список: подвійний клік не вмикає трек", "self.list.itemActivated.connect(", "self.list.itemChanged.connect("),
    ("список: рядок не підсвічується", "        self.list.setCurrentRow(i)\n", ""),
    ("список: немає автопереходу", "            self.play_index(self.index + 1)  # саме", "            pass  # саме"),
    ("діалог відкриває лише один файл", "        self.add_sources(paths)", "        self.add_sources(paths[:1])"),
    ("повтор не вмикається", "QMediaPlayer.Infinite if on else", "QMediaPlayer.Once if on else"),
    ("швидкість не змінюється", "        self.player.setPlaybackRate(rate)\n", ""),
    ("напис швидкості не оновлюється", 'self.speed_btn.setText(f"{rate:g}×")', "pass"),
    ("швидкість перескакує крок", "SPEEDS.index(self.player.playbackRate()) + 1)", "SPEEDS.index(self.player.playbackRate()) + 2)"),
    ("повний екран не вмикається", "self.showFullScreen() if full else", "self.showNormal() if full else"),
    ("Esc не виходить з повного екрана", "self.isFullScreen() and self.toggle_fullscreen()", "None"),
    ("кадр зберігається без відео", "if not (self.player.hasVideo() and frame.isValid()):", "if not frame.isValid():"),
    ("кадр не зберігається", "if not frame.toImage().save(path):", "if True:"),
    ("клавіша N не перемикає трек", "(Qt.Key_N, self.next_btn.click)", "(Qt.Key_J, self.next_btn.click)"),
    ("заголовок вікна без назви файлу", 'self.setWindowTitle(f"{name} — Медіаплеєр")', "pass"),
]


def run_once(cwd: Path) -> tuple[str, str]:
    cmd = [sys.executable, "-m", "pytest", "-x", "-q", "-p", "no:cacheprovider", "tests"]
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace", timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return "timeout", ""
    return ("pass" if r.returncode == 0 else "fail"), r.stdout[-1500:]


def run_tests(cwd: Path) -> tuple[str, str]:
    """Падіння рахується, лише якщо повторилось двічі: відсіює рідкісні збої Qt FFmpeg."""
    result, out = run_once(cwd)
    if result != "pass":
        result, out = run_once(cwd)
    return result, out


def main():
    src = (ROOT / "player.py").read_text(encoding="utf-8")
    for name, old, _new in MUTANTS:
        assert src.count(old) == 1, f"фрагмент мутанта «{name}» має бути в коді рівно раз"

    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "proj"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache"))
        target = work / "player.py"

        print("Еталонний прогін тестів на незміненому коді...", flush=True)
        result, out = run_tests(work)
        if result != "pass":
            sys.exit(f"Тести падають і без мутацій — спочатку полагодьте їх.\n{out}")

        survived = []
        for i, (name, old, new) in enumerate(MUTANTS, 1):
            target.write_text(src.replace(old, new), encoding="utf-8")
            result, _ = run_tests(work)
            verdict = "ВИЖИВ" if result == "pass" else "вбитий" + (" (timeout)" if result == "timeout" else "")
            print(f"{i:2}. {verdict:18} {name}", flush=True)
            if result == "pass":
                survived.append(name)
        target.write_text(src, encoding="utf-8")

    killed = len(MUTANTS) - len(survived)
    print(f"\nВбито {killed}/{len(MUTANTS)} мутантів ({killed / len(MUTANTS):.0%}).")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
