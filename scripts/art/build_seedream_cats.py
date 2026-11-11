"""build_seedream_cats.py: the no-provider half of make_seedream_cats.py (10 Nov 2026). Cuts the Seedream sheets out of the magenta,
sets every pose of a cat at ONE scale, writes the canvases, the sunset colourway, portraits, contact sheet and walk GIFs.
The walk is NOT a Seedream grid (its frames did not move): it is the lineup's standing cat with a toy toddle (toddle()).
Pure Pillow + numpy; it never calls a model."""
import os, shutil
import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

from make_sunset_art import warm

CATS = ["cream", "ginger", "black", "smoky", "snowy", "cocoa"]
SEEN, SOLID = 24, 96
WALK_H = 138                 # the median walking cat stands this tall in its cell (the toddle needs headroom in 155)
CELL_H, PAD = 155, 3        # the cell width is worked out: the chubby cats are about as wide as tall, so the cell is wider than the old 121
LILAC = (243, 238, 252)
K = np.array([255.0, 0.0, 255.0])


def key_magenta(path):
    """RGB sheet on flat magenta -> RGBA. Alpha ramps with the distance from magenta; the rim is un-mixed from magenta."""
    im = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    d = np.sqrt(((im - K) ** 2).sum(-1))
    a = np.clip((d - 70.0) / 90.0, 0, 1)
    # a pure-magenta pixel has G near 0 while R and B are high: that is also "magenta-ness" for dark-edged pixels
    mag = np.clip((np.minimum(im[..., 0], im[..., 2]) - im[..., 1] - 40.0) / 90.0, 0, 1)
    a = np.minimum(a, 1 - 0.0 * mag) if False else a
    safe = np.maximum(a, 1e-3)[..., None]
    rgb = np.clip((im - (1 - a[..., None]) * K) / safe, 0, 255)
    rgb = np.where(a[..., None] > 0.98, im, rgb)
    out = np.dstack([rgb, a * 255]).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def clean_fringe(im):
    """remove leftover magenta tint on the soft rim: where the pixel is pinker than the fur just inside it, pull it to that fur"""
    rgba = np.array(im)
    a = rgba[..., 3].astype(np.float32)
    solid = a > 235
    inner = ndimage.binary_erosion(solid, iterations=3)
    if inner.sum() == 0:
        return im
    rgb = rgba[..., :3].astype(np.float32)
    # nearest inner pixel colour for every rim pixel
    idx = ndimage.distance_transform_edt(~inner, return_distances=False, return_indices=True)
    near = rgb[idx[0], idx[1]]
    rim = (a > 0) & ~inner
    tint = np.clip((np.minimum(rgb[..., 0], rgb[..., 2]) - rgb[..., 1] - 25.0) / 80.0, 0, 1)      # magenta-ness
    ntint = np.clip((np.minimum(near[..., 0], near[..., 2]) - near[..., 1] - 25.0) / 80.0, 0, 1)
    w = np.clip(tint - ntint, 0, 1)[..., None] * rim[..., None]
    w = np.maximum(w, 0.35 * rim[..., None] * (~ndimage.binary_erosion(solid, iterations=1))[..., None])   # outermost ring leans to the inside colour
    rgb = rgb * (1 - w) + near * w
    # alpha edge: a 1 px soft erosion removes the last pink hair
    al = Image.fromarray(rgba[..., 3], "L").filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.6))
    rgba[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    rgba[..., 3] = np.asarray(al)
    return Image.fromarray(rgba, "RGBA")


def components(im, n, merge=14):
    """the n biggest separate cats in a keyed sheet, each as its own RGBA image (full sheet size) and its centroid"""
    a = np.asarray(im.getchannel("A")) > 128
    lab, cnt = ndimage.label(ndimage.binary_dilation(a, iterations=merge))
    sizes = ndimage.sum(a, lab, range(1, cnt + 1))
    keep = list(np.argsort(sizes)[::-1][:n] + 1)
    outs = []
    for l in keep:
        region = ndimage.binary_dilation(lab == l, iterations=2)
        arr = np.array(im)
        arr[..., 3] = np.where(region, arr[..., 3], 0)
        ys, xs = np.nonzero(arr[..., 3] > SEEN)
        outs.append((Image.fromarray(arr, "RGBA"), xs.mean(), ys.mean()))
    return outs


def seen_box(im):
    a = np.asarray(im.getchannel("A"))
    ys, xs = np.nonzero(a > SEEN)
    rows = np.nonzero((a > SOLID).any(1))[0]
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(rows.max()) + 1


def tight(im):
    return im.crop(seen_box(im))


def rs(im, s):
    return im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)


