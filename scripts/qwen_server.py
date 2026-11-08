#!/usr/bin/env python3
"""A tiny local speech server for FreeFlow, backed by Qwen3-ASR on Apple Silicon (MLX).

It speaks the same two requests the app already sends to whisper.cpp's server, so the
app only has to swap which process it starts:

    GET  /            200 once the model is loaded, 503 while it loads
    POST /inference   multipart form: file (wav), language, prompt  ->  {"text": "..."}

Everything stays on this Mac. It listens on 127.0.0.1 only.
Run with the Python from engines/qwen/venv (see scripts/install-qwen-engine.sh).
"""
import argparse
import json
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# FreeFlow sends Whisper-style codes. Qwen3-ASR wants a language it knows, or None to auto-detect.
SUPPORTED = {
    "en": "English", "zh": "Chinese", "hi": "Hindi", "ja": "Japanese", "ko": "Korean",
    "es": "Spanish", "fr": "French", "de": "German", "ar": "Arabic", "nl": "Dutch",
    "it": "Italian", "pt": "Portuguese", "ru": "Russian", "tr": "Turkish",
}

state = {"session": None, "error": None, "model": ""}
infer_lock = threading.Lock()  # the MLX model is not safe to call from two threads at once


def language_for(code):
    return SUPPORTED.get((code or "").strip().lower())  # None = let the model detect


def parse_multipart(content_type, body):
    """Minimal multipart/form-data reader (the stdlib `cgi` module is gone in Python 3.13)."""
    boundary = None
    for part in content_type.split(";"):
        part = part.strip()
        if part.startswith("boundary="):
            boundary = part[len("boundary="):].strip('"')
    if not boundary:
        raise ValueError("no multipart boundary")
    fields, files = {}, {}
    marker = ("--" + boundary).encode()
    for chunk in body.split(marker):
        chunk = chunk.strip(b"\r\n")
        if not chunk or chunk == b"--":
            continue
        head, _, data = chunk.partition(b"\r\n\r\n")
        name, filename = None, None
        for line in head.decode("utf-8", "replace").split("\r\n"):
            if line.lower().startswith("content-disposition"):
                for item in line.split(";"):
                    item = item.strip()
                    if item.startswith("name="):
                        name = item[5:].strip('"')
                    elif item.startswith("filename="):
                        filename = item[9:].strip('"')
        if name is None:
            continue
        if filename is not None:
            files[name] = data
        else:
            fields[name] = data.decode("utf-8", "replace")
    return fields, files


def transcribe(wav_bytes, language, context):
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        tmp.write(wav_bytes)
        tmp.flush()
        with infer_lock:
            result = state["session"].transcribe(tmp.name, language=language, context=context or "")
    return (result.text or "").strip()


class Handler(BaseHTTPRequestHandler):
    server_version = "freeflow-qwen/1"

    def log_message(self, fmt, *args):  # quiet: the app writes its own log
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if state["error"]:
            return self._json(500, {"error": state["error"]})
        if state["session"] is None:
            return self._json(503, {"status": "loading"})
        self._json(200, {"status": "ok", "model": state["model"]})

    def do_POST(self):
        if self.path.split("?")[0] != "/inference":
            return self._json(404, {"error": "not found"})
        if state["session"] is None:
            return self._json(503, {"error": "model still loading"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            fields, files = parse_multipart(self.headers.get("Content-Type", ""), body)
            audio = files.get("file")
            if not audio:
                return self._json(400, {"error": "no audio"})
            started = time.time()
            text = transcribe(audio, language_for(fields.get("language")), fields.get("prompt", ""))
            sys.stderr.write("transcribed %d bytes in %.2fs\n" % (len(audio), time.time() - started))
            self._json(200, {"text": text})
        except Exception as e:  # report to the app instead of dropping the connection
            sys.stderr.write("error: %r\n" % (e,))
            self._json(500, {"error": str(e)})


def load_model(model):
    try:
        from mlx_qwen3_asr import Session
        state["session"] = Session(model=model)
        state["model"] = model
        # The first inference is slow; spend it on a moment of silence.
        import wave
        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            with wave.open(tmp.name, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(16000)
                w.writeframes(b"\x00\x00" * 8000)
            state["session"].transcribe(tmp.name, language="English")
    except Exception as e:
        state["error"] = "Qwen engine failed to load: %s" % (e,)
        state["session"] = None
        sys.stderr.write(state["error"] + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8178)
    ap.add_argument("--model", default="Qwen/Qwen3-ASR-1.7B")
    args = ap.parse_args()
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    threading.Thread(target=load_model, args=(args.model,), daemon=True).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
