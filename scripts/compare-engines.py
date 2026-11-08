#!/usr/bin/env python3
"""Run every saved FreeFlow recording through both engines and print them side by side.

    ~/Library/Application\\ Support/FreeFlow/engines/qwen/venv/bin/python scripts/compare-engines.py [folder] [-o report.md]

Turn on "Keep my recordings on this Mac" in the menu (Speech engine) and dictate for a few days.
Each take is a .wav plus a .json with what the engine heard at the time. Nothing leaves this Mac.
Add your own right answer by putting "truth": "what you actually said" in a take's .json,
and the report scores both engines on word errors for those takes.
"""
import glob
import json
import os
import re
import subprocess
import sys

SUPPORT = os.path.expanduser("~/Library/Application Support/FreeFlow")
WHISPER_MODEL = os.path.join(SUPPORT, "models", "ggml-large-v3-turbo-q5_0.bin")
WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"


def vocab_prompt():
    path = os.path.join(SUPPORT, "dictionary.txt")
    terms = []
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=>" not in line:
                terms.append(line)
    return "Glossary: " + ", ".join(terms[:60]) + "." if terms else ""


def words(s):
    return re.findall(r"[a-z0-9+']+", s.lower())


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


def whisper(wav, prompt):
    out = subprocess.run([WHISPER_CLI, "-m", WHISPER_MODEL, "-f", wav, "-nt", "-l", "en", "-t", "6",
                          "--prompt", prompt], capture_output=True, text=True)
    return " ".join(out.stdout.split())


def main():
    argv = sys.argv[1:]
    report = None
    if "-o" in argv:
        i = argv.index("-o")
        report = argv[i + 1]
        del argv[i:i + 2]
    args = [a for a in argv if not a.startswith("-")]
    folder = os.path.expanduser(args[0]) if args else os.path.join(SUPPORT, "takes")
    wavs = sorted(glob.glob(os.path.join(folder, "*.wav")))
    if not wavs:
        sys.exit("No recordings in %s. Turn on 'Keep my recordings' first." % folder)
    from mlx_qwen3_asr import Session
    session = Session(model="Qwen/Qwen3-ASR-1.7B")
    prompt = vocab_prompt()
    rows, scored = [], {"whisper": [], "qwen": []}
    for wav in wavs:
        meta_path = wav[:-4] + ".json"
        meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
        w = whisper(wav, prompt)
        q = session.transcribe(wav, language="English", context=prompt).text.strip()
        truth = meta.get("truth")
        if truth:
            for name, text in (("whisper", w), ("qwen", q)):
                e = wer(truth, text)
                if e is not None:
                    scored[name].append(e)
        rows.append((os.path.basename(wav), meta.get("heard", ""), w, q, truth))
    lines = ["# FreeFlow engine comparison", ""]
    for name, heard, w, q, truth in rows:
        lines += ["## " + name, "- Heard live (%s): %s" % ("kept", heard or "-"),
                  "- Whisper large-v3-turbo: " + w, "- Qwen3-ASR 1.7B: " + q]
        if truth:
            lines.append("- You said: " + truth)
        lines.append("")
    if scored["whisper"]:
        n = len(scored["whisper"])
        lines.append("Word error over %d takes with your answer: Whisper %.1f%%, Qwen %.1f%%" % (
            n, 100 * sum(scored["whisper"]) / n, 100 * sum(scored["qwen"]) / n))
    text = "\n".join(lines)
    if report:
        open(report, "w", encoding="utf-8").write(text)
        print("wrote", report)
    else:
        print(text)


if __name__ == "__main__":
    main()
