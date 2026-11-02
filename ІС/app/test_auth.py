"""Самоперевірка сервера авторизації:  AUTH_DB=/tmp/t.db python -m unittest test_auth"""
import http.client
import os
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

os.environ.setdefault("AUTH_DB", os.path.join(tempfile.mkdtemp(), "auth.db"))
import auth  # noqa: E402


class AuthTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        auth.init_db()
        auth.add_user("tester", "secret123")
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), auth.Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def request(self, method, path, body=None, cookie=""):
        conn = http.client.HTTPConnection(*self.server.server_address)
        headers = {"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"}
        conn.request(method, path, body, headers)
        return conn.getresponse()

    def test_password(self):
        self.assertTrue(auth.check_password("tester", "secret123"))
        self.assertFalse(auth.check_password("tester", "wrong"))
        self.assertFalse(auth.check_password("nobody", "secret123"))

    def test_bad_username_rejected(self):
        with self.assertRaises(ValueError):
            auth.add_user("Іван", "secret123")

    def test_login_verify_logout(self):
        self.assertEqual(self.request("GET", "/auth/verify").status, 401)
        self.assertEqual(self.request("GET", "/auth/verify", cookie="session=forged").status, 401)
        self.assertEqual(self.request("POST", "/auth/login", "username=tester&password=wrong").status, 401)

        r = self.request("POST", "/auth/login", "username=tester&password=secret123")
        self.assertEqual(r.status, 302)
        cookie = r.getheader("Set-Cookie").split(";")[0]

        r = self.request("GET", "/auth/verify", cookie=cookie)
        self.assertEqual((r.status, r.getheader("X-User")), (200, "tester"))

        self.request("GET", "/auth/logout", cookie=cookie)
        self.assertEqual(self.request("GET", "/auth/verify", cookie=cookie).status, 401)


if __name__ == "__main__":
    unittest.main()
