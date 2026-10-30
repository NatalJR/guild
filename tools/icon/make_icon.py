# Generates the Claude Directory listing icon at .claude-plugin/icon.png.
# Run from the repository root: python tools/icon/make_icon.py
# Dev-time only: Python 3 standard library, no third-party imports.
# Anti-aliasing is coverage-based: each shape's signed distance at the pixel
# centre maps to a 0..1 coverage that blends the shape over what lies below.
import math
import os
import struct
import zlib

SIZE = 1024
CENTRE = SIZE / 2
CORNER_RADIUS = 180
BACKGROUND = (0x1F, 0x29, 0x37)
MEMBER_COUNT = 6
RING_RADIUS = 300
RING_CIRCLE_RADIUS = 58
RING_COLOUR = (0xF3, 0xF4, 0xF6)
CENTRE_CIRCLE_RADIUS = 78
CENTRE_COLOUR = (0xF5, 0x9E, 0x0B)
LINE_HALF_WIDTH = 7
LINE_COLOUR = (0x9C, 0xA3, 0xAF)


def coverage(distance):
    return min(max(0.5 - distance, 0.0), 1.0)


def rounded_square_mask(x, y):
    inner = CENTRE - CORNER_RADIUS
    qx = abs(x - CENTRE) - inner
    qy = abs(y - CENTRE) - inner
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return coverage(outside + inside - CORNER_RADIUS)


def circle_coverage(x, y, centre, radius):
    return coverage(math.hypot(x - centre[0], y - centre[1]) - radius)


def line_coverage(x, y, start, end, half_width):
    dx, dy = end[0] - start[0], end[1] - start[1]
    t = ((x - start[0]) * dx + (y - start[1]) * dy) / (dx * dx + dy * dy)
    t = min(max(t, 0.0), 1.0)
    distance = math.hypot(x - start[0] - t * dx, y - start[1] - t * dy)
    return coverage(distance - half_width)


def blend(base, colour, amount):
    return tuple(b + (c - b) * amount for b, c in zip(base, colour))


def ring_centres():
    step = 2 * math.pi / MEMBER_COUNT
    return [
        (CENTRE + RING_RADIUS * math.sin(i * step), CENTRE - RING_RADIUS * math.cos(i * step))
        for i in range(MEMBER_COUNT)
    ]


def shade(x, y, members):
    centre = (CENTRE, CENTRE)
    colour = BACKGROUND
    for member in members:
        colour = blend(colour, LINE_COLOUR, line_coverage(x, y, centre, member, LINE_HALF_WIDTH))
    for member in members:
        colour = blend(colour, RING_COLOUR, circle_coverage(x, y, member, RING_CIRCLE_RADIUS))
    return blend(colour, CENTRE_COLOUR, circle_coverage(x, y, centre, CENTRE_CIRCLE_RADIUS))


def render_pixel(x, y, members):
    px, py = x + 0.5, y + 0.5
    alpha = rounded_square_mask(px, py)
    colour = shade(px, py, members) if alpha > 0 else BACKGROUND
    return bytes(round(c) for c in colour) + bytes((round(alpha * 255),))


def render_row(y, members):
    pixels = (render_pixel(x, y, members) for x in range(SIZE))
    return b"\x00" + b"".join(pixels)


def chunk(kind, data):
    body = kind + data
    crc = zlib.crc32(body) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + body + struct.pack(">I", crc)


def write_png(path, rows):
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    data = zlib.compress(b"".join(rows), 9)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", data) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = os.path.join(root, ".claude-plugin", "icon.png")
    members = ring_centres()
    rows = [render_row(y, members) for y in range(SIZE)]
    write_png(path, rows)
    print(path)


if __name__ == "__main__":
    main()
