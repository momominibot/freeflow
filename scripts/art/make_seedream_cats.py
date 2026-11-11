#!/usr/bin/env python3
"""scripts/art/make_seedream_cats.py: six Seedream cats, every pose the same character at the same scale (10 Nov 2026).

Stages (run one at a time; generation stages call Seedream once each, no retry, and stop for good on the first provider problem):
  gen-lineup <id>   one lineup sheet (standing, sitting, asleep) on magenta           -> WORK/gen/lineup-<id>.png
  gen-walk          retired (the grids did not move); the walk is the standing pose with a toy toddle, made in build
  build             cut, scale, canvas, sunset, portraits, contact sheet, GIFs        -> WORK/out/ (and --install copies into assets/art)
Prompts: scripts/art/seedream_cats_prompts.py (a copy of each prompt is saved next to its image as .prompt.json by gen.py).
Pose grid for the walk: the eight cells of assets/art/cats/walk-cream.webp (or WORK/backup/cats/walk-cream.webp) arranged 4 x 2 on magenta.
WORK defaults to $CATGEN_WORK."""
import json, os, subprocess, sys, re, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
WORK = os.environ.get("CATGEN_WORK", "/private/tmp/catgen")
CATS = ["cream", "ginger", "black", "smoky", "snowy", "cocoa"]
MAX_GENERATIONS = 45
BAD = re.compile(r"rate.?limit|quota|usage|credit|balance|overdue|session|auth|unauthori|forbidden|invalid|too many|HTTP \d{3}|API error|timed? ?out|connection error|Traceback", re.I)


def block_path():
    return os.path.join(WORK, "BLOCKED.json")


def count_gens():
    p = os.path.join(WORK, "gen")
    return len([f for f in os.listdir(p) if f.endswith(".png.prompt.json")]) if os.path.isdir(p) else 0


def gen_one(out, size, refs, seed, prompt):
    """one Seedream call. Skips an existing image. First failure writes BLOCKED.json and exits nonzero (no retry, no fallback)."""
    if os.path.exists(out):
        print("exists, skipped:", out); return
    if os.path.exists(block_path()):
        sys.exit("BLOCKED earlier, not generating: " + open(block_path()).read()[:300])
    if count_gens() >= MAX_GENERATIONS:
        sys.exit("generation cap reached")
    if len(prompt) > 800:
        sys.exit(f"prompt too long ({len(prompt)})")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cmd = [sys.executable, os.path.join(HERE, "gen.py"), "--retries", "0", "--out", out, "--size", size, "--seed", str(seed)]
    for r in refs:
        cmd += ["--ref", r]
    cmd.append(prompt)
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=280)
        so, se, rc = p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        so, se, rc = "", "timeout", 124
    bad = rc != 0 or not os.path.exists(out) or BAD.search(so + se)
    if bad:
        info = {"when": time.strftime("%F %T"), "out": out, "rc": rc, "stdout": so[-400:], "stderr": se[-400:], "seconds": round(time.time() - t0)}
        if os.path.exists(out):
            os.remove(out)
        json.dump(info, open(block_path(), "w"), indent=1)
        sys.exit("PROVIDER PROBLEM, stopped: " + json.dumps(info)[:500])
    print("ok", os.path.basename(out), round(time.time() - t0), "s;", so.strip()[:160])


def main():
    import seedream_cats_prompts as P
    cmd = sys.argv[1]
    if cmd == "gen-lineup":
        cid = sys.argv[2]
        base = cid if cid in ("cream", "ginger", "black") else "cream"
        ref = os.path.join(WORK, f"ref-sit-{base}.png") if cid in ("cream", "ginger", "black") else os.path.join(WORK, "gen", "lineup-cream.png")
        gen_one(os.path.join(WORK, "gen", f"lineup-{cid}.png"), "1536x768", [ref], 11 + CATS.index(cid), P.lineup(cid))
    elif cmd == "gen-walk":
        sys.exit("gen-walk is retired: the Seedream walk grids did not move their legs; the walk is made from the standing pose by build_seedream_cats.toddle()")
    else:
        import build_seedream_cats as B
        B.run(WORK, ROOT, install="--install" in sys.argv)


if __name__ == "__main__":
    main()
