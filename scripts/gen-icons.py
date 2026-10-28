"""生成 PWA 图标：渐变底 + 白色 H。无第三方依赖。"""

import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "web" / "public"


def in_rect(x: float, y: float, x0: float, y0: float, x1: float, y1: float) -> bool:
    return x0 <= x <= x1 and y0 <= y <= y1


def pixel(x: int, y: int, size: int) -> tuple[int, int, int, int]:
    u = x / size
    v = y / size
    # 对角渐变：#4f8cff -> #7b5cff
    t = (u + v) / 2
    r = int(0x4F + (0x7B - 0x4F) * t)
    g = int(0x8C + (0x5C - 0x8C) * t)
    b = int(0xFF + (0xFF - 0xFF) * t)

    # 白色 H：两竖 + 一横
    if (
        in_rect(u, v, 0.28, 0.26, 0.38, 0.74)
        or in_rect(u, v, 0.62, 0.26, 0.72, 0.74)
        or in_rect(u, v, 0.28, 0.46, 0.72, 0.54)
    ):
        r, g, b = 255, 255, 255
    return r, g, b, 255


def make_png(path: Path, size: int) -> None:
    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter type: none
        for x in range(size):
            raw.extend(pixel(x, y, size))

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(png)
    print(f"wrote {path} ({len(png)} bytes)")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    make_png(OUT / "icon-180.png", 180)
    make_png(OUT / "icon-512.png", 512)
