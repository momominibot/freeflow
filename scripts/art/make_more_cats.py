#!/usr/bin/env python3
"""scripts/art/make_more_cats.py: the six cats, and the ONE command that regenerates all their pictures (10 Nov 2026).

Cats, in app order: cream, ginger, black (Rhythme's own), then three made here by recolouring Rhythme's pictures
(no image generation, every pixel is a deterministic colour transform of a Rhythme painting):
    smoky  a blue-grey tabby, from the ginger cat
    snowy  a white cat with soft cool-grey shading, from the cream cat
    cocoa  a milk-chocolate brown tabby with darker stripes, from the ginger cat
The recolour touches the fur only. It is hue-selective (orange and cream fur, in HSV and Lab), and what is not fur is
protected: the pink or peach cheek blush, the eyes (iris and pupil), the lilac collar, bandana and flower, the gold bell,
the nose, the inner ears and the paw pads. Lab lightness is kept, so every stripe and every soft shadow survives.

Every cat has three poses, written to assets/art/cats (Dreamy) and assets/art/sunset (Sunset, lilac turned to coral by
make_sunset_art.warm, which is told to leave the recoloured fur alone):
    walk-<cat>.webp          strip of 8 equal cells, cell width incl. PAD = strip width / 8   (make_walk_art.py)
    runner-<cat>.webp        sitting picture                                                  (make_runner_art.py)
    runner-sleep-<cat>.webp  lying, sleeping picture                                          (make_runner_art.py)
All 36 files share one size rule (scripts/art/cat_fit.py): every cat is scaled to the same visual mass as the ginger cat
was drawn before this change, and set into a fixed canvas per pose, feet on the bottom row, so the six cats look the same
size and stand on the same line.

The Rhythme folder is read from $RHYTHME_DREAM (see make_cat_art.py).
Regenerate everything:   RHYTHME_DREAM=<rhythme>/assets/room/dream python3 scripts/art/make_more_cats.py [--preview-dir DIR]
(= make_walk_art.py + make_runner_art.py, each also runnable alone; needs Pillow with WebP and numpy)."""
import functools, os, sys
import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_cat_art import SRC, load                  # noqa: E402

CATS = ["cream", "ginger", "black", "smoky", "snowy", "cocoa"]
BASE = {"cream": "cream", "ginger": "ginger", "black": "black", "smoky": "ginger", "snowy": "cream", "cocoa": "ginger"}
WALK = {"cream": "pet-walk-cat-side", "ginger": "pet-walk-catginger-side", "black": "pet-walk-catblack-side"}
SIT = {"cream": "prop-cat--bandana", "ginger": "prop-cat-ginger--bandana", "black": "prop-cat-black--bandana"}
SLEEP = {"cream": "pet-sleep-cat", "ginger": "pet-sleep-catginger", "black": "pet-sleep-catblack"}
FRAMES = 8


# ---------------------------------------------------------------- colour maths (numpy, float, sRGB in 0..1)
def rgb_to_hsv(rgb):
    mx, mn = rgb.max(-1), rgb.min(-1)
    d = mx - mn
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    safe = np.where(d > 1e-6, d, 1.0)
    h = np.where(mx == r, ((g - b) / safe) % 6, np.where(mx == g, (b - r) / safe + 2, (r - g) / safe + 4))
    h = np.where(d > 1e-6, h * 60.0, 0.0)
    s = np.where(mx > 1e-6, d / np.where(mx > 1e-6, mx, 1.0), 0.0)
    return h, s, mx


_M = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
_WHITE = np.array([0.95047, 1.0, 1.08883])


def rgb_to_lab(rgb):
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    t = (lin @ _M.T) / _WHITE
    f = np.where(t > 216 / 24389, np.cbrt(t), (24389 / 27 * t + 16) / 116)
    return 116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])


