#!/bin/bash
# Host-run tests for pure (Foundation-only) AO3Kit files. Compiles each
# test with the files it covers and runs it; no simulator, no Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# Top-level test code must live in a file named main.swift.
cp packages/AO3Kit/Tests/AO3LinkTests.swift "$out/main.swift"
swiftc -O -o "$out/links" \
  packages/AO3Kit/Sources/Links/AO3Link.swift \
  "$out/main.swift"
"$out/links"
