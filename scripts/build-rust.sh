#!/bin/bash
set -euo pipefail

# Build the Rust core library for iOS targets and generate Swift bindings.
# Usage: ./scripts/build-rust.sh [--release]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CORE_DIR="$ROOT_DIR/core"
GENERATED_DIR="$ROOT_DIR/ArchiveOfYourOwn/Generated"

PROFILE="debug"
PROFILE_FLAG=""
if [[ "${1:-}" == "--release" ]]; then
    PROFILE="release"
    PROFILE_FLAG="--release"
fi

echo "==> Building Rust core ($PROFILE)..."

cd "$CORE_DIR"

# Ensure targets are available
rustup target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

# Build for device and simulator
echo "  Building for iOS device (aarch64-apple-ios)..."
cargo build --target aarch64-apple-ios $PROFILE_FLAG --no-default-features

echo "  Building for iOS simulator (aarch64-apple-ios-sim)..."
cargo build --target aarch64-apple-ios-sim $PROFILE_FLAG --no-default-features

# Generate Swift bindings
echo "==> Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"

cargo run --bin uniffi-bindgen generate \
    --library "target/aarch64-apple-ios-sim/$PROFILE/libao3_core.a" \
    --language swift \
    --out-dir "$GENERATED_DIR" 2>/dev/null || {
    # If the bindgen binary doesn't exist, use cargo-uniffi
    cargo install uniffi-bindgen-cli 2>/dev/null || true
    uniffi-bindgen generate \
        --library "target/aarch64-apple-ios-sim/$PROFILE/libao3_core.a" \
        --language swift \
        --out-dir "$GENERATED_DIR"
}

# Create XCFramework
echo "==> Creating XCFramework..."
FRAMEWORK_DIR="$ROOT_DIR/AO3Core.xcframework"
rm -rf "$FRAMEWORK_DIR"

DEVICE_LIB="target/aarch64-apple-ios/$PROFILE/libao3_core.a"
SIM_LIB="target/aarch64-apple-ios-sim/$PROFILE/libao3_core.a"

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
        -output "$FRAMEWORK_DIR"

    rm -rf "$HEADERS_DIR"
else
    xcodebuild -create-xcframework \
        -library "$DEVICE_LIB" \
        -library "$SIM_LIB" \
        -output "$FRAMEWORK_DIR"
fi

echo "==> Done!"
echo "  XCFramework: $FRAMEWORK_DIR"
echo "  Swift bindings: $GENERATED_DIR"
echo ""
echo "  Add the XCFramework to your Xcode project and"
echo "  import the generated Swift file."