def lab_to_rgb(L, a, b):
    fy = (L + 16) / 116
    f = np.stack([fy + a / 500, fy, fy - b / 200], -1)
    t = np.where(f ** 3 > 216 / 24389, f ** 3, (116 * f - 16) / (24389 / 27))
    lin = (t * _WHITE) @ np.linalg.inv(_M).T
    lin = np.clip(lin, 0, 1)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055)


def smooth(x, lo, hi):
    """0 below lo, 1 above hi, smooth in between (works with lo > hi for a falling edge)"""
    t = np.clip((x - lo) / (hi - lo), 0, 1)
    return t * t * (3 - 2 * t)


def blur(mask, radius):
    """Gaussian blur of a 0..1 float mask (through 8-bit, which is plenty for a mask)"""
    im = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(float(radius)))
    return np.asarray(im, np.float32) / 255.0


def grow(mask, radius):
    """a 0/1 mask grown by `radius` pixels (a square growth, by repeated 3 x 3 maxima)"""
    im = Image.fromarray((np.asarray(mask) > 0).astype(np.uint8) * 255, "L")
    for _ in range(int(round(radius))):
        im = im.filter(ImageFilter.MaxFilter(3))
    return (np.asarray(im) > 0).astype(np.float32)


def components(mask, min_area):
    """connected blobs (8-neighbour) of a boolean mask with at least min_area pixels, as lists of (y, x) arrays"""
    h, w = mask.shape
    todo = set(map(tuple, np.argwhere(mask)))
    blobs = []
    while todo:
        seed = todo.pop(); stack = [seed]; pts = [seed]
        while stack:
            y, x = stack.pop()
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    p = (y + dy, x + dx)
                    if p in todo:
                        todo.discard(p); stack.append(p); pts.append(p)
        if len(pts) >= min_area:
            blobs.append(np.array(pts))
    return blobs


# ---------------------------------------------------------------- what is NOT fur
# Where the bell is when the gold detector below cannot find it (pose: x, y as a fraction of the picture, radius as a fraction of its width)
BELL_FALLBACK = {("ginger", "sleep"): (0.456, 0.770, 0.055), ("cream", "sleep"): (0.554, 0.683, 0.050)}


def bell_zone(rgb, a, h, s, v, base, pose):
    """0..1 map of the gold bell on the collar. Ginger: the rich gold core (a compact blob close to the lilac collar or bandana; the
    olive chin shading above the collar is too pale and too stretched to pass), grown to the whole bell. Cream: the core must sit
    inside the lilac flower (the brown shadows under the paws are rich gold too), and only the walk is found that way; the
    sleeping cream cat's bell is at a fixed place (BELL_FALLBACK)."""
    op = a > 200
    lilac = (op & (h > 245) & (h < 345) & (s > 0.1) & (v > 0.35)).astype(np.float32)
    near = grow(lilac, 36) > 0
    core = (h > 34) & (h < 54) & (s > (0.72 if base == "ginger" else 0.55)) & (v > 0.4) & near
    zone = np.zeros(a.shape, np.float32)
    height = float(np.ptp(np.nonzero(op)[0]) + 1)
    if base == "ginger" or pose == "walk":
        for pts in components(core, 25):
            blob = np.zeros(a.shape, np.float32)
            blob[pts[:, 0], pts[:, 1]] = 1
            ring = (grow(blob, 10) > 0) & (blob == 0)
            if base == "ginger" or lilac[ring].mean() > 0.15:
                zone = np.maximum(zone, blob)
        zone = grow(zone, 0.045 * height)
    if (base, pose) in BELL_FALLBACK:
        fx, fy, fr = BELL_FALLBACK[(base, pose)]
        yy, xx = np.mgrid[0: a.shape[0], 0: a.shape[1]]
        zone = np.maximum(zone, (np.hypot(xx - fx * a.shape[1], yy - fy * a.shape[0]) < fr * a.shape[1]).astype(np.float32))
    gold = ((h > 34) & (h < 62) & (s > 0.4) & (v > 0.4)).astype(np.float32)
    dark = (v < 0.5).astype(np.float32)                         # the slit and the rim of the bell
    return zone * np.maximum(gold, dark)


