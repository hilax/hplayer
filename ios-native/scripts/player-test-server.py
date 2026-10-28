from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
from urllib.parse import unquote
from urllib.request import Request, urlopen
import tempfile

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
        if self.path.startswith("/catalog/") or self.path.startswith("/meta/"):
            fixtures = json.loads((root / "metadata-fixture.json").read_text(encoding="utf-8"))
            if self.path.startswith("/catalog/"):
                kind = self.path.split("/")[2]
                query = unquote(self.path.split("search=", 1)[-1].removesuffix(".json")).lower()
                result = {"metas": [item for item in fixtures if item["type"] == kind and query in item["name"].lower()]}
            else:
                imdb = self.path.rsplit("/", 1)[-1].removesuffix(".json")
                result = {"meta": next(item for item in fixtures if item["id"] == imdb)}
            for item in result.get("metas", [result.get("meta")]):
                if item:
                    item["poster"] = f"http://127.0.0.1:8765/ui-artwork/{item['id']}/poster.jpg"
                    item["background"] = f"http://127.0.0.1:8765/ui-artwork/{item['id']}/background.jpg"
            body = json.dumps(result).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/ui-artwork/"):
            parts = self.path.split("/")
            fixtures = json.loads((root / "metadata-fixture.json").read_text(encoding="utf-8"))
            item = next(item for item in fixtures if item["id"] == parts[2])
            cache = Path(tempfile.gettempdir()) / "hplayer-artwork"
            cache.mkdir(exist_ok=True)
            target = cache / f"{parts[2]}-{parts[3]}"
            try:
                if not target.exists():
                    with urlopen(Request(item[parts[3].removesuffix('.jpg')], headers={"User-Agent": "HPlayer/1.1"}), timeout=15) as upstream:
                        target.write_bytes(upstream.read())
                body = target.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception:
                self.send_error(502, "Artwork unavailable")
            return
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
