#!/bin/bash
set -euo pipefail

# Prune core/target of build leftovers nothing reads. Cargo never
# garbage-collects target/:
#   - .rcgu.o files in deps/: per-codegen-unit objects that held debug
#     info. Dev builds have no debug info (Cargo.toml) and release builds
#     delete their own after linking, so every one left there is dead.
#   - incremental caches: every change to a build configuration (feature
#     set, profile, dependency bump, rustc update) starts a new
#     <crate>-<hash> directory and orphans the old one. At most two
#     configurations per crate are live in any one incremental directory
#     (ao3_core's test build and its library build), so the two most
#     recently used are kept and the rest deleted.
# Never touches dependency artifacts or target/release's host-side tools
# (deleting those slows every build). Run before a build, never alongside
# one.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$(dirname "$SCRIPT_DIR")/core/target"
KEEP=2

[[ -d "$TARGET_DIR" ]] || exit 0

# Only the leftovers in deps/ — the incremental session directories keep
# their own .rcgu.o files as cached codegen, and deleting those forces a
# full recompile every build.
find "$TARGET_DIR" -type f -path '*/deps/*.rcgu.o' -delete

while IFS= read -r inc; do
    # Crate names in this incremental directory, newest-first per crate.
    for crate in $(ls "$inc" | sed -E 's/-[^-]+$//' | sort -u); do
        ls -dt "$inc/$crate"-* 2>/dev/null | tail -n +$((KEEP + 1)) | while IFS= read -r dir; do
            rm -rf "$dir"
        done
    done
done < <(find "$TARGET_DIR" -maxdepth 3 -type d -name incremental)
