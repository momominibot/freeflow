#!/bin/bash
# Builds the Harper grammar checker (Apache-2.0, https://github.com/Automattic/harper) into a static library
# for the Mac app: native/harper/libharper-macos.a
#
#   scripts/build-harper.sh macos     builds it (build.sh calls it this way; with no argument it does the same)
#
# Purrscribe builds without it (a smaller built-in checker is used then); with it you get Harper's few hundred rules.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TAG="v3.1.0"                                     # pinned: change on purpose, then rerun this and the tests
CACHE="$ROOT/.harper-build"
OUT="$ROOT/native/harper"
WHICH="${1:-macos}"

# Find a Rust toolchain: PATH first, then any rustup toolchain.
if ! command -v cargo >/dev/null 2>&1; then
  TC=$(ls -d "$HOME"/.rustup/toolchains/*/bin 2>/dev/null | head -1 || true)
  [ -n "$TC" ] && export PATH="$TC:$PATH"
fi
command -v cargo >/dev/null 2>&1 || { echo "No Rust found. Install it with: brew install rustup && rustup default stable"; exit 1; }

mkdir -p "$CACHE" "$OUT"
if [ ! -d "$CACHE/harper" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/Automattic/harper.git "$CACHE/harper"
fi
cd "$CACHE/harper"
rm -rf harper-ffi && cp -R "$ROOT/rust/harper-ffi" harper-ffi
# Join Harper's workspace so its pinned Cargo.lock (exact dependency versions) is used.
grep -q '"harper-ffi"' Cargo.toml || sed -i '' 's|^members = \[|members = ["harper-ffi", |' Cargo.toml

# Harper's release profile aborts on a panic; here a panic must come back as "no answer", not close the app.
export CARGO_PROFILE_RELEASE_PANIC=unwind
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=4

build() { # <rust target> <output name> <env...>
  local target=$1 name=$2; shift 2
  echo "== $name ($target)"
  if ! rustup target list --installed 2>/dev/null | grep -qx "$target"; then
    rustup target add "$target" || { echo "Could not install the Rust target $target"; exit 1; }
  fi
  local log="$CACHE/build-$name.log"
  if ! env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" "$@" \
        cargo build --release -p harper-ffi --target "$target" >"$log" 2>&1; then
    tail -25 "$log"
    echo "Harper ($name) did not build. Full log: $log"
    exit 1
  fi
  tail -1 "$log"
  cp "target/$target/release/libharper_ffi.a" "$OUT/libharper-$name.a"
}

case "$WHICH" in
  all|macos) ;;
  *) echo "Usage: scripts/build-harper.sh [macos]"; exit 1 ;;
esac
build aarch64-apple-darwin macos MACOSX_DEPLOYMENT_TARGET=13.0
ls -lh "$OUT"
