#!/usr/bin/env python3
"""Natural-sounding test speech for scripts/smoke.sh, rendered on this Mac, free, no cloud.

Kokoro-82M (Apache-2.0 weights) through kokoro-onnx. The macOS `say` voices that ship with the system sound robotic; this reads
each line the way a person would: one sentence at a time, a short breath between sentences that is a little longer after a
question or a full stop than after a comma, the edges trimmed, and the level the same for every line so the microphone hears
them equally. Several speakers can take turns (a meeting), one paragraph each.

  speak.py OUTDIR < lines.tsv
    each line:  name <TAB> voice[,voice2,...] <TAB> text        paragraphs in the text are separated by " || "
    writes OUTDIR/name.wav (mono, 24 kHz, 16 bit)
  speak.py --voices      lists every voice the model has, and marks the ones kept in assets/voices/voices.json
  speak.py --samples DIR renders one short sample of each kept voice to DIR/<id>.wav

The voices FreeFlow keeps are in assets/voices/voices.json (id, a short alias such as "warm" or "calm", the feel, what each was
used for). In the lines file the voice column takes an id, an alias, or "default". The model lives in
~/Library/Application Support/FreeFlow/voices (kokoro-v1.0.onnx and voices-v1.0.bin); KOKORO_DIR overrides that folder.
Run it with a Python that has kokoro_onnx and soundfile (FF_VOICE_PY in scripts/smoke.sh)."""
import json
import os
import re
import sys

import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = json.load(open(os.path.join(HERE, "..", "..", "assets", "voices", "voices.json")))
STORED = os.path.expanduser(CONFIG["model_dir"])
LEGACY = os.path.expanduser("~/Doubao/chats/2026-10-06/new-chat-10/lemo-opuscar/core/tts")
# the copy kept inside FreeFlow comes first; the older folder is only a fallback
KD = os.environ.get("KOKORO_DIR") or (STORED if os.path.exists(os.path.join(STORED, CONFIG["model_files"][0])) else LEGACY)
SPEED = float(os.environ.get("SPEAK_SPEED", CONFIG.get("speed", 1.0)))     # 1.0 is a normal talking pace; the calm guide voice used 0.88
ALIASES = {v["alias"]: v["id"] for v in CONFIG["voices"]}


def resolve(voice):
    """An id, an alias such as "warm", or "default" (and an empty column) all name a voice."""
    voice = (voice or "").strip()
    if voice in ("", "default"):
        return CONFIG["default"]
    return ALIASES.get(voice, voice)


TARGET_RMS = 0.085                                       # about -21 dBFS, loud enough for the built-in microphone


def trim(y, sr):
    on = np.where(np.abs(y) > 0.01)[0]
    if not len(on):
        return y
    return y[max(0, on[0] - int(0.03 * sr)):min(len(y), on[-1] + int(0.09 * sr))]


def breath(sentence, i):
    """A pause that follows the sentence: longer after a question or a full stop, a little different each time."""
    base = 0.46 if sentence.rstrip().endswith("?") else 0.34
    return base + (0.05 if i % 3 == 1 else 0.0) - (0.04 if i % 4 == 2 else 0.0)


def read(k, text, voice):
    parts = [p for p in re.split(r"(?<=[.?!])\s+", text.strip()) if p]
    out, sr = [], 24000
    for i, p in enumerate(parts):
        y, sr = k.create(p.replace("’", "'"), voice=voice, speed=SPEED, lang="en-us")
        out.append(trim(np.asarray(y, dtype=np.float32), sr))
        if i < len(parts) - 1:
            out.append(np.zeros(int(breath(p, i) * sr), dtype=np.float32))
    return np.concatenate(out), sr


def level(y):
    rms = float(np.sqrt(np.mean(np.square(y)))) or 1e-6
    y = y * (TARGET_RMS / rms)
    peak = float(np.max(np.abs(y)))
    return y * (0.89 / peak) if peak > 0.89 else y


def main():
    if "--voices" in sys.argv:
        from kokoro_onnx import Kokoro
        kept = {v["id"]: v for v in CONFIG["voices"]}
        for vid in Kokoro(os.path.join(KD, "kokoro-v1.0.onnx"), os.path.join(KD, "voices-v1.0.bin")).get_voices():
            v = kept.get(vid)
            print(f"{vid:14} {'kept as ' + v['alias'] + ': ' + v['feel'] if v else ''}".rstrip())
        return 0
    if "--samples" in sys.argv:
        from kokoro_onnx import Kokoro
        out = sys.argv[sys.argv.index("--samples") + 1]
        os.makedirs(out, exist_ok=True)
        k = Kokoro(os.path.join(KD, "kokoro-v1.0.onnx"), os.path.join(KD, "voices-v1.0.bin"))
        for v in CONFIG["voices"]:
            y, sr = read(k, CONFIG["sample_text"], v["id"])
            y = level(y)
            sf.write(os.path.join(out, v["id"] + ".wav"), y, sr, subtype="PCM_16")
            print(f"{v['id']}: {len(y) / sr:.1f}s", flush=True)
        return 0
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    from kokoro_onnx import Kokoro
    k = Kokoro(os.path.join(KD, "kokoro-v1.0.onnx"), os.path.join(KD, "voices-v1.0.bin"))
    n = 0
    for raw in sys.stdin:
        raw = raw.rstrip("\n")
        if not raw.strip() or raw.startswith("#"):
            continue
        name, voices, text = raw.split("\t", 2)
        voices = [resolve(v) for v in voices.split(",") if v] or [resolve("")]
        pieces, sr = [], 24000
        for j, para in enumerate([p for p in text.split(" || ") if p.strip()]):
            y, sr = read(k, para, voices[j % len(voices)])
            pieces.append(y)
            pieces.append(np.zeros(int((0.7 if j % 2 == 0 else 0.55) * sr), dtype=np.float32))     # a turn-taking gap
        y = level(np.concatenate(pieces[:-1]))
        sf.write(os.path.join(outdir, name + ".wav"), y, sr, subtype="PCM_16")
        print(f"{name}: {len(y) / sr:.1f}s, {len(voices)} voice(s)", flush=True)
        n += 1
    return 0 if n else 1


if __name__ == "__main__":
    sys.exit(main())