def eye_zone(a, h, s, v):
    """0..1 map of the iris and its dark rim: found from the pupil (a dark blob in the head), amber and dark pixels around it"""
    op = a > 200
    ys, xs = np.nonzero(op)
    top, bottom = ys.min(), ys.max()
    dark = op & (v < 0.3)
    dark[: top, :] = False
    dark[int(top + 0.9 * (bottom - top)):, :] = False          # shadows between the toes are not eyes
    pupil = np.zeros(a.shape, np.float32)
    for pts in components(dark, 90):
        pupil[pts[:, 0], pts[:, 1]] = 1
    zone = grow(pupil, 15)
    return zone * (((s > 0.55) & (h > 12) & (h < 70)) | (v < 0.5)).astype(np.float32)


# ---------------------------------------------------------------- the three recolours
# fraction of the picture (x0, y0, x1, y1) where the cheek blush lives; elsewhere peach is a patch of fur and goes white
HEAD = {"walk": (0.5, 0, 1, 0.55), "sit": (0, 0, 0.75, 0.55), "sleep": (0, 0, 0.5, 0.75)}


def _fur_weight(h, s, v, hue_lo=10.0, hue_hi=140.0, sat_lo=0.05):
    return smooth(h, hue_lo, hue_lo + 22) * smooth(h, hue_hi, hue_hi - 15) * smooth(s, sat_lo, sat_lo + 0.1) * smooth(v, 0.28, 0.42)


