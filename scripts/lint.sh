#!/bin/bash
# Lint the Rust core (clippy, warnings are errors) and the Swift apps
# (SwiftLint, config in .swiftlint.yml). Exits non-zero on any finding.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
echo "==> clippy"
(cd core && cargo clippy --all-targets --features tor -- -D warnings) || status=1
echo "==> swiftlint"
swiftlint lint --quiet --strict || status=1
exit $status
