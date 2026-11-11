#!/usr/bin/env python3
"""scripts/art/cat_fit.py: one size rule for every cat picture (10 Nov 2026). A helper module, used by make_walk_art.py and
make_runner_art.py (run make_more_cats.py to regenerate everything).

The problem: each Rhythme picture is a different size and shape, and the old pipeline cropped every picture tight and scaled it to
a set height, so how big a cat looked depended on its pose and crop (the cream walker stood taller than the ginger one, the black
sleeper was a different height). The rule now:

  1. Visual mass. A picture is scaled so that sqrt(opaque area) (alpha > 24; for a walk, the median of its eight frames) equals
     the ginger cat's, as it was drawn before this change: REF below, in pixels of the 150 / 200 / 300 px poses, that is points
     at 150 px = 44 pt (walk), 200 px = 38 pt (sit), 300 px = 64 pt wide (sleep).
  2. A fixed canvas per pose, the same for every cat: the biggest any cat needs, nothing clipped. The cat is centred across
     (a walk is centred as one shared box, so the eight strides do not jump about) and stands on the bottom row: the lowest pixel
     with alpha > 96 is on the last row, and everything under it (soft shadow, haze) is cut off.
  3. The rim: the paintings have a one-colour fringe (pale lilac on the black cat, green on the ginger and the black one) where
     the cut-out meets the old background; defringe() repaints it with the colour just inside, and drops the pale haze that
     floats away from the body."""
import numpy as np
from PIL import Image, ImageFilter

REF = {"walk": 96.62, "sit": 144.57, "sleep": 196.66}     # sqrt(opaque area) of the ginger cat as drawn before 10 Nov 2026
SEEN, SOLID = 24, 96                                       # alpha counted as part of the cat / as standing on the line


def _grow(mask, n, shrink=False):
    im = Image.fromarray(mask.astype(np.uint8) * 255, "L")
    f = ImageFilter.MinFilter(3) if shrink else ImageFilter.MaxFilter(3)
    for _ in range(n):
        im = im.filter(f)
    return np.asarray(im) > 0


def defringe(im, band=6):
    """repaint the rim of a cut-out with the colour just inside it, and drop the pale haze away from the body (colour and
    far haze only: the shape of the cat, its ears and its whiskers are untouched)"""
    rgba = np.array(im.convert("RGBA"))
    a = rgba[..., 3].copy()
    mass = _grow(_grow(a > 200, 2, shrink=True), 2)                   # the body, without whiskers and hairs
    a[~_grow(mass, 3) & (a < 64)] = 0                                 # haze
    core = _grow(mass, band, shrink=True)
    inner = Image.fromarray(rgba[..., :3] * core[..., None].astype(np.uint8), "RGB").filter(ImageFilter.GaussianBlur(band * 0.6))
    cover = Image.fromarray(core.astype(np.uint8) * 255, "L").filter(ImageFilter.GaussianBlur(band * 0.6))
    cover = np.asarray(cover, np.float32)[..., None] / 255.0
    inner = np.asarray(inner, np.float32) / np.maximum(cover, 1e-3)
    rim = (_grow(mass, 2) & ~core & (a > 0) & (cover[..., 0] > 0.03))[..., None]
    rgb = np.where(rim, rgba[..., :3] * 0.1 + np.clip(inner, 0, 255) * 0.9, rgba[..., :3])
    rgb = np.clip(rgb + 0.5, 0, 255).astype(np.uint8)
    hsv = np.array(Image.fromarray(rgb, "RGB").convert("HSV"))
    if np.median(hsv[..., 2][core]) < 80:
        # a near-black cat: the dark teal of the painting's contact shadow (under the tail) becomes the cat's own dark violet
        teal = (hsv[..., 0] > 67) & (hsv[..., 0] < 142) & (hsv[..., 2] < 160) & (hsv[..., 1] > 50) & (a > 0)
        a[~_grow(mass, 4) & (a < 160)] = 0                            # and its last wisps of haze, a little further out
        hsv[..., 0] = np.where(teal, 186, hsv[..., 0])
        hsv[..., 1] = np.where(teal, hsv[..., 1] * 0.6, hsv[..., 1])
        rgb = np.array(Image.fromarray(hsv, "HSV").convert("RGB"))
    return Image.fromarray(np.dstack([rgb, a]), "RGBA")


def seen_box(im):
    """(x0, y0, x1, y1) of the cat: alpha > SEEN, but the bottom is the lowest row that is solid (alpha > SOLID)"""
    a = np.asarray(im.getchannel("A"))
    ys, xs = np.nonzero(a > SEEN)
    rows = np.nonzero((a > SOLID).any(1))[0]
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(rows.max()) + 1


def mass(im):
    return float(np.sqrt((np.asarray(im.getchannel("A")) > SEEN).sum()))


def _resize(im, s):
    return im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)


def _ground(im):
    """cut everything under the lowest solid row, so that row is the last"""
    a = np.asarray(im.getchannel("A"))
    return im.crop((0, 0, im.width, int(np.nonzero((a > SOLID).any(1))[0].max()) + 1))


def fit_one(im, pose):
    """one picture (sit or sleep) trimmed, scaled to the ginger cat's visual mass, standing on its last row"""
    im = im.crop(seen_box(im))
    s = REF[pose] / mass(im)
    for _ in range(3):                                   # resampling softens the edge a little: settle on the exact mass
        out = _ground(_resize(im, s))
        s *= REF[pose] / mass(out)
    return _ground(_resize(im, s))


def fit_walk(frames):
    """eight same-size frames -> eight same-size, same-box pictures at the ginger cat's mass, standing on their last row"""
    boxes = [seen_box(f) for f in frames]
    box = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
    crops = [f.crop(box) for f in frames]
    s = REF["walk"] / float(np.median([mass(c) for c in crops]))
    for _ in range(3):
        out = [_resize(c, s) for c in crops]
        s *= REF["walk"] / float(np.median([mass(o) for o in out]))
    out = [_resize(c, s) for c in crops]
    last = max(int(np.nonzero((np.asarray(o.getchannel("A")) > SOLID).any(1))[0].max()) for o in out) + 1
    return [o.crop((0, 0, o.width, last)) for o in out]


def place(im, width, height):
    """into a (width, height) canvas: centred across, standing on the bottom row"""
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    canvas.alpha_composite(im, ((width - im.width) // 2, height - im.height))
    return canvas


def canvas_size(pictures, margin=2):
    """the smallest fixed canvas every picture (or walk, as its first frame) fits in: (width, height)"""
    return max(p.width for p in pictures) + margin, max(p.height for p in pictures)
