#!/bin/bash
set -euo pipefail

# Build the Rust core library and generate Swift bindings.
# Usage: ./scripts/build-rust.sh [--release] [--mac-only]
#
# --mac-only builds just the macOS slice (the everyday loop while testing
# the Mac app) and repackages the XCFramework with the existing iOS libs —
# those go stale until the next full run, so do a full build before iOS
# work. Bindings are regenerated either way, from whichever library was
# just built.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Ensure cargo is on PATH
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
CORE_DIR="$ROOT_DIR/core"
GENERATED_DIR="$ROOT_DIR/packages/AO3Kit/Sources/Generated"

PROFILE="debug"
PROFILE_FLAG=""
MAC_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --release)
            PROFILE="release"
            PROFILE_FLAG="--release"
            ;;
        --mac-only)
            MAC_ONLY=1
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

PHASE_T0=$SECONDS
phase() {
    echo "    [$(( SECONDS - PHASE_T0 ))s] $1"
    PHASE_T0=$SECONDS
}

echo "==> Building Rust core ($PROFILE$( [[ $MAC_ONLY == 1 ]] && echo ", macOS only" ))..."

cd "$CORE_DIR"

# Ensure targets are available
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin 2>/dev/null || true

# Set deployment targets to match project.yml so the linker doesn't warn
# about objects built for a newer OS than the app targets.
export IPHONEOS_DEPLOYMENT_TARGET=18.0
export MACOSX_DEPLOYMENT_TARGET=14.0

# --lib: the crate also declares the uniffi-bindgen helper binary, and a
# plain `cargo build` compiled that binary (and its dependency tree) once
# per cross target — code that can never run there. Only the static
# library is wanted for the app targets.
DEVICE_LIB="target/aarch64-apple-ios/$PROFILE/libao3_core.a"
SIM_LIB="target/aarch64-apple-ios-sim/$PROFILE/libao3_core.a"
MACOS_LIB="target/aarch64-apple-darwin/$PROFILE/libao3_core.a"

if [[ $MAC_ONLY == 0 ]]; then
    echo "  Building for iOS device (aarch64-apple-ios)..."
    cargo build --lib --target aarch64-apple-ios $PROFILE_FLAG --no-default-features --features tor

    echo "  Building for iOS simulator (aarch64-apple-ios-sim)..."
    cargo build --lib --target aarch64-apple-ios-sim $PROFILE_FLAG --no-default-features --features tor
fi

echo "  Building for macOS (aarch64-apple-darwin)..."
PHASE_T0=$SECONDS
cargo build --lib --target aarch64-apple-darwin $PROFILE_FLAG --no-default-features --features tor
phase "macOS compile done"

if [[ $MAC_ONLY == 1 ]]; then
    for lib in "$DEVICE_LIB" "$SIM_LIB"; do
        if [[ ! -f "$lib" ]]; then
            echo "!! $lib missing — run a full build (no --mac-only) first." >&2
            exit 1
        fi
    done
    echo "  (reusing existing iOS libs — stale until the next full build)"
fi

# Cargo never garbage-collects target/, and stray debug invocations with
# --target quietly leave multi-GB artifact trees nothing ever reads —
# sweep those. target/release MUST survive: with --target, cargo puts the
# HOST-side artifacts there (proc-macros, build-script binaries), and
# deleting it forced a ~40s host-side recompile into every subsequent
# build (measured 2026-08-14 — this sweep was the whole mystery of the
# slow build loop).
echo "==> Sweeping unused build trees..."
for triple in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
    rm -rf "target/$triple/debug"
done

# Generate Swift bindings — from the macOS library, which is always fresh
# (the API surface is identical across targets).
echo "==> Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"

cargo run --bin uniffi-bindgen --features bindgen-cli generate \
    --library "$MACOS_LIB" \
    --language swift \
    --out-dir "$GENERATED_DIR" 2>/dev/null || {
    # If the bindgen binary doesn't exist, use cargo-uniffi
    cargo install uniffi-bindgen-cli 2>/dev/null || true
    uniffi-bindgen generate \
        --library "$MACOS_LIB" \
        --language swift \
        --out-dir "$GENERATED_DIR"
}
phase "bindgen done"

# Create XCFramework
echo "==> Creating XCFramework..."
FRAMEWORK_DIR="$ROOT_DIR/AO3Core.xcframework"
rm -rf "$FRAMEWORK_DIR"

# Find the generated header (uniffi generates a modulemap + header)
HEADER_FILE="$GENERATED_DIR/ao3_coreFFI.h"
MODULE_FILE="$GENERATED_DIR/ao3_coreFFI.modulemap"

if [[ -f "$HEADER_FILE" ]]; then
    # Create temporary directories for headers
    HEADERS_DIR="$(mktemp -d)"
    mkdir -p "$HEADERS_DIR"
    cp "$HEADER_FILE" "$HEADERS_DIR/"
    cp "$MODULE_FILE" "$HEADERS_DIR/module.modulemap" 2>/dev/null || true

    xcodebuild -create-xcframework \
        -library "$DEVICE_LIB" -headers "$HEADERS_DIR" \
        -library "$SIM_LIB" -headers "$HEADERS_DIR" \
        -library "$MACOS_LIB" -headers "$HEADERS_DIR" \
        -output "$FRAMEWORK_DIR"

    rm -rf "$HEADERS_DIR"
else
    xcodebuild -create-xcframework \
        -library "$DEVICE_LIB" \
        -library "$SIM_LIB" \
        -library "$MACOS_LIB" \
        -output "$FRAMEWORK_DIR"
fi

phase "xcframework done"
echo "==> Done!"
echo "  XCFramework: $FRAMEWORK_DIR"
echo "  Swift bindings: $GENERATED_DIR"
