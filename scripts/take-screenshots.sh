#!/bin/bash
set -euo pipefail

# Screenshot automation for Archive of Your Own
#
# Usage:
#   ./scripts/take-screenshots.sh
#   ./scripts/take-screenshots.sh --device "iPhone 16 Pro"
#   ./scripts/take-screenshots.sh --output my-screenshots/
#   ./scripts/take-screenshots.sh --skip-build

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

DEVICE="iPhone 17 Pro"
OUTPUT_DIR="$PROJECT_DIR/screenshots"
BUNDLE_ID="com.archiveofyourown.reader"
SKIP_BUILD=false
TIMEOUT=300  # seconds to wait for all screenshots

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --device NAME    Simulator device (default: iPhone 17 Pro)"
            echo "  --output DIR     Output directory (default: screenshots/)"
            echo "  --skip-build     Skip xcodebuild, use existing build"
            echo "  --timeout SEC    Max seconds to wait (default: 300)"
            echo "  -h, --help       Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

DERIVED_DATA="$PROJECT_DIR/.build/screenshots"
SAFE_DEVICE_NAME="$(echo "$DEVICE" | tr ' ' '-' | tr -cd '[:alnum:]-')"

echo "=== Screenshot Generator ==="
echo "Device:  $DEVICE"
echo "Output:  $OUTPUT_DIR"
echo ""

# ── Simulator Setup (before build, so we can target by UDID) ───────────

# Find the UDID for the requested device. Prefer the latest runtime.
DEVICE_UDID="$(xcrun simctl list devices available -j \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
matches = []
for runtime, devices in data['devices'].items():
    for d in devices:
        if d['name'] == '$DEVICE' and d['isAvailable']:
            matches.append((runtime, d['udid'], d['state']))
if not matches:
    sys.exit(1)
# Sort by runtime descending (latest first), prefer already-booted
matches.sort(key=lambda m: (m[2] == 'Booted', m[0]), reverse=True)
print(matches[0][1])
" 2>/dev/null || true)"

if [ -z "$DEVICE_UDID" ]; then
    echo "ERROR: Simulator '$DEVICE' not found. Available devices:"
    xcrun simctl list devices available | grep -v "^--" | grep -v "^$" | head -25
    exit 1
fi

echo "Using simulator: $DEVICE ($DEVICE_UDID)"

# ── Build ──────────────────────────────────────────────────────────────

if [ "$SKIP_BUILD" = false ]; then
    echo "Building for simulator..."
    if ! xcodebuild build \
        -project "$PROJECT_DIR/ArchiveOfYourOwn.xcodeproj" \
        -scheme ArchiveOfYourOwn \
        -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
        -derivedDataPath "$DERIVED_DATA" \
        -quiet 2>&1; then
        echo ""
        echo "ERROR: Build failed."
        exit 1
    fi
    echo "Build complete."
else
    echo "Skipping build (--skip-build)."
fi

APP_PATH="$(find "$DERIVED_DATA" -name "ArchiveOfYourOwn.app" -path "*iphonesimulator*" | head -1)"
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find built .app bundle in $DERIVED_DATA"
    exit 1
fi

# Boot if needed
DEVICE_STATE="$(xcrun simctl list devices -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    for d in devices:
        if d['udid'] == '$DEVICE_UDID':
            print(d['state']); sys.exit()
")"

if [ "$DEVICE_STATE" != "Booted" ]; then
    echo "Booting simulator..."
    xcrun simctl boot "$DEVICE_UDID"
    sleep 3
fi

# Clean status bar for professional screenshots
echo "Setting clean status bar..."
xcrun simctl status_bar "$DEVICE_UDID" override \
    --time "9:41" \
    --batteryState charged \
    --batteryLevel 100 \
    --cellularMode active \
    --cellularBars 4 \
    --operatorName "" \
    --wifiBars 3 \
    --dataNetwork "wifi" 2>/dev/null || true

# ── Install & Launch ───────────────────────────────────────────────────

echo "Installing app..."
xcrun simctl install "$DEVICE_UDID" "$APP_PATH"

# Terminate if already running
xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "Launching in screenshot mode..."
xcrun simctl launch "$DEVICE_UDID" "$BUNDLE_ID" -screenshots

# Find the data container
sleep 2
DATA_CONTAINER="$(xcrun simctl get_app_container "$DEVICE_UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
if [ -z "$DATA_CONTAINER" ]; then
    echo "ERROR: Could not find app data container"
    exit 1
fi

SIGNAL_DIR="$DATA_CONTAINER/Documents/screenshots"
echo "Watching: $SIGNAL_DIR"

# ── Capture Loop ───────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR/$SAFE_DEVICE_NAME"

CAPTURED=0
STARTED=$(date +%s)

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - STARTED))
    if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
        echo "ERROR: Timed out after ${TIMEOUT}s"
        break
    fi

    # Check for done signal
    if [ -f "$SIGNAL_DIR/done.signal" ]; then
        echo ""
        echo "All scenes captured."
        rm -f "$SIGNAL_DIR/done.signal"
        break
    fi

    # Look for ready signals
    for signal in "$SIGNAL_DIR"/ready_*.signal; do
        [ -f "$signal" ] || continue

        BASENAME="$(basename "$signal" .signal)"
        SCENE_NAME="${BASENAME#ready_}"

        OUTFILE="$OUTPUT_DIR/$SAFE_DEVICE_NAME/${SCENE_NAME}.png"
        echo "  Capturing: $SCENE_NAME"

        xcrun simctl io "$DEVICE_UDID" screenshot "$OUTFILE" 2>/dev/null

        rm -f "$signal"
        CAPTURED=$((CAPTURED + 1))
    done

    sleep 0.3
done

# ── Cleanup ────────────────────────────────────────────────────────────

echo "Restoring status bar..."
xcrun simctl status_bar "$DEVICE_UDID" clear 2>/dev/null || true

xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID" 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "Captured $CAPTURED screenshots in: $OUTPUT_DIR/$SAFE_DEVICE_NAME/"
ls -1 "$OUTPUT_DIR/$SAFE_DEVICE_NAME/" 2>/dev/null | sed 's/^/  /'
