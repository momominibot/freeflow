#!/usr/bin/env python3
"""Run recordings through both FreeFlow engines and print them side by side, with word error when the right answer is known.

    ~/Library/Application\\ Support/FreeFlow/engines/qwen/venv/bin/python scripts/compare-engines.py [folder] [options]

    --script FILE   one right-answer sentence per line, matched to the recordings in file-name order
                    (use docs/read-aloud-script.txt after reading it aloud, see docs/read-aloud-script.md)
    --lang LANG     mixed (default: English + Chinese), or en to force English
    -o FILE         write the report to FILE instead of printing it

Without --script, a take's own .json can carry "truth": "what you actually said".
Turn on "Keep my recordings on this Mac" in the menu (Speech engine) to collect takes. Nothing leaves this Mac.
Error is counted per English word and per Chinese character, ignoring punctuation, case and spaces.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

SUPPORT = os.path.expanduser("~/Library/Application Support/FreeFlow")
WHISPER_MODEL = os.path.join(SUPPORT, "models", "ggml-large-v3-turbo-q5_0.bin")
WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
TOKEN = re.compile(r"[a-z0-9+']+|[㐀-䶿一-鿿]")


def terms():
    path = os.path.join(SUPPORT, "dictionary.txt")
    out = []
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=>" not in line:
                out.append(line)
    return out[:60]


def prompt_for(lang):
    t = terms()
    if not t:
        return ""
    return "词汇：" + ", ".join(t) + "。" if lang == "mixed" else "Glossary: " + ", ".join(t) + "."


def words(s):
    s = re.sub(r"(?<=\d),(?=\d)", "", s.lower())
    return TOKEN.findall(s)


def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    if not r:
        return None
    d = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hw in enumerate(h, 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (rw != hw))
            prev, d[j] = d[j], cur
    return d[len(h)] / len(r)


def whisper(wav, lang, prompt):
    out = subprocess.run([WHISPER_CLI, "-m", WHISPER_MODEL, "-f", wav, "-nt", "-l", "auto" if lang == "mixed" else lang,
                          "-t", "6", "--prompt", prompt], capture_output=True, text=True)
    return " ".join(out.stdout.split())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", nargs="?", default=os.path.join(SUPPORT, "takes"))
    ap.add_argument("--script")
    ap.add_argument("--lang", default="mixed")
    ap.add_argument("-o", dest="report")
    a = ap.parse_args()
    folder = os.path.expanduser(a.folder)
    wavs = sorted(glob.glob(os.path.join(folder, "*.wav")))
    if not wavs:
        sys.exit("No recordings in %s. Turn on 'Keep my recordings' first." % folder)
    truths = [None] * len(wavs)
    if a.script:
        lines = [l.strip() for l in open(os.path.expanduser(a.script), encoding="utf-8") if l.strip()]
        if len(lines) != len(wavs):
            sys.exit("The script has %d sentences but %s has %d recordings. Delete the extra or redo the missing ones, "
                     "so they line up one to one." % (len(lines), folder, len(wavs)))
        truths = lines
    from mlx_qwen3_asr import Session
    session = Session(model="Qwen/Qwen3-ASR-1.7B")
    prompt = prompt_for(a.lang)
    qlang = "Chinese" if a.lang == "mixed" else {"en": "English"}.get(a.lang)
    rows, scored = [], {"whisper": [], "qwen": []}
    for k, wav in enumerate(wavs):
        meta_path = wav[:-4] + ".json"
        meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
        w = whisper(wav, a.lang, prompt)
        q = session.transcribe(wav, language=qlang, context=prompt).text.strip()
        truth = truths[k] or meta.get("truth")
        errs = {}
        if truth:
            for name, text in (("whisper", w), ("qwen", q)):
                e = wer(truth, text)
                if e is not None:
                    errs[name] = e
                    scored[name].append(e)
        rows.append((k + 1, os.path.basename(wav), meta.get("heard", ""), w, q, truth, errs))
    lines = ["# FreeFlow engine comparison", ""]
    for k, name, heard, w, q, truth, errs in rows:
        lines += ["## %d. %s" % (k, name)]
        if truth:
            lines.append("- You read:  " + truth)
        lines += ["- Whisper:    %s%s" % (w, "  [%.0f%% error]" % (100 * errs["whisper"]) if "whisper" in errs else ""),
                  "- Qwen3-ASR:  %s%s" % (q, "  [%.0f%% error]" % (100 * errs["qwen"]) if "qwen" in errs else "")]
        if heard:
            lines.append("- Heard live: " + heard)
        lines.append("")
    if scored["whisper"]:
        n = len(scored["whisper"])
        lines.append("Mean error over %d scored takes: Whisper %.1f%%, Qwen3-ASR %.1f%%" % (
            n, 100 * sum(scored["whisper"]) / n, 100 * sum(scored["qwen"]) / n))
        better = sum(1 for x, y in zip(scored["whisper"], scored["qwen"]) if y < x)
        worse = sum(1 for x, y in zip(scored["whisper"], scored["qwen"]) if y > x)
        lines.append("Qwen better on %d takes, worse on %d, same on %d." % (better, worse, n - better - worse))
    text = "\n".join(lines)
    if a.report:
        open(os.path.expanduser(a.report), "w", encoding="utf-8").write(text)
        print("wrote", a.report)
    else:
        print(text)


if __name__ == "__main__":
    main()
