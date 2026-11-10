#!/usr/bin/env python3
"""Writes ThirdPartyNotices.txt: scripts/notices-header.txt plus the licence text of every Rust library linked into Harper.

Needs the Harper checkout from scripts/build-harper.sh (.harper-build/harper) and a Rust toolchain.
    python3 scripts/gen-notices.py          writes ThirdPartyNotices.txt and ios/App/Resources/ThirdPartyNotices.txt
"""
import hashlib, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARPER = os.path.join(ROOT, ".harper-build", "harper")
if not os.path.isdir(HARPER):
    sys.exit("Run scripts/build-harper.sh first (it fetches Harper into .harper-build/harper).")

env = dict(os.environ)
tc = sorted(d for d in (os.path.join(os.path.expanduser("~/.rustup/toolchains"), t, "bin") for t in os.listdir(os.path.expanduser("~/.rustup/toolchains"))) if os.path.isdir(d)) if os.path.isdir(os.path.expanduser("~/.rustup/toolchains")) else []
if tc:
    env["PATH"] = tc[0] + ":" + env["PATH"]

def run(*cmd):
    return subprocess.run(cmd, cwd=HARPER, env=env, capture_output=True, text=True, check=True).stdout

meta = json.loads(run("cargo", "metadata", "--format-version", "1", "--filter-platform", "aarch64-apple-ios", "--offline"))
pkgs = {(p["name"], p["version"]): p for p in meta["packages"]}
tree = run("cargo", "tree", "-p", "harper-ffi", "--target", "aarch64-apple-ios", "-e", "normal", "--prefix", "none", "--offline")
linked = sorted({tuple(l.replace(" (*)", "").split()[:2]) for l in tree.splitlines() if l.strip()})

LICENSE_NAME = re.compile(r"^(LICEN[CS]E|COPYING|UNLICENSE|NOTICE)", re.I)
texts = {}      # sha -> text
users = {}      # sha -> [crate names]
missing = []
for name, ver in linked:
    ver = ver.lstrip("v")
    p = pkgs.get((name, ver))
    if not p:
        continue
    d = os.path.dirname(p["manifest_path"])
    # Harper's own crates keep their licence at the workspace root, not next to each Cargo.toml.
    while not any(LICENSE_NAME.match(f) for f in os.listdir(d)) and name.startswith("harper-") and os.path.abspath(d) != HARPER:
        d = os.path.dirname(d)
    files = sorted(f for f in os.listdir(d) if LICENSE_NAME.match(f) and os.path.isfile(os.path.join(d, f)))
    if not files:
        missing.append((name, ver, p.get("license") or ""))
        continue
    for f in files:
        t = open(os.path.join(d, f), encoding="utf-8", errors="replace").read().strip()
        h = hashlib.sha256(t.encode()).hexdigest()
        texts[h] = t
        users.setdefault(h, []).append(f"{name} {ver}")

# A crate that ships no licence file but is licensed "MIT OR Apache-2.0" may be used under the Apache terms, whose text is included.
apache = next((h for h in texts if texts[h].startswith("Apache License") and "Version 2.0, January 2004" in texts[h][:200]), None)
still_missing = []
for name, ver, lic in missing:
    if apache and "Apache-2.0" in lic and " OR " in lic:
        users[apache].append(f"{name} {ver}")
    else:
        still_missing.append(f"{name} {ver} ({lic})")
missing = still_missing

out = [open(os.path.join(ROOT, "scripts", "notices-header.txt"), encoding="utf-8").read().rstrip(), ""]
out.append("=" * 80)
out.append("Rust libraries inside Harper")
out.append("=" * 80)
out.append(f"{len(linked)} libraries are linked into the grammar checker. Each is listed with its licence text below; libraries that")
out.append("share the same text are grouped. Sources: the repository named in each crate's page on https://crates.io.")
out.append("Three libraries are under the Mozilla Public License 2.0 (colored, cssparser, dtoa-short). They are used unmodified and")
out.append("their source is public at https://github.com/mackwic/colored, https://github.com/servo/rust-cssparser and")
out.append("https://github.com/upsuper/dtoa-short.")
out.append("")
# The Apache text first (Harper's own), then the rest by crate name.
def first_user(h): return users[h][0]
order = sorted(texts, key=lambda h: (0 if any(u.startswith("harper-core ") for u in users[h]) else 1, first_user(h)))
for h in order:
    out.append("-" * 80)
    out.append("Used by: " + ", ".join(sorted(users[h])))
    out.append("-" * 80)
    out.append(texts[h])
    out.append("")
if missing:
    out.append("-" * 80)
    out.append("Libraries that ship no licence file; their licence is named in their package metadata:")
    out.extend("  " + m for m in missing)
    out.append("")
text = "\n".join(out)
for dest in (os.path.join(ROOT, "ThirdPartyNotices.txt"), os.path.join(ROOT, "ios", "App", "Resources", "ThirdPartyNotices.txt")):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, "w", encoding="utf-8").write(text)
print(f"{len(linked)} libraries, {len(texts)} distinct licence texts, {len(missing)} without a licence file, {len(text) // 1024} KB")
for m in missing: print("  no licence file:", m)
