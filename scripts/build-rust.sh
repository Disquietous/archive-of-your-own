#!/bin/bash
set -euo pipefail

# Build the Rust core library and generate Swift bindings.
# Usage: ./scripts/build-rust.sh [--release] [--mac-only | --ios-only | --sim-only]
#
# Slice selection — pick the one matching the OS you are working on:
#   (none)      all three slices (iOS device, iOS simulator, macOS)
#   --mac-only  macOS slice only         (everyday loop for the Mac app)
#   --ios-only  iOS device + simulator   (everyday loop for the iOS app)
#   --sim-only  iOS simulator only       (fastest iOS loop; no device runs)
#   --device-only  iOS device only       (testing on a real iPhone/iPad)
# Slices that are not rebuilt are reused from the previous build and go
# stale until the next run that includes them — run the matching flag (or a
# full build) before switching to the other OS. Bindings are regenerated
# either way, from whichever library was just built (the API surface is
# identical across targets).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Ensure cargo is on PATH
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
CORE_DIR="$ROOT_DIR/core"
GENERATED_DIR="$ROOT_DIR/packages/AO3Kit/Sources/Generated"

PROFILE="debug"
PROFILE_FLAG=""
# Which slices to build (1 = build, 0 = reuse the existing lib).
BUILD_DEVICE=1
BUILD_SIM=1
BUILD_MAC=1
SLICE_LABEL=""
for arg in "$@"; do
    case "$arg" in
        --release)
            PROFILE="release"
            PROFILE_FLAG="--release"
            ;;
        --mac-only)
            BUILD_DEVICE=0; BUILD_SIM=0; BUILD_MAC=1; SLICE_LABEL="macOS only"
            ;;
        --ios-only)
            BUILD_DEVICE=1; BUILD_SIM=1; BUILD_MAC=0; SLICE_LABEL="iOS only"
            ;;
        --sim-only)
            BUILD_DEVICE=0; BUILD_SIM=1; BUILD_MAC=0; SLICE_LABEL="iOS simulator only"
            ;;
        --device-only)
            BUILD_DEVICE=1; BUILD_SIM=0; BUILD_MAC=0; SLICE_LABEL="iOS device only"
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

echo "==> Building Rust core ($PROFILE${SLICE_LABEL:+, $SLICE_LABEL})..."

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

# The library the bindgen step reads; set to whichever slice was built last.
BINDGEN_LIB=""

if [[ $BUILD_DEVICE == 1 ]]; then
    echo "  Building for iOS device (aarch64-apple-ios)..."
    PHASE_T0=$SECONDS
    cargo build --lib --target aarch64-apple-ios $PROFILE_FLAG --no-default-features --features tor
    phase "iOS device compile done"
    BINDGEN_LIB="$DEVICE_LIB"
fi

if [[ $BUILD_SIM == 1 ]]; then
    echo "  Building for iOS simulator (aarch64-apple-ios-sim)..."
    PHASE_T0=$SECONDS
    cargo build --lib --target aarch64-apple-ios-sim $PROFILE_FLAG --no-default-features --features tor
    phase "iOS simulator compile done"
    BINDGEN_LIB="$SIM_LIB"
fi

if [[ $BUILD_MAC == 1 ]]; then
    echo "  Building for macOS (aarch64-apple-darwin)..."
    PHASE_T0=$SECONDS
    cargo build --lib --target aarch64-apple-darwin $PROFILE_FLAG --no-default-features --features tor
    phase "macOS compile done"
    BINDGEN_LIB="$MACOS_LIB"
fi

# Slices that were skipped must already exist so the XCFramework can be
# repackaged; they are stale until a run that includes them.
REUSED=()
[[ $BUILD_DEVICE == 0 ]] && REUSED+=("$DEVICE_LIB")
[[ $BUILD_SIM == 0 ]] && REUSED+=("$SIM_LIB")
[[ $BUILD_MAC == 0 ]] && REUSED+=("$MACOS_LIB")
# `${arr[@]+"${arr[@]}"}`: an empty array trips `set -u` on bash < 4.4
# (the full build reuses nothing), so expand it only when it has entries.
for lib in ${REUSED[@]+"${REUSED[@]}"}; do
    if [[ ! -f "$lib" ]]; then
        echo "!! $lib missing — run a full build (no slice flag) first." >&2
        exit 1
    fi
done
if [[ ${#REUSED[@]} -gt 0 ]]; then
    echo "  (reusing ${#REUSED[@]} existing slice(s) — stale until the next build that includes them)"
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

# Generate Swift bindings — from whichever library was just built (the API
# surface is identical across targets, so any fresh slice will do).
echo "==> Generating Swift bindings (from $BINDGEN_LIB)..."
mkdir -p "$GENERATED_DIR"

cargo run --bin uniffi-bindgen --features bindgen-cli generate \
    --library "$BINDGEN_LIB" \
    --language swift \
    --out-dir "$GENERATED_DIR" 2>/dev/null || {
    # If the bindgen binary doesn't exist, use cargo-uniffi
    cargo install uniffi-bindgen-cli 2>/dev/null || true
    uniffi-bindgen generate \
        --library "$BINDGEN_LIB" \
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