def recolour(im, kind, pose="walk"):
    """RGBA picture of the ginger cat (smoky, cocoa) or the cream cat (snowy) -> (recoloured RGBA, weight 0..1).
    The weight is how much of each pixel was repainted; make_sunset_art.warm uses it to leave the new fur colour alone."""
    rgba = np.array(im.convert("RGBA"))
    rgb = rgba[..., :3].astype(np.float32) / 255.0
    a = rgba[..., 3]
    h, s, v = rgb_to_hsv(rgb)
    L, A, B = rgb_to_lab(rgb)
    base = "ginger" if kind in ("smoky", "cocoa") else "cream"
    bell = bell_zone(rgb, a, h, s, v, base, pose)
    if base == "ginger":
        keep = np.maximum(eye_zone(a, h, s, v), bell)
        w = _fur_weight(h, s, v) * (1 - blur(keep, 1.2))
        stripe = smooth(s, 0.42, 0.68)                      # the rich orange of the stripes
        if kind == "smoky":
            L2 = 0.86 * L - 2.0 - 15.0 * stripe             # cooler, a little darker, stripes pull dark
            chroma = 7.0 * (1 - smooth(L2, 62, 92) * 0.6)   # a hint of blue, less in the highlights
            A2, B2 = np.full_like(L, -1.2), -chroma
        else:
            L2 = 0.68 * L - 2.0 - 11.0 * stripe
            ang = np.arctan2(B, A)
            ang = np.radians(60) + np.minimum(ang - np.radians(60), 0) + 0.15 * np.maximum(ang - np.radians(60), 0)   # no olive: green shading goes brown
            ang = ang - np.radians(5)                       # a touch redder: chocolate, not caramel
            c = np.hypot(A, B) * 0.68
            A2, B2 = c * np.cos(ang), c * np.sin(ang)
    else:
        hh, ww = a.shape
        x0, y0, x1, y1 = HEAD[pose]
        box = np.zeros(a.shape, bool)
        box[int(y0 * hh): int(y1 * hh), int(x0 * ww): int(x1 * ww)] = True
        blush = ((h < 24) & (h > 6) & (s > 0.3) & (v > 0.86) & box).astype(np.float32)
        keep = smooth(blur(blush, 7), 0.12, 0.30)           # the cheek blush is a dense blob; body patches are lighter and elsewhere
        w = _fur_weight(h, s, v, 8.0, 140.0, 0.03) * (1 - blur(bell, 1.2))
        w = w * (1 - keep) + 0.4 * keep                     # the blush stays, a little softer on white
        shade = np.clip((96 - L) / 40, 0, 1)
        L2 = 98 - (98 - L) * 0.62
        A2, B2 = np.full_like(L, -0.8), -3.4 * shade ** 0.8 - 0.4
    w = blur(np.clip(w, 0, 1), 1.0) * (a > 0)               # a soft weight, so the new fur has no speckle where hues cross a threshold
    new = lab_to_rgb(L2, A2, B2)
    out = rgb * (1 - w[..., None]) + new * w[..., None]
    out = (np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(np.dstack([out, a]), "RGBA"), w


# ---------------------------------------------------------------- sources (full size, recoloured where needed)
@functools.lru_cache(maxsize=None)
def walk_frames(who):
    """the eight full-size frames of a cat's side-view walk cycle: [(RGBA, fur weight or None)] (cats face right)"""
    strip = Image.open(os.path.join(SRC, WALK[BASE[who]] + ".webp")).convert("RGBA")
    w = strip.width // FRAMES
    frames = [strip.crop((i * w, 0, (i + 1) * w, strip.height)) for i in range(FRAMES)]
    return [recolour(f, who, "walk") if who != BASE[who] else (f, None) for f in frames]


@functools.lru_cache(maxsize=None)
def sit_picture(who):
    im = load(SIT[BASE[who]])
    return recolour(im, who, "sit") if who != BASE[who] else (im, None)


@functools.lru_cache(maxsize=None)
def sleep_picture(who):
    im = load(SLEEP[BASE[who]])
    return recolour(im, who, "sleep") if who != BASE[who] else (im, None)


def ruler(folder, path):
    """a preview sheet: the six cats in a row for walk frame 0, walk frame 3, sit and sleep, at the size the app draws them
    (walk 150 px = 44 pt, sit 200 px = 38 pt, sleep 300 px = 64 pt) times 3, each row on a red baseline: every cat should stand on
    the line and look the same size"""
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "art", folder)
    paper = (253, 247, 236) if folder == "cats" else (252, 245, 228)
    rows = []
    for label, name, k in (("walk 0", "walk-{}.webp", 44 / 150 * 3), ("walk 3", "walk-{}.webp", 44 / 150 * 3),
                           ("sit", "runner-{}.webp", 38 / 200 * 3), ("sleep", "runner-sleep-{}.webp", 64 / 300 * 3)):
        pics = []
        for who in CATS:
            im = Image.open(os.path.join(root, name.format(who))).convert("RGBA")
            if label.startswith("walk"):
                cell = im.width // FRAMES
                i = int(label[-1])
                im = im.crop((i * cell, 0, (i + 1) * cell, im.height))
            pics.append(im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS))
        rows.append(pics)
    gap, top = 24, 28
    width = max(sum(p.width for p in r) + gap * (len(r) + 1) for r in rows)
    sheet = Image.new("RGBA", (width, sum(max(p.height for p in r) + top + 14 for r in rows)), paper + (255,))
    from PIL import ImageDraw
    draw = ImageDraw.Draw(sheet)
    y = 0
    for pics in rows:
        h = max(p.height for p in pics)
        x = gap
        for who, p in zip(CATS, pics):
            sheet.alpha_composite(p, (x, y + top + h - p.height))
            draw.text((x, y + 6), who, fill=(90, 80, 70, 255))
            x += p.width + gap
        draw.rectangle((0, y + top + h, width, y + top + h + 1), fill=(230, 30, 30, 255))
        y += top + h + 14
    sheet.convert("RGB").save(path)


def main():
    import make_walk_art, make_runner_art
    make_walk_art.main()
    make_runner_art.main()
    if "--preview-dir" in sys.argv:
        out = sys.argv[sys.argv.index("--preview-dir") + 1]
        os.makedirs(out, exist_ok=True)
        for folder in ("cats", "sunset"):
            ruler(folder, os.path.join(out, f"ruler-{folder}.png"))


if __name__ == "__main__":
    main()
