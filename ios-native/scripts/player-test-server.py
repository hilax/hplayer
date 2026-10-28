from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(__file__).resolve().parent
expected_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"


class PlayerTestHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("User-Agent") != expected_agent or self.headers.get("Referer") != "https://115.com/":
            self.send_error(403, "Expected 115 playback headers")
            return
        super().do_GET()

    def do_HEAD(self):
        if self.headers.get("User-Agent") != expected_agent or self.headers.get("Referer") != "https://115.com/":
            self.send_error(403, "Expected 115 playback headers")
            return
        super().do_HEAD()


ThreadingHTTPServer(("127.0.0.1", 8765), partial(PlayerTestHandler, directory=str(root))).serve_forever()
