#!/bin/bash
# Installs the optional Qwen3-ASR speech engine for FreeFlow (Apple Silicon only).
# Everything lands in ~/Library/Application Support/FreeFlow/engines/qwen:
#   a private Python environment (mlx-qwen3-asr, Apache-2.0) and the model (~4.7 GB, from Hugging Face).
# Nothing is uploaded. Safe to run again: it only fills in what is missing.
set -euo pipefail

MODEL="${1:-Qwen/Qwen3-ASR-1.7B}"
ENG="$HOME/Library/Application Support/FreeFlow/engines/qwen"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

[ "$(uname -m)" = "arm64" ] || { echo "The Qwen engine needs an Apple Silicon Mac."; exit 1; }
mkdir -p "$ENG"
cd "$ENG"

if [ ! -x venv/bin/python ]; then
  echo "Creating the Python environment…"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.13 venv
  else
    PY=$(command -v python3.13 || command -v python3.12 || command -v python3.11 || true)
    [ -n "$PY" ] || { echo "Python 3.11 to 3.13 is needed. Install it with: brew install python@3.13"; exit 1; }
    "$PY" -m venv venv
  fi
fi

echo "Installing the speech package…"
if command -v uv >/dev/null 2>&1; then
  uv pip install --python venv/bin/python "mlx-qwen3-asr==0.4.4"
else
  venv/bin/python -m pip install --quiet "mlx-qwen3-asr==0.4.4"
fi

echo "Downloading the model ($MODEL)…"
venv/bin/python - "$MODEL" <<'EOF'
import sys
from huggingface_hub import snapshot_download
snapshot_download(sys.argv[1])
print("model ready")
EOF

echo "Checking it loads…"
venv/bin/python - "$MODEL" <<'EOF'
import sys
from mlx_qwen3_asr import Session
Session(model=sys.argv[1])
print("ok")
EOF
echo "Qwen engine installed."
