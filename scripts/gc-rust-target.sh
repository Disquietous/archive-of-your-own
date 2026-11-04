#!/bin/bash
set -euo pipefail

# Garbage-collect Cargo target trees down to exactly what the last
# sanctioned build used.
#
# Cargo never deletes an artifact: every change of feature set, profile,
# dependency, or toolchain starts a new <crate>-<hash> and orphans the
# old one, so a target tree only ever grows (12 GB of orphans in
# target/debug/deps by 2026-11-04). Cargo does, however, report every
# artifact a build used — fresh or rebuilt — via --message-format=json.
# This script reads one or more of those JSON streams, collects the
# metadata hashes they reference, and deletes every entry in deps/,
# build/, and .fingerprint/ whose hash is not referenced, in each
# profile directory the streams touched.
#
# Deleting something Cargo still wanted costs one rebuild of that unit,
# never a broken build — so a wrong guess here is slow, not fatal.
#
# Usage: gc-rust-target.sh <target-dir> <json-file>...
#   target-dir  the Cargo target directory (core/target)
#   json-file   stdout of a cargo build/test with
#               --message-format=json-render-diagnostics

TARGET_DIR="$1"; shift
[[ -d "$TARGET_DIR" ]] || exit 0
[[ $# -gt 0 ]] || { echo "gc-rust-target: no JSON inputs" >&2; exit 1; }

python3 -I - "$TARGET_DIR" "$@" <<'PY'
import json, os, re, shutil, sys

target = os.path.realpath(sys.argv[1])
HASH = re.compile(r'-([0-9a-f]{16})(?:\.|$)')

# profile root (e.g. target/debug, target/aarch64-apple-ios/release)
# -> set of referenced hashes
roots = {}

def note(path):
    path = os.path.realpath(path)
    if not path.startswith(target + os.sep):
        return
    rel = path[len(target) + 1:].split(os.sep)
    for i, part in enumerate(rel):
        if part in ("deps", "build", ".fingerprint") and i > 0:
            root = os.path.join(target, *rel[:i])
            seen = roots.setdefault(root, set())
            for comp in rel[i + 1:]:
                m = HASH.search(comp)
                if m:
                    seen.add(m.group(1))
            return

for src in sys.argv[2:]:
    with open(src) as f:
        for line in f:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            reason = msg.get("reason")
            if reason == "compiler-artifact":
                for p in msg.get("filenames", []):
                    note(p)
                if msg.get("executable"):
                    note(msg["executable"])
            elif reason == "build-script-executed":
                if msg.get("out_dir"):
                    note(msg["out_dir"])

removed = 0
freed = 0

def size(path):
    if os.path.isfile(path) and not os.path.islink(path):
        return os.path.getsize(path)
    total = 0
    for d, _, files in os.walk(path):
        for f in files:
            fp = os.path.join(d, f)
            if not os.path.islink(fp):
                try: total += os.path.getsize(fp)
                except OSError: pass
    return total

for root, seen in roots.items():
    for sub in ("deps", "build", ".fingerprint"):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            m = HASH.search(name)
            if not m or m.group(1) in seen:
                continue
            p = os.path.join(d, name)
            freed += size(p)
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p, ignore_errors=True)
            else:
                try: os.remove(p)
                except OSError: pass
            removed += 1

rel_roots = ", ".join(os.path.relpath(r, target) for r in sorted(roots)) or "none"
print(f"    gc: {removed} orphaned entries removed, {freed / 1e9:.2f} GB freed ({rel_roots})")
PY
