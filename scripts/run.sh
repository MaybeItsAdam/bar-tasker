#!/bin/bash

# Configuration
SCHEME="Bar Tasker"
CONFIG="Debug"
BUILD_DIR="$(pwd)/build"

echo "🚀 Building $SCHEME..."

# Build - Using -quiet to keep it clean since xcpretty is missing
xcodebuild build \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -quiet \
    SYMROOT="$BUILD_DIR"

# Check if build succeeded
if [ $? -eq 0 ]; then
    echo "✅ Build Succeeded. Locating binary..."

    # Dynamically find the binary to avoid path mismatches
    # This looks for the executable inside the .app bundle
    BINARY_PATH=$(find "$BUILD_DIR" -name "Bar Tasker" -type f -perm +111 | head -n 1)

    if [ -z "$BINARY_PATH" ]; then
        echo "❌ Error: Could not find binary in $BUILD_DIR"
        exit 1
    fi

    echo "Running: $BINARY_PATH"

    # Kill existing instance if running
    killall "$SCHEME" 2>/dev/null

    # Run it!
    "$BINARY_PATH"
else
    echo "❌ Build Failed."
    exit 1
fi
