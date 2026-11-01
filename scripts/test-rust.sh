#!/bin/bash
set -euo pipefail

# Run the Rust core's tests. Always the same feature set, so test builds
# reuse one cache instead of starting a new one per flag combination.
#
# Usage: ./scripts/test-rust.sh [cargo test args...]   e.g. test_name

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

# Same values as build-rust.sh: the C dependencies' build scripts rerun
# when these change, so a mismatch rebuilds them on every switch between
# the two scripts.
export IPHONEOS_DEPLOYMENT_TARGET=18.0
export MACOSX_DEPLOYMENT_TARGET=14.0

"$SCRIPT_DIR/prune-rust-target.sh"
cd "$(dirname "$SCRIPT_DIR")/core"
cargo test --lib --no-default-features --features tor "$@"
