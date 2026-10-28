from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(__file__).resolve().parent
expected_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
expected_cookies = ("UID=ui-test", "CID=ui-test", "SEID=ui-test", "KID=ui-test")


class PlayerTestHandler(SimpleHTTPRequestHandler):
    def log_playback_request(self):
        print(
            f"{self.command} {self.path} "
            f"UA={self.headers.get('User-Agent', '')!r} "
            f"Referer={self.headers.get('Referer', '')!r} "
            f"Cookie={self.headers.get('Cookie', '')!r}",
            flush=True,
        )

    def do_GET(self):
        self.log_playback_request()
        cookie = self.headers.get("Cookie", "")
        if (
            self.headers.get("User-Agent") != expected_agent
            or self.headers.get("Referer") != "https://115.com/"
            or not all(value in cookie for value in expected_cookies)
        ):
            self.send_error(403, "Expected 115 playback headers")
            return
        super().do_GET()

    def do_HEAD(self):
        self.log_playback_request()
        cookie = self.headers.get("Cookie", "")
        if (
            self.headers.get("User-Agent") != expected_agent
            or self.headers.get("Referer") != "https://115.com/"
            or not all(value in cookie for value in expected_cookies)
        ):
            self.send_error(403, "Expected 115 playback headers")
            return
        super().do_HEAD()


ThreadingHTTPServer(("127.0.0.1", 8765), partial(PlayerTestHandler, directory=str(root))).serve_forever()