def lineup_poses(cid, work):
    im = clean_fringe(key_magenta(os.path.join(work, "gen", f"lineup-{cid}.png")))
    comps = sorted(components(im, 3), key=lambda c: c[1])
    stand, sit, sleep = [tight(c[0]) for c in comps]
    return stand, sit, sleep.transpose(Image.FLIP_LEFT_RIGHT)   # the sheet sleeps head right; the app's sleepers have the head on the left


def place_bottom(im, w, h, cx=None):
    """into a (w, h) canvas: centred across (or on cx), lowest solid row on the last row"""
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    x = (w - im.width) // 2 if cx is None else int(round(cx - im.width / 2))
    canvas.alpha_composite(im, (x, h - im.height))
    return canvas


def ground(im):
    a = np.asarray(im.getchannel("A"))
    return im.crop((0, 0, im.width, int(np.nonzero((a > SOLID).any(1))[0].max()) + 1))


def centroid_x(im):
    a = np.asarray(im.getchannel("A")).astype(np.float32)
    return float((a.sum(0) * np.arange(im.width)).sum() / max(a.sum(), 1))




# ---------------------------------------------------------------- head measurement (to hold one scale across poses and cats)
# Sit: automatic. The head is the part above the neck, and the neck is the narrowest row of the sitting silhouette below the widest
# part of the head. Stand and sleep (a profile and a curled head have no such waist): read once by eye off a ruler overlay of the
# lineup cut-outs, in lineup pixels (ear tip to the collar for the stander; the vertical extent of the head for the sleeper).
# A cat without marks is simply built at its lineup scale (the three poses came from one sheet, drawn at one scale) and prints n/a.
HEAD_MARKS = {"cream": (250, 255), "smoky": (218, 245), "cocoa": (230, 245)}      # (stand, sleep)
SLEEP_K = 1.0     # measured sleep/sit head ratio is 0.92 to 1.03 (median 0.94): inside the tolerance, so no 1.10 lift


def head_height_sit(im):
    a = np.asarray(im.getchannel("A")) > 128
    k = np.convolve(a.sum(1).astype(float), np.ones(9) / 9, "same")
    H = len(k)
    hmax = int(np.argmax(k[: int(0.6 * H)]))
    lo, hi = hmax + int(0.1 * H), int(0.8 * H)
    return float(lo + int(np.argmin(k[lo:hi])))


# ---------------------------------------------------------------- the toddle
def toddle(stand, scale, n=8, bob=0.04, rock=3.0, squash=0.03):
    """n frames of the standing cat (scaled) with a toy-like toddle: two hops per cycle (a vertical lift of `bob` of its height, feet on the
    floor line at the low point), a rock of +-`rock` degrees around the feet, a squash of `squash` at the low point. Resampled bicubic in
    premultiplied alpha, so the rim never goes dark. Returns the frames (each its own size), the lift in px for each frame and the pivot x."""
    base = rs(stand, scale)
    ground_im = ground(base)
    H, W = ground_im.height, ground_im.width
    A = bob * H
    m = int(0.25 * max(W, H)) + 4
    out = []
    for i in range(n):
        ph = 2 * np.pi * i / n
        lift = A * (1 - np.cos(2 * ph)) / 2                    # 0 at i = 0 and 4 (feet down), A at i = 2 and 6
        low = 1 - lift / A                                      # 1 at the low point
        sy, sx = 1 - squash * low, 1 + 0.5 * squash * low
        pm = ground_im.convert("RGBa")
        pm = pm.resize((max(1, round(W * sx)), max(1, round(H * sy))), Image.BICUBIC)
        canvas = Image.new("RGBa", (pm.width + 2 * m, pm.height + 2 * m), (0, 0, 0, 0))
        canvas.paste(pm, (m, m))
        pivot = (m + pm.width / 2, m + pm.height - 1)           # the feet, centre of the body
        canvas = canvas.rotate(-rock * np.sin(ph), resample=Image.BICUBIC, center=pivot)
        fr = canvas.convert("RGBA")
        a = np.asarray(fr.getchannel("A"))
        ys, xs = np.nonzero(a > SEEN)
        rows = np.nonzero((a > SOLID).any(1))[0]
        # keep the pivot x fixed, the lowest solid row at the floor
        out.append((fr, float(pivot[0]), int(rows.max()) + 1, float(lift)))
    return out


