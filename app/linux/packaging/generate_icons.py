#!/usr/bin/env python3
"""Generates the Melsi app icon (indigo->violet tile, white shield, "M") and
writes every platform variant: iOS AppIcon set (opaque), macOS AppIcon set,
Windows app_icon.ico, Linux hicolor PNGs, and assets/icon/icon.png (kept if it
already exists). Requires Pillow:  pip install pillow
Usage: python3 app/linux/packaging/generate_icons.py
"""
import math, os
from PIL import Image, ImageDraw, ImageFilter, ImageChops

SS = 4
N = 1024 * SS
APP = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
OUT = os.path.join(APP, 'build', 'icon')

def lerp(a, b, t): return a + (b - a) * t
def lerp_c(c1, c2, t): return tuple(int(round(lerp(c1[i], c2[i], t))) for i in range(len(c1)))

def gradient(size, stops, angle_deg=135):
    w = h = size
    # diagonal gradient via a small image then resize (smooth)
    g = Image.new('RGB', (256, 256))
    px = g.load()
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    for y in range(256):
        for x in range(256):
            u, v = x / 255 - 0.5, y / 255 - 0.5
            t = (u * -dx + v * dy) / (abs(dx) * 0.5 + abs(dy) * 0.5) * 0.5 + 0.5
            t = min(1, max(0, t))
            for i in range(len(stops) - 1):
                p0, c0 = stops[i]; p1, c1 = stops[i + 1]
                if p0 <= t <= p1:
                    px[x, y] = lerp_c(c0, c1, (t - p0) / (p1 - p0)); break
    return g.resize((w, h), Image.BICUBIC)

def bezier(p0, p1, p2, p3, n=64):
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = mt**3*p0[0] + 3*mt*mt*t*p1[0] + 3*mt*t*t*p2[0] + t**3*p3[0]
        y = mt**3*p0[1] + 3*mt*mt*t*p1[1] + 3*mt*t*t*p2[1] + t**3*p3[1]
        pts.append((x, y))
    return pts

def shield_points(cx, top, bottom, half_w, s):
    # right half then mirrored; coordinates in 1024 space, scaled by s
    shoulder_y = top + (bottom - top) * 0.10
    right = []
    # top crest: center dips up slightly
    right += bezier((cx, top), (cx + half_w * 0.35, top + 18), (cx + half_w * 0.75, shoulder_y - 30), (cx + half_w, shoulder_y))
    # side down to bottom tip
    right += bezier((cx + half_w, shoulder_y), (cx + half_w * 1.02, top + (bottom - top) * 0.55), (cx + half_w * 0.62, bottom - (bottom - top) * 0.12), (cx, bottom))
    left = [(2 * cx - x, y) for (x, y) in reversed(right)]
    pts = right + left
    return [(x * s, y * s) for x, y in pts]

def rounded_mask(size, radius):
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return m

def artwork(size_px):
    """Full-bleed square artwork (no alpha) at supersampled resolution."""
    s = size_px / 1024
    stops = [(0.0, (67, 56, 202)), (0.55, (109, 64, 236)), (1.0, (168, 85, 247))]
    img = gradient(size_px, stops, 120).convert('RGBA')

    # soft top-left glow (gloss)
    glow = Image.new('L', (size_px, size_px), 0)
    ImageDraw.Draw(glow).ellipse((-0.35 * size_px, -0.45 * size_px, 0.85 * size_px, 0.62 * size_px), fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(size_px * 0.08))
    white = Image.new('RGBA', (size_px, size_px), (255, 255, 255, 255))
    img = Image.composite(white, img, glow.point(lambda v: int(v * 0.22)))

    # subtle bottom-right vignette
    vig = Image.new('L', (size_px, size_px), 0)
    ImageDraw.Draw(vig).ellipse((0.35 * size_px, 0.45 * size_px, 1.5 * size_px, 1.5 * size_px), fill=110)
    vig = vig.filter(ImageFilter.GaussianBlur(size_px * 0.12))
    dark = Image.new('RGBA', (size_px, size_px), (30, 16, 90, 255))
    img = Image.composite(dark, img, vig.point(lambda v: int(v * 0.5)))

    # shield
    pts = shield_points(512, 196, 858, 292, s)
    shield = Image.new('L', (size_px, size_px), 0)
    ImageDraw.Draw(shield).polygon(pts, fill=255)

    # drop shadow for the shield
    shadow = shield.filter(ImageFilter.GaussianBlur(size_px * 0.025))
    shadow = ImageChops.offset(shadow, 0, int(size_px * 0.018))
    img = Image.composite(Image.new('RGBA', (size_px, size_px), (25, 10, 80, 255)), img, shadow.point(lambda v: int(v * 0.45)))

    # shield fill: white -> very light lavender vertical gradient
    fill = Image.new('RGBA', (size_px, size_px))
    fd = ImageDraw.Draw(fill)
    for y in range(size_px):
        t = y / size_px
        fd.line((0, y, size_px, y), fill=lerp_c((255, 255, 255, 255), (232, 226, 255, 255), t))
    img = Image.composite(fill, img, shield)

    # "M" glyph cut into the shield, drawn with the brand gradient
    m_mask = Image.new('L', (size_px, size_px), 0)
    md = ImageDraw.Draw(m_mask)
    w = int(74 * s)
    p = [(372, 690), (372, 380), (512, 548), (652, 380), (652, 690)]
    p = [(x * s, y * s) for x, y in p]
    # brush-stamp the stroke: uniform width, round caps and joins
    r = w / 2
    for (x0, y0), (x1, y1) in zip(p, p[1:]):
        # thick segment body
        ang = math.atan2(y1 - y0, x1 - x0)
        nx, ny = -math.sin(ang) * r, math.cos(ang) * r
        md.polygon([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny), (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)], fill=255)
    for (x, y) in p:
        md.ellipse((x - r, y - r, x + r, y + r), fill=255)
    m_mask = ImageChops.multiply(m_mask, shield)
    m_grad = gradient(size_px, [(0.0, (79, 70, 229)), (1.0, (147, 51, 234))], 100).convert('RGBA')
    img = Image.composite(m_grad, img, m_mask)

    # glossy highlight on the upper part of the shield
    hl = Image.new('L', (size_px, size_px), 0)
    ImageDraw.Draw(hl).ellipse((0.18 * size_px, -0.12 * size_px, 0.82 * size_px, 0.42 * size_px), fill=70)
    hl = hl.filter(ImageFilter.GaussianBlur(size_px * 0.03))
    hl = ImageChops.multiply(hl, shield)
    img = Image.composite(Image.new('RGBA', (size_px, size_px), (255, 255, 255, 255)), img, hl.point(lambda v: int(v * 0.35)))
    return img.convert('RGB')

