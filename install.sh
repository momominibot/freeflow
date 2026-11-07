#!/bin/bash
# FreeFlow installer for teammates. Run from the unzipped release folder:
#   ./install.sh            # app + speech engine + model
#   ./install.sh --with-ai  # also installs Ollama and the local AI model for clean-up and Command Mode
#
# Everything runs on your Mac. Nothing is uploaded.
set -euo pipefail
cd "$(dirname "$0")"

MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
MODEL_SHA="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
SUPPORT="$HOME/Library/Application Support/FreeFlow"
MODEL="$SUPPORT/models/ggml-large-v3-turbo-q5_0.bin"
AI_MODEL="qwen3.5:9b"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ "$(uname -m)" = "arm64" ] || { echo "FreeFlow needs an Apple Silicon Mac."; exit 1; }
[ -d FreeFlow.app ] || { echo "FreeFlow.app is not next to this script. Unzip the release first."; exit 1; }

if ! command -v brew >/dev/null 2>&1; then
  say "Homebrew is needed for the speech engine. Install it from https://brew.sh then run this script again."
  exit 1
fi

say "1/4 Speech engine (whisper.cpp)"
if [ -x /opt/homebrew/bin/whisper-server ]; then
  echo "already installed"
else
  brew install whisper-cpp
fi

say "2/4 Speech model (574 MB, downloaded once)"
mkdir -p "$SUPPORT/models"
if [ -f "$MODEL" ] && [ "$(shasum -a 256 "$MODEL" | cut -d' ' -f1)" = "$MODEL_SHA" ]; then
  echo "already present and verified"
else
  curl -L --progress-bar -o "$MODEL.part" "$MODEL_URL"
  got=$(shasum -a 256 "$MODEL.part" | cut -d' ' -f1)
  if [ "$got" != "$MODEL_SHA" ]; then
    rm -f "$MODEL.part"
    echo "Model download did not match its checksum. Try again."; exit 1
  fi
  mv "$MODEL.part" "$MODEL"
  echo "downloaded and verified"
fi

say "3/4 Installing FreeFlow.app"
# Stage the new copy first and check it, so a broken download never removes a working install.
STAGE="/Applications/.FreeFlow.app.new"
rm -rf "$STAGE"
ditto FreeFlow.app "$STAGE"
# The app is signed with a development certificate, not a Developer ID, so macOS would refuse to open
# a downloaded copy. Clearing the download flag on a file you chose to install is the standard fix.
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
codesign --verify --deep "$STAGE" || { rm -rf "$STAGE"; echo "The app bundle failed its signature check; not installed."; exit 1; }
"$STAGE/Contents/MacOS/FreeFlow" --test >/dev/null || { rm -rf "$STAGE"; echo "The app failed its self-checks; not installed."; exit 1; }
pkill -x FreeFlow 2>/dev/null || true
sleep 0.5
rm -rf /Applications/FreeFlow.app
mv "$STAGE" /Applications/FreeFlow.app
echo "installed to /Applications/FreeFlow.app"

say "4/4 Local AI for clean-up and Command Mode (optional)"
if [ "${1:-}" = "--with-ai" ]; then
  if ! command -v ollama >/dev/null 2>&1; then
    brew install ollama
  fi
  if ! curl -s -m 2 127.0.0.1:11434/api/tags >/dev/null; then
    brew services start ollama
    for _ in $(seq 1 20); do curl -s -m 1 127.0.0.1:11434/api/tags >/dev/null && break; sleep 1; done
  fi
  ollama pull "$AI_MODEL"
  echo "Ollama running with $AI_MODEL (about 7.6 GB on disk)"
else
  if curl -s -m 2 127.0.0.1:11434/api/tags >/dev/null; then
    echo "Ollama is already running; FreeFlow will use $AI_MODEL if it is pulled (ollama pull $AI_MODEL)"
  else
    echo "skipped. Re-run with --with-ai to add it; without it FreeFlow uses rule-based clean-up only."
  fi
fi

open /Applications/FreeFlow.app
say "Done. FreeFlow is in the menu bar."
cat <<'EOF'
First launch asks for Microphone and Accessibility. Allow both, then:
  hold right Option, talk, let go          -> text appears where your cursor is
  tap Shift while holding                  -> hands-free; tap right Option again to finish
  select text, hold right Control, speak   -> Command Mode ("make this shorter", "turn this into bullet points")
  say "press enter" at the end             -> sends the message
Team: menu bar icon > Team > Choose team folder (the shared folder your admin set up).
EOF
