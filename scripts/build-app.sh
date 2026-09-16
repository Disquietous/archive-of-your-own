#!/bin/bash
set -euo pipefail

# Compile ONE app target (or both) to verify it builds. Never installs,
# launches, or signs anything.
#
# Usage: ./scripts/build-app.sh <mac|ios|both> [--rust] [--clean]
#
#   mac      build ArchiveOfYourOwnMac only
#   ios      build ArchiveOfYourOwn (iOS) only, against a generic arm64
#            simulator (the XCFramework carries no x86_64 slice)
#   both     build each in turn — use when porting a finished feature to
#            the other OS, not after every change
#   --rust   first rebuild the matching Rust slice(s) via build-rust.sh
#            (--release, and --mac-only / --ios-only / full accordingly)
#   --clean  pass `clean build` to xcodebuild instead of `build`
#
# The two app targets share packages/AO3Kit/Sources but are otherwise
# independent: building one never compiles the other. Shared-code changes
# made while working on one OS are only checked against the other when
# you ask for it (`both`, or the other OS's flag at port time).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$ROOT_DIR/ArchiveOfYourOwn.xcodeproj"

WHICH="${1:-}"
shift || true
RUST=0
ACTION="build"
for arg in "$@"; do
    case "$arg" in
        --rust) RUST=1 ;;
        --clean) ACTION="clean build" ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

case "$WHICH" in
    mac|ios|both) ;;
    *) echo "Usage: $0 <mac|ios|both> [--rust] [--clean]" >&2; exit 1 ;;
esac

if [[ $RUST == 1 ]]; then
    case "$WHICH" in
        mac)  "$SCRIPT_DIR/build-rust.sh" --release --mac-only ;;
        ios)  "$SCRIPT_DIR/build-rust.sh" --release --ios-only ;;
        both) "$SCRIPT_DIR/build-rust.sh" --release ;;
    esac
fi

# Per-developer signing team lives in the gitignored Local.xcconfig; a
# fresh clone gets the blank template so the project still generates.
if [[ ! -f "$ROOT_DIR/Local.xcconfig" ]]; then
    cp "$ROOT_DIR/Local.xcconfig.example" "$ROOT_DIR/Local.xcconfig"
fi

# The .xcodeproj is gitignored and regenerated from project.yml.
if [[ ! -d "$PROJECT" ]] || [[ "$ROOT_DIR/project.yml" -nt "$PROJECT/project.pbxproj" ]]; then
    echo "==> Generating Xcode project..."
    (cd "$ROOT_DIR" && xcodegen generate)
fi

build_one() {
    local scheme="$1" dest="$2"
    echo "==> Building $scheme ($dest)..."
    local t0=$SECONDS
    xcodebuild $ACTION \
        -project "$PROJECT" \
        -scheme "$scheme" \
        -destination "$dest" \
        -quiet \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGN_IDENTITY="" \
        DEVELOPMENT_TEAM="" \
        ARCHS=arm64
    echo "    [$(( SECONDS - t0 ))s] $scheme OK"
}

case "$WHICH" in
    mac)  build_one ArchiveOfYourOwnMac "platform=macOS,arch=arm64" ;;
    ios)  build_one ArchiveOfYourOwn "generic/platform=iOS Simulator" ;;
    both)
        build_one ArchiveOfYourOwnMac "platform=macOS,arch=arm64"
        build_one ArchiveOfYourOwn "generic/platform=iOS Simulator"
        ;;
esac
echo "==> Done."