def toddle_frames(frames, cw, ch):
    """(RGBA cell images, half-width needed from the pivot, top-most opaque row) from toddle() output: pivot at the cell centre,
    lowest foot on the last row minus the lift"""
    cells, half, top = [], 0.0, 10 ** 6
    for fr, px, bottom, lift in frames:
        cell = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
        x = int(round(cw / 2 - px))
        y = int(round(ch - bottom - lift))
        big = Image.new("RGBA", (cw + 2 * fr.width, ch + 2 * fr.height), (0, 0, 0, 0))        # room so nothing is cut while measuring
        big.alpha_composite(fr, (fr.width + x, fr.height + y))
        a = np.asarray(big.getchannel("A"))
        ys, xs = np.nonzero(a > SEEN)
        half = max(half, cw / 2 - (xs.min() - fr.width), (xs.max() + 1 - fr.width) - cw / 2)
        top = min(top, ys.min() - fr.height)
        cells.append(big.crop((fr.width, fr.height, fr.width + cw, fr.height + ch)))
    return cells, half, top


def graded(im, cid, sunset):
    if not sunset:
        return im
    arr = np.array(im.convert("RGBA"))
    hsv = np.array(Image.fromarray(arr[..., :3], "RGB").convert("HSV"), np.float32)
    keep = None
    if cid in ("smoky", "snowy", "black"):
        # fur and blue eyes (hue under 250) are protected from the lilac-to-coral turn: only the truly lilac collar turns coral
        hue = hsv[..., 0] * 360 / 255
        keep = np.clip((250 - hue) / 10, 0, 1).astype(np.float32)
        keep = np.asarray(Image.fromarray((keep * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(0.8)), np.float32) / 255.0
    return warm(im, lively=True, keep=keep)


def present(work):
    have = [c for c in CATS if os.path.exists(os.path.join(work, "gen", f"lineup-{c}.png"))]
    for c in CATS:
        if c not in have:
            print(f"note: no lineup for {c}, skipped")
    return have


def run(work, root, install=False):
    cats_ids = present(work)
    out = os.path.join(work, "out")
    shutil.rmtree(out, ignore_errors=True)
    for f in ("cats", "sunset"):
        os.makedirs(os.path.join(out, f))
    if install and len(cats_ids) < len(CATS):
        raise SystemExit("refusing to install: not all six cats exist")
    poses = {c: lineup_poses(c, work) for c in cats_ids}
    # --- one scale: the same head height for every cat (measured on the sitting pose), then check the other poses
    hh = {c: dict(sit=head_height_sit(p[1]), stand=(HEAD_MARKS.get(c, (None, None))[0]), sleep=(HEAD_MARKS.get(c, (None, None))[1])) for c, p in poses.items()}
    g0 = WALK_H / float(np.median([p[0].height for p in poses.values()]))
    head_t = g0 * float(np.median([h["sit"] for h in hh.values()]))              # target head height in px, same for all cats
    gs = {c: head_t / hh[c]["sit"] for c in cats_ids}
    global CELL_W
    for _ in range(40):                                                          # shrink everything until every toddle frame fits the cell height
        tops = [toddle_frames(toddle(poses[c][0], gs[c]), 400, CELL_H)[2] for c in cats_ids]
        if min(tops) >= 1:
            break
        gs = {c: v * 0.98 for c, v in gs.items()}
    half = max(toddle_frames(toddle(poses[c][0], gs[c]), 400, CELL_H)[1] for c in cats_ids)
    CELL_W = int(2 * np.ceil(half) + 2 * PAD)
    print("head heights in px at the final scale  (stand / sit / sleep), sit measured, stand and sleep read off the lineup:")
    for c in cats_ids:
        g, h = gs[c], hh[c]
        f = lambda v, k=1.0: "   n/a" if v is None else f"{v * g * k:6.1f}"
        print(f"  {c:6s} {f(h['stand'])} {h['sit'] * g:6.1f} {f(h['sleep'], SLEEP_K)}   scale {g:.3f}   head sit {h['sit'] * g:.1f} (target {head_t:.1f})")
    SIDE = 3
    sit_s = {c: ground(rs(poses[c][1], gs[c])) for c in cats_ids}
    sleep_s = {c: ground(rs(poses[c][2], gs[c] * SLEEP_K)) for c in cats_ids}
    sit_w, sit_h = max(p.width for p in sit_s.values()) + 2 * SIDE, max(p.height for p in sit_s.values())
    sl_w, sl_h = max(p.width for p in sleep_s.values()) + 2 * SIDE, max(p.height for p in sleep_s.values())
    pk = 400.0 / max(poses[c][1].height * gs[c] for c in cats_ids)
    por = {c: ground(rs(poses[c][1], gs[c] * pk)) for c in cats_ids}
    por_w, por_h = max(p.width for p in por.values()) + 8, max(p.height for p in por.values())
    for sunset, folder in ((False, "cats"), (True, "sunset")):
        for c in cats_ids:
            cells, _, _ = toddle_frames(toddle(poses[c][0], gs[c]), CELL_W, CELL_H)
            strip = Image.new("RGBA", (CELL_W * 8, CELL_H), (0, 0, 0, 0))
            for i, cell in enumerate(cells):
                strip.alpha_composite(graded(cell, c, sunset), (i * CELL_W, 0))
            strip.save(os.path.join(out, folder, f"walk-{c}.webp"), "WEBP", quality=90, method=6)
            place_bottom(graded(sit_s[c], c, sunset), sit_w, sit_h).save(os.path.join(out, folder, f"runner-{c}.webp"), "WEBP", quality=92, method=6)
            place_bottom(graded(sleep_s[c], c, sunset), sl_w, sl_h).save(os.path.join(out, folder, f"runner-sleep-{c}.webp"), "WEBP", quality=92, method=6)
            place_bottom(graded(por[c], c, sunset), por_w, por_h).save(os.path.join(out, folder, f"portrait-{c}.webp"), "WEBP", quality=92, method=6)
    print("walker heights (stand, before the toddle):", {c: round(poses[c][0].height * gs[c]) for c in cats_ids})
    print("canvas sizes:", dict(walk=(CELL_W * 8, CELL_H), cell=(CELL_W, CELL_H), sit=(sit_w, sit_h), sleep=(sl_w, sl_h), portrait=(por_w, por_h)),
          "(sit/sleep/portrait canvases are the largest of the cats built so far: they grow when the other lineups exist)")
    contact(out, work, cats_ids)
    gifs(out, work, cats_ids)
    if install:
        for folder in ("cats", "sunset"):
            for f in os.listdir(os.path.join(out, folder)):
                shutil.copy2(os.path.join(out, folder, f), os.path.join(root, "assets", "art", folder, f))
        print("installed")


def on_bg(im, bg=LILAC):
    b = Image.new("RGBA", im.size, bg + (255,))
    b.alpha_composite(im.convert("RGBA"))
    return b.convert("RGB")


def contact(out, work, cats_ids):
    sheets = []
    for bg in (LILAC, (38, 34, 48)):
        rows = []
        for c in cats_ids:
            ims = [Image.open(os.path.join(out, "cats", f"{n}-{c}.webp")).convert("RGBA") for n in ("walk", "runner", "runner-sleep")]
            h = max(i.height for i in ims)
            row = Image.new("RGBA", (sum(i.width for i in ims) + 30, h + 10), bg + (255,))
            x = 0
            for im in ims:
                row.alpha_composite(im, (x, h + 5 - im.height)); x += im.width + 15
            rows.append(row.convert("RGB"))
        sheet = Image.new("RGB", (max(r.width for r in rows), sum(r.height for r in rows)), bg)
        y = 0
        for r in rows:
            sheet.paste(r, (0, y)); y += r.height
        sheets.append(sheet)
    both = Image.new("RGB", (sheets[0].width, sum(s.height for s in sheets)), LILAC)
    both.paste(sheets[0], (0, 0)); both.paste(sheets[1], (0, sheets[0].height))
    both.save(os.path.join(work, "contact.jpg"), quality=92)


def gifs(out, work, cats_ids):
    """8 frames in about 0.85 s (the app's walk speed), on the lilac, 3x for review"""
    for c in cats_ids:
        strip = Image.open(os.path.join(out, "cats", f"walk-{c}.webp")).convert("RGBA")
        fr = [on_bg(strip.crop((i * CELL_W, 0, (i + 1) * CELL_W, CELL_H)).resize((CELL_W * 3, CELL_H * 3), Image.LANCZOS)) for i in range(8)]
        fr[0].save(os.path.join(work, f"walk-{c}.gif"), save_all=True, append_images=fr[1:], duration=[110] * 4 + [100] * 4, loop=0)
