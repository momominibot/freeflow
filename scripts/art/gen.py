#!/usr/bin/env python3
"""Seedream 5.0 pro helper. Usage:
  gen.py --out file.png --size 1664x2080 [--ref img ...] [--seed N] [--fmt png|jpeg] "prompt"
Writes the image and a sidecar .prompt.json. Never prints the key."""
import argparse, base64, json, os, sys, time, urllib.request, mimetypes, http.client

# Route (Jamie, 30 Oct: images go on the Agent Plan, not the pay-as-you-go balance, which ran overdue):
# plan (default) = /api/plan/v3 with the plan key; RHYTHME_ART_ROUTE=paygo = the old /api/v3 with the account key.
ROUTE = os.environ.get("RHYTHME_ART_ROUTE", "plan")
if ROUTE == "paygo":
    MODEL = "doubao-seedream-5-0-pro-260628"
    URL = "https://ark.cn-beijing.volces.com/api/v3/images/generations"
    KEYFILE = "~/.config/volcengine/api_key"
else:
    MODEL = "doubao-seedream-5.0-pro"
    URL = "https://ark.cn-beijing.volces.com/api/plan/v3/images/generations"
    KEYFILE = "~/.config/volcengine/agent_plan_api_key"

def key():
    # a cloud session reads ARK_API_KEY from the environment's secrets; a laptop keeps the key in a file
    k = os.environ.get("ARK_API_KEY", "").strip()
    return k or open(os.path.expanduser(KEYFILE)).read().strip()

RAWREF = "--rawref" in __import__("sys").argv
def ref_to_param(p, max_side=1280):
    if p.startswith("http"):
        return p
    if RAWREF:
        mime = mimetypes.guess_type(p)[0] or "image/png"
        return f"data:{mime};base64," + base64.b64encode(open(p, "rb").read()).decode()
    # Downscale heavy references to a JPEG so the request stays small; the
    # server only needs the composition, not 4MB of pixels.
    try:
        from PIL import Image
        import io
        im = Image.open(p).convert("RGB")
        if max(im.size) > max_side:
            im.thumbnail((max_side, max_side), Image.LANCZOS)
        buf = io.BytesIO(); im.save(buf, "JPEG", quality=88)
        return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()
    except Exception as e:
        print("ref downscale failed, sending original:", e, file=sys.stderr)
    mime = mimetypes.guess_type(p)[0] or "image/png"
    b = base64.b64encode(open(p, "rb").read()).decode()
    return f"data:{mime};base64,{b}"

def read_stream(r):
    """Parse SSE; keep the last event carrying an image."""
    last_img, usage, err = None, None, None
    for raw in r:
        line = raw.decode("utf-8", errors="replace").strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload in ("", "[DONE]"):
            continue
        try:
            ev = json.loads(payload)
        except Exception:
            continue
        if ev.get("error"):
            err = ev["error"]
        if ev.get("b64_json") or ev.get("url"):
            last_img = ev
        if ev.get("usage"):
            usage = ev["usage"]
        for d in ev.get("data", []) or []:
            if d.get("b64_json") or d.get("url"):
                last_img = d
    return last_img, usage, err

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt")
    ap.add_argument("--out", required=True)
    ap.add_argument("--size", default="2K")
    ap.add_argument("--ref", action="append", default=[])
    ap.add_argument("--seed", type=int, default=-1)
    ap.add_argument("--fmt", default="png")
    ap.add_argument("--retries", type=int, default=2)
    ap.add_argument("--stream", action="store_true", help="SSE streaming keeps long renders alive")
    ap.add_argument("--url", action="store_true", help="ask for a URL instead of inline base64 (a small JSON reply, then a plain download; avoids truncated bodies)")
    ap.add_argument("--rawref", action="store_true")
    ap.add_argument("--model", default=MODEL)
    a = ap.parse_args()
    body = {"model": a.model, "prompt": a.prompt, "size": a.size, "response_format": "url" if a.url else "b64_json",
            "watermark": False, "seed": a.seed}
    if a.model.startswith("doubao-seedream-5"):
        body["output_format"] = a.fmt
    if a.stream:
        body["stream"] = True
    if a.ref:
        refs = [ref_to_param(r) for r in a.ref]
        body["image"] = refs if len(refs) > 1 else refs[0]
    data = json.dumps(body).encode()
    last = None
    for attempt in range(a.retries + 1):
        req = urllib.request.Request(URL, data=data, headers={"Authorization": "Bearer " + key(), "Content-Type": "application/json"})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                if a.stream:
                    img_ev, usage, err = read_stream(r)
                    if err:
                        print("API error:", json.dumps(err, ensure_ascii=False)[:400], file=sys.stderr); sys.exit(3)
                    if not img_ev:
                        raise ConnectionError("stream ended without an image")
                    if img_ev.get("url") and not img_ev.get("b64_json"):
                        with urllib.request.urlopen(img_ev["url"], timeout=120) as ir:
                            img_ev["b64_json"] = base64.b64encode(ir.read()).decode()
                    res = {"data": [img_ev], "usage": usage}
                else:
                    res = json.loads(r.read())
                    if a.url and "data" in res and res["data"] and res["data"][0].get("url") and not res["data"][0].get("b64_json"):
                        with urllib.request.urlopen(res["data"][0]["url"], timeout=120) as ir:
                            res["data"][0]["b64_json"] = base64.b64encode(ir.read()).decode()
        except urllib.error.HTTPError as e:
            last = e.read().decode(errors="replace")
            print(f"HTTP {e.code}: {last[:400]}", file=sys.stderr)
            if e.code in (429, 500, 502, 503, 504) and attempt < a.retries:
                time.sleep(8); continue
            sys.exit(2)
        except (ConnectionError, OSError, EOFError, http.client.HTTPException) as e:
            # Long 2K renders sometimes drop the socket; the job is idempotent, so retry.
            print(f"connection error ({type(e).__name__}): {e}; attempt {attempt+1}/{a.retries+1} after {round(time.time()-t0,1)}s", file=sys.stderr)
            if attempt < a.retries:
                time.sleep(5); continue
            sys.exit(5)
        if "error" in res:
            print("API error:", json.dumps(res["error"], ensure_ascii=False)[:400], file=sys.stderr); sys.exit(3)
        img = res["data"][0]
        raw = base64.b64decode(img["b64_json"])
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        open(a.out, "wb").write(raw)
        meta = {"model": a.model, "prompt": a.prompt, "size_req": a.size, "size": img.get("size"), "seed": a.seed,
                "refs": a.ref, "usage": res.get("usage"), "seconds": round(time.time() - t0, 1), "bytes": len(raw)}
        open(a.out + ".prompt.json", "w").write(json.dumps(meta, ensure_ascii=False, indent=1))
        print(json.dumps({"out": a.out, "size": img.get("size"), "bytes": len(raw), "seconds": meta["seconds"]}))
        return
    sys.exit(4)

if __name__ == "__main__":
    main()
