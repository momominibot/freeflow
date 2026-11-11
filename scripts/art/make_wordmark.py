#!/usr/bin/env python3
"""scripts/art/make_wordmark.py: the Purrscribe wordmark (10 Nov 2026).

The word "Purrscribe" (capital P, the rest lowercase) in a joined script, the whole word turned TILT_DEGREES counter-clockwise
so the baseline rises to the right. Written as black on transparent, so the apps can tint it as a template image in any colour
(plum in Dreamy, espresso in Sunset, white on the dark floating bar).

Two pictures, both cut from the same artwork, cropped tight with a small even margin:
  assets/brand/wordmark-purrscribe.png         1600 px wide
  assets/brand/wordmark-purrscribe-small.png    480 px wide  (Mac sidebar, iPhone title)

The letters come from SignPainter HouseScript Semibold, an Apple system font on this Mac. It is fine as a picture, but it is not
an open-licence font; swap FONT_PATH for one (Great Vibes, for example) before a public release and rerun this script.

Run from the repo root:  python3 scripts/art/make_wordmark.py       (needs Pillow; the Pillow in the session venv works)"""
import os
from PIL import Image, ImageDraw, ImageFont

TILT_DEGREES = 25                 # counter-clockwise: the baseline rises to the right. Change this one number to retilt.
TEXT = "Purrscribe"
FONT_PATH = "/System/Library/Fonts/Supplemental/SignPainter.ttc"
FONT_INDEX = 1                    # 0 = HouseScript, 1 = HouseScript Semibold
FONT_SIZE = 900                   # drawn big, then scaled down, so the edges come out smooth
MARGIN = 0.03                     # empty border as a share of the picture's width, the same on all four sides
SIZES = {"wordmark-purrscribe.png": 1600, "wordmark-purrscribe-small.png": 480}

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "brand")


def artwork():
    """The word as a white-on-black mask, turned and cropped to its ink. Checks nothing is cut off before or after the turn."""
    font = ImageFont.truetype(FONT_PATH, FONT_SIZE, index=FONT_INDEX)
    left, top, right, bottom = font.getbbox(TEXT, anchor="ls")             # ink box around a baseline origin
    pad = FONT_SIZE // 2                                                   # room for swashes the box under-reports
    canvas = Image.new("L", (right - left + 2 * pad, bottom - top + 2 * pad), 0)
    ImageDraw.Draw(canvas).text((pad - left, pad - top), TEXT, font=font, fill=255, anchor="ls")
    ink = canvas.getbbox()
    assert ink and ink[0] > 8 and ink[1] > 8 and ink[2] < canvas.width - 8 and ink[3] < canvas.height - 8, "letters touch the canvas edge"
    turned = canvas.rotate(TILT_DEGREES, resample=Image.BICUBIC, expand=True)  # PIL turns counter-clockwise for a positive angle
    ink = turned.getbbox()
    assert ink[0] > 8 and ink[1] > 8 and ink[2] < turned.width - 8 and ink[3] < turned.height - 8, "turned letters touch the canvas edge"
    return turned.crop(ink)


def save(mask, width, name):
    """Scale the cropped mask so the whole picture, margin included, is `width` px wide; write it as black with the mask as alpha."""
    margin = round(width * MARGIN)
    inner = width - 2 * margin
    h = round(mask.height * inner / mask.width)
    small = mask.resize((inner, h), Image.LANCZOS)
    alpha = Image.new("L", (width, h + 2 * margin), 0)
    alpha.paste(small, (margin, margin))
    out = Image.new("RGBA", alpha.size, (0, 0, 0, 0))
    out.putalpha(alpha)
    path = os.path.normpath(os.path.join(OUT, name))
    out.save(path, optimize=True)
    print(f"{path}  {out.width}x{out.height}")


def main():
    mask = artwork()
    for name, width in SIZES.items():
        save(mask, width, name)


if __name__ == "__main__":
    main()