def main():
    art = artwork(N).resize((1024, 1024), Image.LANCZOS)
    art.save(os.path.join(OUT, 'icon_square.png'))  # full-bleed, opaque (iOS / Android adaptive)

    # rounded-square (squircle-ish) icon with transparent margin (macOS / desktop)
    size = 1024
    inner = 824  # Apple macOS grid
    radius = int(inner * 0.2237)
    big = artwork(inner * SS)
    mask = rounded_mask(inner * SS, radius * SS)
    tile = Image.new('RGBA', (inner * SS, inner * SS), (0, 0, 0, 0))
    tile.paste(big, (0, 0), mask)
    tile = tile.resize((inner, inner), Image.LANCZOS)
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    # soft shadow
    sh = Image.new('L', (size, size), 0)
    off = (size - inner) // 2
    ImageDraw.Draw(sh).rounded_rectangle((off, off + 12, off + inner, off + inner + 12), radius=radius, fill=110)
    sh = sh.filter(ImageFilter.GaussianBlur(18))
    canvas.paste(Image.new('RGBA', (size, size), (20, 10, 60, 255)), (0, 0), sh)
    canvas.alpha_composite(tile, (off, off))
    canvas.save(os.path.join(OUT, 'icon_macos.png'))

    # desktop/app master: rounded tile filling the canvas (small margin)
    inner2 = 960
    r2 = int(inner2 * 0.2237)
    big2 = artwork(inner2 * SS)
    mask2 = rounded_mask(inner2 * SS, r2 * SS)
    tile2 = Image.new('RGBA', (inner2 * SS, inner2 * SS), (0, 0, 0, 0))
    tile2.paste(big2, (0, 0), mask2)
    tile2 = tile2.resize((inner2, inner2), Image.LANCZOS)
    c2 = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    c2.alpha_composite(tile2, ((1024 - inner2) // 2, (1024 - inner2) // 2))
    c2.save(os.path.join(OUT, 'icon.png'))


def distribute():
    import json
    sq = Image.open(os.path.join(OUT, 'icon_square.png')).convert('RGB')
    rd = Image.open(os.path.join(OUT, 'icon.png')).convert('RGBA')
    mac = Image.open(os.path.join(OUT, 'icon_macos.png')).convert('RGBA')
    rs = lambda im, n: im.resize((n, n), Image.LANCZOS)
    master = os.path.join(APP, 'assets', 'icon', 'icon.png')
    os.makedirs(os.path.dirname(master), exist_ok=True)
    if not os.path.exists(master):
        rd.save(master, optimize=True)
    d = os.path.join(APP, 'ios/Runner/Assets.xcassets/AppIcon.appiconset')
    for i in json.load(open(os.path.join(d, 'Contents.json')))['images']:
        n = int(round(float(i['size'].split('x')[0]) * int(i['scale'][0])))
        rs(sq, n).save(os.path.join(d, i['filename']), optimize=True)  # opaque RGB
    d = os.path.join(APP, 'macos/Runner/Assets.xcassets/AppIcon.appiconset')
    for n in (16, 32, 64, 128, 256, 512, 1024):
        rs(mac, n).save(os.path.join(d, 'app_icon_%d.png' % n), optimize=True)
    rd.save(os.path.join(APP, 'windows/runner/resources/app_icon.ico'), format='ICO',
            sizes=[(n, n) for n in (16, 20, 24, 32, 40, 48, 64, 128, 256)])
    rs(rd, 512).save(os.path.join(APP, 'linux/packaging/app.melsi.png'), optimize=True)
    for n in (16, 24, 32, 48, 64, 128, 256, 512):
        p = os.path.join(APP, 'linux/packaging/icons/hicolor/%dx%d/apps' % (n, n))
        os.makedirs(p, exist_ok=True)
        rs(rd, n).save(os.path.join(p, 'app.melsi.png'), optimize=True)


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    main()
    distribute()
