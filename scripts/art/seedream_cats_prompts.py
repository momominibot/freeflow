"""Prompts for make_seedream_cats.py (Purrscribe cats, 10 Nov 2026). One lineup prompt per cat, one walk-grid prompt per cat."""
STYLE_T = ("Soft 3D plush felted toy render, big round head, big glossy eyes, {cheeks}, tiny chubby body, cute, "
         "the same cat identity in every pose. Every pose wears the same thin lilac collar with one small gold bell, no bandana, no flower. ")
NOBLUSH = {"smoky", "cocoa"}   # owner, 10 Nov: no pink blush at all on the grey and the brown cat
NB = "no blush, no pink cheeks, plain fur on the cheeks"


def style(cid):
    return STYLE_T.format(cheeks=NB if cid in NOBLUSH else "very soft pink cheeks")


CATS = {
    "cream": "cream fur, apricot ear tips and apricot tail tip, lilac eyes",
    "ginger": "orange tabby fur with stripes, white chest and white paws, amber eyes",
    "black": "glossy black fur, round gold eyes",
    "smoky": "blue-grey Scottish fold with small folded-forward ears, round face, copper eyes",
    "snowy": "fluffy long-haired pure white fur, blue eyes",
    "cocoa": "chocolate brown fur with cream muzzle, cream belly and cream socks, green eyes",
}


def lineup(cid):
    return ("Character sheet on a flat pure magenta #FF00FF background, no shadows, no floor, no text. The same kitten drawn three times "
            "side by side, left to right, all at exactly the same scale so the head is the same size in each: (1) standing on four legs, "
            "side view facing right; (2) sitting upright, facing the viewer slightly turned right; (3) curled up fast asleep, head resting "
            f"on its paws on the right side. The kitten: {CATS[cid]}. " + style(cid) + "Wide gaps.")


def walkgrid(cid):
    return ("Redraw the first reference image: a 4 by 2 grid of eight walking-cycle frames on flat pure magenta #FF00FF. Keep exactly the same "
            "grid, the same eight leg and tail poses in the same cells, the same size and position of the cat in every cell, facing right. "
            f"But the cat is the kitten from the second reference image: {CATS[cid]}, same soft plush style, same lilac collar with a gold "
            "bell, no flower." + (" " + NB + "." if cid in NOBLUSH else "") + " No shadows, no floor, no text, magenta background everywhere between the cats.")
