"""Сервер авторизації: користувачі й сесії в SQLite.
nginx перед кожним запитом до Grafana/Prometheus питає GET /auth/verify (auth_request)
і пускає далі лише з валідною сесією; ім'я користувача передається в Grafana заголовком.

Додати користувача:  docker compose exec auth python auth.py adduser <логін>"""
import getpass
import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import sys
import time
from contextlib import closing
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

from prometheus_client import Counter, start_http_server

from obs import setup

DB = os.getenv("AUTH_DB", "/data/auth.db")
SESSION_TTL = 8 * 3600
DUMMY_SALT = secrets.token_bytes(16)

tracer, log = setup("auth")
LOGINS = Counter("auth_logins_total", "Спроби входу", ["result"])


def connect():
    return closing(sqlite3.connect(DB))


def init_db():
    with connect() as c:
        c.executescript("""
            CREATE TABLE IF NOT EXISTS users (name TEXT PRIMARY KEY, salt BLOB NOT NULL, hash BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS sessions (token TEXT PRIMARY KEY, name TEXT NOT NULL, expires REAL NOT NULL);
        """)


def hash_password(password, salt):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 200_000)


def add_user(name, password):
    # ім'я йде в HTTP-заголовок до Grafana, тому лише ASCII
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,32}", name) or len(password) < 6:
        raise ValueError("логін: латиниця/цифри/._- до 32 символів; пароль: від 6 символів")
    salt = secrets.token_bytes(16)
    with connect() as c, c:
        c.execute("INSERT OR REPLACE INTO users VALUES (?, ?, ?)", (name, salt, hash_password(password, salt)))


def check_password(name, password):
    with connect() as c:
        row = c.execute("SELECT salt, hash FROM users WHERE name = ?", (name,)).fetchone()
    if row is None:
        hash_password(password, DUMMY_SALT)  # однаковий час відповіді, щоб не можна було вгадати існуючі логіни
        return False
    return hmac.compare_digest(hash_password(password, row[0]), row[1])


def new_session(name):
    token = secrets.token_urlsafe(32)
    with connect() as c, c:
        c.execute("DELETE FROM sessions WHERE expires < ?", (time.time(),))
        c.execute("INSERT INTO sessions VALUES (?, ?, ?)", (token, name, time.time() + SESSION_TTL))
    return token


def session_user(token):
    if not token:
        return None
    with connect() as c:
        row = c.execute("SELECT name FROM sessions WHERE token = ? AND expires > ?", (token, time.time())).fetchone()
    return row[0] if row else None


def delete_session(token):
    with connect() as c, c:
        c.execute("DELETE FROM sessions WHERE token = ?", (token,))


LOGIN_PAGE = """<!doctype html><html lang="uk"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Вхід — ІС моніторингу БД</title>
<style>
body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#111217;color:#e6e6e6}
form{display:grid;gap:.75rem;width:min(20rem,90vw);padding:2rem;border:1px solid #2c2f36;border-radius:8px;background:#181b1f}
h1{font-size:1.25rem;margin:0 0 .5rem}label{display:grid;gap:.25rem;font-size:.9rem}
input,button{padding:.6rem;font-size:1rem;border-radius:4px;border:1px solid #2c2f36;background:#0b0c0e;color:inherit}
button{background:#3d71d9;border:0;cursor:pointer}.err{color:#ff7383;margin:0}
</style></head><body>
<form method="post" action="/auth/login"><h1>ІС моніторингу БД</h1>
<label>Логін<input name="username" autocomplete="username" required autofocus></label>
<label>Пароль<input name="password" type="password" autocomplete="current-password" required></label>
<button>Увійти</button>{error}</form></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def token(self):
        try:
            cookie = SimpleCookie(self.headers.get("Cookie", ""))
        except CookieError:
            return ""
        return cookie["session"].value if "session" in cookie else ""

    def reply(self, code, body=b"", headers=()):
        self.send_response(code)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def login_page(self, code=200, error=""):
        self.reply(code, LOGIN_PAGE.replace("{error}", error).encode(), [("Content-Type", "text/html; charset=utf-8")])

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/auth/verify":
            user = session_user(self.token())
            return self.reply(200, headers=[("X-User", user)]) if user else self.reply(401)
        if path == "/auth/login":
            return self.login_page()
        if path == "/auth/logout":
            delete_session(self.token())
            return self.reply(302, headers=[("Location", "/auth/login"), ("Set-Cookie", "session=; Path=/; Max-Age=0")])
        self.reply(404)

    def do_POST(self):
        if self.path != "/auth/login":
            return self.reply(404)
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 4096)
        except ValueError:
            return self.reply(400)
        form = parse_qs(self.rfile.read(length).decode(errors="replace"))
        name, password = form.get("username", [""])[0], form.get("password", [""])[0]
        with tracer.start_as_current_span("login", attributes={"enduser.id": name}):
            if check_password(name, password):
                LOGINS.labels("success").inc()
                log.info(f"login ok user={name!r}")
                cookie = f"session={new_session(name)}; Path=/; HttpOnly; SameSite=Lax; Max-Age={SESSION_TTL}"
                return self.reply(302, headers=[("Location", "/"), ("Set-Cookie", cookie)])
            LOGINS.labels("failure").inc()
            log.warning(f"login failed user={name!r}")
            self.login_page(401, '<p class="err">Невірний логін або пароль</p>')

    def log_message(self, *args):
        pass  # /auth/verify викликається на кожен запит до Grafana - не засмічуємо логи


def main():
    init_db()
    if sys.argv[1:2] == ["adduser"] and len(sys.argv) == 3:
        add_user(sys.argv[2], getpass.getpass("Пароль: "))
        return print(f"Користувача {sys.argv[2]} збережено")
    with connect() as c:
        empty = c.execute("SELECT count(*) FROM users").fetchone()[0] == 0
    if empty:
        add_user(os.environ["ADMIN_USER"], os.environ["ADMIN_PASSWORD"])
        log.info(f"created first user {os.environ['ADMIN_USER']!r}")
    start_http_server(9100)
    log.info("auth server listening on :8000")
    ThreadingHTTPServer(("", 8000), Handler).serve_forever()


if __name__ == "__main__":
    main()
