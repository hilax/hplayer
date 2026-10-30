from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import threading
import time
from urllib.parse import unquote
from urllib.request import Request, urlopen
import tempfile

root = Path(__file__).resolve().parent
expected_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
expected_cookies = ("UID=ui-test", "CID=ui-test", "SEID=ui-test", "KID=ui-test")

# /stall/ 下的文件支持分段下载，并模拟 CDN 卡死：第一次往文件后半段跳转的请求只接受连接、
# 永远不回数据（播放器要能自己发现并重连）。之后的请求都正常返回，用来验证播放器能自己重连恢复。
stall_lock = threading.Lock()
stall_hung = set()


class PlayerTestHandler(SimpleHTTPRequestHandler):
    def log_playback_request(self):
        print(
            f"{self.command} {self.path} "
            f"UA={self.headers.get('User-Agent', '')!r} "
            f"Referer={self.headers.get('Referer', '')!r} "
            f"Cookie={self.headers.get('Cookie', '')!r}",
            flush=True,
        )

    def serve_stall_fixture(self, prefix="/stall/", may_hang=True):
        name = self.path.split("?", 1)[0].removeprefix(prefix)
        path = root / name
        if "/" in name or not path.is_file():
            self.send_error(404)
            return
        size = path.stat().st_size
        header = self.headers.get("Range", "")
        ranged = header.startswith("bytes=")
        start, end = 0, size - 1
        if ranged:
            first, _, last = header[6:].split(",")[0].partition("-")
            start = int(first) if first.strip() else 0
            end = min(int(last), size - 1) if last.strip() else size - 1
        with stall_lock:
            # 播放器打开 MP4 时可能会探一下文件末尾（offset == size），那个不算跳转，不挂
            hang = may_hang and self.command == "GET" and size * 0.4 < start < size - 65536 and name not in stall_hung
            if hang:
                stall_hung.add(name)
        print(f"{'STALL' if may_hang else 'RANGE'} {self.command} {name} Range={header!r} hang={hang}", flush=True)
        if hang:
            time.sleep(90)
            return
        if not may_hang:
            # /range/ 模拟网盘 CDN：每个请求先等一会儿才回数据，跳转时要重新发请求
            time.sleep(0.6)
        if start >= size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        length = end - start + 1
        self.send_response(206 if ranged else 200)
        self.send_header("Content-Type", "video/x-matroska" if name.endswith(".mkv") else "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if ranged:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        try:
            with path.open("rb") as source:
                source.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = source.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def range_headers_ok(self):
        cookie = self.headers.get("Cookie", "")
        return (
            self.headers.get("User-Agent") == expected_agent
            and self.headers.get("Referer") == "https://115.com/"
            and all(value in cookie for value in expected_cookies)
        )

    def send_json(self, result):
        body = json.dumps(result, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        # 番组计划搜索接口 POST /v0/search/subjects：按关键字在本地样例里找
        if self.path.split("?", 1)[0] == "/v0/search/subjects":
            length = int(self.headers.get("Content-Length", "0") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
            keyword = str(payload.get("keyword", "")).strip().lower()
            subjects = json.loads((root / "bangumi-fixture.json").read_text(encoding="utf-8"))
            found = [item for item in subjects if keyword and (keyword in item["name"].lower() or keyword in item["name_cn"].lower())]
            print(f"BANGUMI POST /v0/search/subjects keyword={keyword!r} UA={self.headers.get('User-Agent', '')!r} found={len(found)}", flush=True)
            self.send_json({"total": len(found), "limit": 10, "offset": 0, "data": found})
            return
        self.send_error(404)

    def do_GET(self):
        if self.path.startswith("/stall/"):
            self.serve_stall_fixture()
            return
        if self.path == "/bangumi-poster.jpg":
            body = (root / "bangumi-poster.jpg").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/range/"):
            # 和 115 一样要求带上请求头；支持分段下载，用来测 MKV（索引在文件末尾）的大跨度跳转
            if not self.range_headers_ok():
                self.log_playback_request()
                self.send_error(403, "Expected 115 playback headers")
                return
            self.serve_stall_fixture(prefix="/range/", may_hang=False)
            return
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
        if self.path.startswith("/stall/"):
            self.serve_stall_fixture()
            return
        if self.path.startswith("/range/"):
            self.serve_stall_fixture(prefix="/range/", may_hang=False)
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
        super().do_HEAD()


ThreadingHTTPServer(("127.0.0.1", 8765), partial(PlayerTestHandler, directory=str(root))).serve_forever()
