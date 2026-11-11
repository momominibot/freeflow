#!/bin/bash
# Makes the little brand pictures on the MCP page (assets/brand/apps/<slug>.png).
# The shapes are Simple Icons (CC0, pinned release), drawn in each brand's own colour by scripts/art/svg2png.swift.
# The brand names and marks still belong to their owners; FreeFlow only shows them to say "works with".
# hermes.png is not made here: it is the Hermes Agent app icon (MIT, Nous Research); its notice is assets/brand/apps/NOTICE.txt.
# Needs curl, python3 and swiftc. Run from anywhere: scripts/art/make_app_logos.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION=16.37.0
BASE="https://cdn.jsdelivr.net/npm/simple-icons@$VERSION"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
OUT=assets/brand/apps
mkdir -p "$OUT"
swiftc -O scripts/art/svg2png.swift -o "$WORK/svg2png" 2>/dev/null
curl -sfL -o "$WORK/simple-icons.json" "$BASE/data/simple-icons.json"
for slug in claude cursor googlegemini modelcontextprotocol; do
  curl -sfL -o "$WORK/$slug.svg" "$BASE/icons/$slug.svg"
  hex=$(python3 - "$WORK/simple-icons.json" "$slug" <<'PY'
import json, sys
for e in json.load(open(sys.argv[1])):
    if (e.get("slug") or e["title"].lower().replace(" ", "")) == sys.argv[2]:
        print(e["hex"]); break
PY
)
  "$WORK/svg2png" "$WORK/$slug.svg" "$OUT/$slug.png" "$hex" 160 >/dev/null
  echo "$slug #$hex"
done
