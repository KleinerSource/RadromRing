"""Render the Settings entry icon (rounded square with a bell) at 1x/2x/3x.

Usage: python3 tools/make_icon.py   (writes Prefs/Resources/icon*.png)
Pure standard library so it runs anywhere.
"""

import pathlib
import struct
import zlib

OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "Prefs" / "Resources"
SUPERSAMPLE = 4


def is_bell(x, y):
    if 0.30 <= y <= 0.68:
        k = (y - 0.30) / 0.38
        if abs(x - 0.5) <= 0.15 + 0.15 * k ** 1.8:
            return True
    if (x - 0.5) ** 2 + (y - 0.31) ** 2 <= 0.15 ** 2:
        return True
    if 0.655 <= y <= 0.715 and abs(x - 0.5) <= 0.31:
        return True
    if (x - 0.5) ** 2 + (y - 0.765) ** 2 <= 0.065 ** 2:
        return True
    return (x - 0.5) ** 2 + (y - 0.165) ** 2 <= 0.04 ** 2


def sample(x, y):
    radius = 0.225
    cx = min(max(x, radius), 1 - radius)
    cy = min(max(y, radius), 1 - radius)
    if (x - cx) ** 2 + (y - cy) ** 2 > radius ** 2:
        return None
    if is_bell(x, y):
        return (255, 255, 255)
    return (int(255 * (0.36 + 0.25 * y)), int(255 * (0.35 - 0.15 * y)), int(255 * (0.95 - 0.10 * y)))


def render(size):
    rows = []
    for py in range(size):
        row = bytearray([0])
        for px in range(size):
            red = green = blue = covered = 0
            for sy in range(SUPERSAMPLE):
                for sx in range(SUPERSAMPLE):
                    color = sample((px + (sx + 0.5) / SUPERSAMPLE) / size,
                                   (py + (sy + 0.5) / SUPERSAMPLE) / size)
                    if color is None:
                        continue
                    red += color[0]
                    green += color[1]
                    blue += color[2]
                    covered += 1
            if covered == 0:
                row += bytes(4)
            else:
                alpha = round(255 * covered / SUPERSAMPLE ** 2)
                row += bytes([red // covered, green // covered, blue // covered, alpha])
        rows.append(bytes(row))
    return b"".join(rows)


def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data +
            struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def write_png(path, size):
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
                     chunk(b"IDAT", zlib.compress(render(size), 9)) + chunk(b"IEND", b""))


def main():
    for name, size in (("icon.png", 29), ("icon@2x.png", 58), ("icon@3x.png", 87)):
        write_png(OUTPUT / name, size)
        print(f"wrote {OUTPUT / name}")


if __name__ == "__main__":
    main()
