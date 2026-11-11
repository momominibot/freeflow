#!/bin/bash
# Purrscribe installer for teammates. Run from the unzipped release folder:
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

[ "$(uname -m)" = "arm64" ] || { echo "Purrscribe needs an Apple Silicon Mac."; exit 1; }
[ -d Purrscribe.app ] || { echo "Purrscribe.app is not next to this script. Unzip the release first."; exit 1; }

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

say "3/4 Installing Purrscribe.app"
# Stage the new copy first and check it, so a broken download never removes a working install.
STAGE="/Applications/.Purrscribe.app.new"
rm -rf "$STAGE"
ditto Purrscribe.app "$STAGE"
# The app is signed with a development certificate, not a Developer ID, so macOS would refuse to open
# a downloaded copy. Clearing the download flag on a file you chose to install is the standard fix.
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
codesign --verify --deep "$STAGE" || { rm -rf "$STAGE"; echo "The app bundle failed its signature check; not installed."; exit 1; }
"$STAGE/Contents/MacOS/Purrscribe" --test >/dev/null || { rm -rf "$STAGE"; echo "The app failed its self-checks; not installed."; exit 1; }
pkill -x Purrscribe 2>/dev/null || true
pkill -x FreeFlow 2>/dev/null || true     # the app's old name, so an earlier install is quit as well
sleep 0.5
rm -rf /Applications/Purrscribe.app
mv "$STAGE" /Applications/Purrscribe.app
# An earlier install lives at /Applications/FreeFlow.app and AI-app setups point at its freeflow-mcp.py. Leave a link under the old
# path so they keep working; a fresh machine gets no link.
if [ -d /Applications/FreeFlow.app ] && [ ! -L /Applications/FreeFlow.app ]; then
  rm -rf /Applications/FreeFlow.app
  ln -s Purrscribe.app /Applications/FreeFlow.app
fi
echo "installed to /Applications/Purrscribe.app"

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
    echo "Ollama is already running; Purrscribe will use $AI_MODEL if it is pulled (ollama pull $AI_MODEL)"
  else
    echo "skipped. Re-run with --with-ai to add it; without it Purrscribe uses rule-based clean-up only."
  fi
fi

# The free local AI is the part people most often miss, so say where its steps are (the guide sits next to this script in the release zip).
GUIDE="LOCAL-MODEL-GUIDE.md"; [ -f "$GUIDE" ] || GUIDE="docs/LOCAL-MODEL-GUIDE.md"
tags=$(curl -s -m 2 127.0.0.1:11434/api/tags 2>/dev/null || true)
case "$tags" in
  *"\"$AI_MODEL"*) ai_line="Local AI: ready ($AI_MODEL). Rewrites, Command Mode and Edit by voice work." ;;
  *) ai_line="Local AI: not ready yet. Purrscribe shows the next step in Help > The local AI, and $GUIDE has all of them (it is free and runs on this Mac)." ;;
esac

open /Applications/Purrscribe.app
say "Done. Purrscribe is in the menu bar."
cat <<'EOF'
First launch asks for Microphone and Accessibility. Allow both, then:
  hold right Option, talk, let go          -> text appears where your cursor is
  tap Shift while holding                  -> hands-free; tap right Option again to finish
  select text, hold right Control, speak   -> Command Mode ("make this shorter", "turn this into bullet points")
  say "press enter" at the end             -> sends the message
Team: menu bar icon > Team > Choose team folder (the shared folder your admin set up).
EOF
echo "$ai_line"
