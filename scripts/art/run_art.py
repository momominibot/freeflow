#!/usr/bin/env python3
"""One guarded run of the FreeFlow pictures (Seedream 5 pro through scripts/art/gen.py, Agent Plan route).

Rules: one go-ahead (the RUN_STARTED marker is written first and a second run refuses); a single lock; at least 60 s between
requests (shared ark-pace); one request per picture with no retry; stdout must be exactly gen.py's one JSON line and stderr
empty, otherwise the first problem stops the whole run and writes BLOCKED.json. Existing pictures are skipped.
Usage: python3 scripts/art/run_art.py [--dry]"""
import fcntl, json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
# Optional: --prompts FILE --out DIR (defaults: prompts.json into assets/art/raw)
def _opt(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default
PROMPTS = os.path.join(HERE, _opt("--prompts", "prompts.json"))
OUT = os.path.abspath(os.path.join(HERE, "..", "..", _opt("--out", "assets/art/raw")))
sys.path.insert(0, os.path.expanduser("~/.local/share/ark-pace"))
os.environ.setdefault("ARK_MIN_GAP", "60")

def main():
    dry = "--dry" in sys.argv
    cfg = json.load(open(PROMPTS))
    os.makedirs(OUT, exist_ok=True)
    marker, blocked = os.path.join(OUT, "RUN_STARTED"), os.path.join(OUT, "BLOCKED.json")
    if os.path.exists(blocked):
        print("blocked earlier:", open(blocked).read()[:300]); sys.exit(1)
    todo = [i for i in cfg["images"] if not os.path.exists(os.path.join(OUT, i["name"] + ".png"))]
    print(f"{len(todo)} of {len(cfg['images'])} pictures to make"); sys.stdout.flush()
    if dry or not todo: return
    if os.path.exists(marker):
        print("RUN_STARTED exists: the go-ahead was already used. Remove it only with a new yes."); sys.exit(1)
    lock = open(os.path.expanduser("~/.local/share/freeflow-art.lock"), "a+")
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError: print("another art run holds the lock"); sys.exit(1)
    open(marker, "w").write(time.strftime("%Y-%m-%d %H:%M:%S"))
    import arkpace
    for img in todo:
        arkpace.wait()
        prompt = f'{cfg["style"]} {cfg["mascot"]} {img["scene"]}'
        out = os.path.join(OUT, img["name"] + ".png")
        p = subprocess.run([sys.executable, os.path.join(HERE, "gen.py"), "--out", out, "--size", "1024x1024", "--seed", str(img["seed"]),
                            "--retries", "0", "--url", prompt], capture_output=True, text=True, timeout=400)
        lines = [l for l in p.stdout.strip().splitlines() if l.strip()]
        ok = p.returncode == 0 and len(lines) == 1 and not p.stderr.strip() and os.path.exists(out)
        if ok:
            try: json.loads(lines[0])
            except Exception: ok = False
        if not ok:
            open(blocked, "w").write(json.dumps({"image": img["name"], "rc": p.returncode, "stdout": p.stdout[:400], "stderr": p.stderr[:400]}))
            print("STOPPED at", img["name"], "rc", p.returncode, p.stderr[:200]); sys.exit(2)
        print("ok", img["name"], lines[0]); sys.stdout.flush()
    print("CLEAN: all pictures made")

main()
