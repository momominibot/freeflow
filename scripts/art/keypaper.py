"""tools/art/keypaper.py: take the plain paper backdrop out of a watercolour picture (the food guide cards, 30 Oct 2026:
Jamie did not want the white squares on the lilac cards).

The paper colour is the median of the border. A pixel is backdrop only if it is close to that colour AND joined to the
border, so a white egg or a pale cup inside its pencil outline stays. Alpha ramps softly with the distance from the
paper colour (d0 fully clear, d1 fully kept; only pixels under t that touch the border are backdrop), and part-clear pixels are un-mixed from the paper so a pale wash does not
leave a cream halo on a coloured card. The result is cropped to the picture, padded and scaled into a square.

Usage: keypaper.py SRC.png OUT.webp [SRC OUT ...] [--size 320] [--d0 8] [--d1 48]"""
import sys
import numpy as np
from PIL import Image
from scipy import ndimage


def key(src, size=320, pad=0.92, d0=8.0, d1=48.0, t=34.0):
    im = np.asarray(Image.open(src).convert('RGB')).astype(np.float32)
    border = np.concatenate([im[:6].reshape(-1, 3), im[-6:].reshape(-1, 3), im[:, :6].reshape(-1, 3), im[:, -6:].reshape(-1, 3)])
    paper = np.median(border, axis=0)
    d = np.sqrt(((ndimage.gaussian_filter(im, (1.6, 1.6, 0)) - paper) ** 2).sum(-1))  # blurred, so paper grain is not read as picture
    bl = ndimage.gaussian_filter(im, (1.6, 1.6, 0)) / 255; mx, mn = bl.max(-1), bl.min(-1); sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    ps = (paper.max() - paper.min()) / max(paper.max(), 1e-6)
    near = (d < t) & (sat < ps + 0.05)  # a pale pink blanket is close to the paper in distance but not in colour, so it stays; joined-to-border backdrop: kept tight so a faint pencil line still walls in a white bowl
    lab, _ = ndimage.label(near)
    edge = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
    bg = np.isin(lab, list(edge))
    a = np.where(bg, np.clip((d - d0) / (d1 - d0), 0, 1), 1.0)
    a[a < 0.04] = 0
    sol, n = ndimage.label(a > 0.25)  # stray specks of grain or wash away from the picture go
    if n:
        sz = ndimage.sum(np.ones_like(a), sol, range(1, n + 1)); big = [i + 1 for i, z in enumerate(sz) if z >= 0.01 * sz.max()]
        near_big = ndimage.binary_dilation(np.isin(sol, big), iterations=6)
        a = np.where(near_big, a, 0)
    safe = np.maximum(a, 1e-3)[..., None]
    rgb = np.clip((im - (1 - a[..., None]) * paper) / safe, 0, 255)
    rgb = np.where(a[..., None] > 0.995, im, rgb)
    out = Image.fromarray(np.dstack([rgb, a * 255]).astype(np.uint8), 'RGBA')
    box = Image.fromarray((a > 0.06).astype(np.uint8) * 255).getbbox()
    out = out.crop(box)
    w, h = out.size; sc = size * pad / max(w, h)
    out = out.resize((max(1, round(w * sc)), max(1, round(h * sc))), Image.LANCZOS)
    c = Image.new('RGBA', (size, size), (0, 0, 0, 0)); c.paste(out, ((size - out.width) // 2, (size - out.height) // 2))
    return c


if __name__ == '__main__':
    opts = {'--size': 320, '--d0': 8.0, '--d1': 48.0}
    args, i = [], 1
    while i < len(sys.argv):
        if sys.argv[i] in opts: opts[sys.argv[i]] = type(opts[sys.argv[i]])(sys.argv[i + 1]); i += 2
        else: args.append(sys.argv[i]); i += 1
    for s, o in zip(args[::2], args[1::2]):
        key(s, size=opts['--size'], d0=opts['--d0'], d1=opts['--d1']).save(o, 'WEBP', quality=90, method=6)
        print(o)
