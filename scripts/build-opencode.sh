#!/usr/bin/env bash
# Build OpenCode standalone binary for Android aarch64
#
# Usage: ./scripts/build-opencode.sh
#
# This script:
# 1. Clones OpenCode if needed
# 2. Swaps x86_64 libopentui.so with ARM64 version
# 3. Runs the TypeScript build script to create the standalone binary
# 4. Restores original libopentui.so
#
# Requires:
# - Android Bun binary built (scripts/build-bun.sh)
# - libopentui.so built (scripts/build-opentui.sh)
# - Host Bun installed (for bundling)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

HOST_BUN="${HOST_BUN:-bun}"

echo "=== Building OpenCode v${OPENCODE_VERSION} for Android aarch64 ==="

# Clone OpenCode if needed
if [ ! -d "$OPENCODE_SRC/.git" ]; then
    echo ">>> Cloning OpenCode..."
    git clone --depth 1 --branch "v${OPENCODE_VERSION}" https://github.com/anomalyco/opencode.git "$OPENCODE_SRC"
else
    echo ">>> OpenCode source exists at $OPENCODE_SRC"
fi

OPENCODE_PKG="$OPENCODE_SRC/packages/opencode"

# Install OpenCode dependencies
echo ">>> Installing OpenCode dependencies..."
cd "$OPENCODE_SRC"
"$HOST_BUN" install

# Install all platform variants of @opentui/core so Bun.build can resolve
# every dynamic import in the chunk (darwin/win32/linux x64+arm64, musl).
echo ">>> Installing @opentui/core platform variants (universal)..."
"$HOST_BUN" install --os="*" --cpu="*" @opentui/core@0.4.5

# =============================================
# Termux overlay fixes (opencode-termux local patches)
# 1. global.ts: Termux tmp dir ($PREFIX/tmp instead of /tmp)
# 2. @opentui/core chunk: null-guard + fallback for bundled asset
#    resolution (fixes "loadedPath.startsWith" TypeError on Android)
# =============================================
echo ">>> Applying Termux overlay: global tmp fix..."
patch -d "$OPENCODE_SRC" -p1 < "$REPO_ROOT/patches/opencode/global-tmp-termux.diff"

echo ">>> Injecting patched @opentui/core chunk..."
CHUNK_NAME="chunk-bun-t2myhmwd.js"
OVERLAY_CHUNK="$REPO_ROOT/patches/opencode/$CHUNK_NAME"
if [ ! -f "$OVERLAY_CHUNK" ]; then
    echo "ERROR: overlay chunk not found at $OVERLAY_CHUNK"
    exit 1
fi
INJECTED=0
while IFS= read -r -d '' f; do
    cp "$OVERLAY_CHUNK" "$f"
    grep -q "OpenTUI-TERMUX-PATCH" "$f" || { echo "ERROR: injection verify failed for $f"; exit 1; }
    INJECTED=$((INJECTED + 1))
done < <(find "$OPENCODE_SRC/node_modules" -type f -name "$CHUNK_NAME" -print0)
if [ "$INJECTED" -eq 0 ]; then
    echo "ERROR: $CHUNK_NAME not found in opencode node_modules"
    exit 1
fi
echo "    Injected patched chunk into $INJECTED location(s)"

# Find the Android bun binary
ANDROID_BUN="$BUN_BUILD/bun"
if [ ! -f "$ANDROID_BUN" ]; then
    echo "ERROR: Android bun binary not found at $ANDROID_BUN"
    echo "       Run scripts/build-bun.sh first."
    exit 1
fi

# Find ARM64 libopentui.so
# build.zig installs to ../lib/{target} relative to the zig dir
ARM64_LIBOPENTUI="$OPENTUI_SRC/packages/core/src/lib/aarch64-linux-android/libopentui.so"
if [ ! -f "$ARM64_LIBOPENTUI" ]; then
    echo "ERROR: ARM64 libopentui.so not found at $ARM64_LIBOPENTUI"
    echo "       Run scripts/build-opentui.sh first."
    exit 1
fi

# Find x86_64 libopentui.so in node_modules and swap it
# OpenCode uses @opentui/core-linux-x64 which has the x86_64 version
OPENTUI_NODE_MODULE=""
for candidate in \
    "$OPENCODE_SRC/node_modules/@opentui/core-linux-x64/libopentui.so" \
    "$OPENCODE_PKG/node_modules/@opentui/core-linux-x64/libopentui.so" \
    "$OPENCODE_SRC/node_modules/.bun/@opentui+core-linux-x64@*/node_modules/@opentui/core-linux-x64/libopentui.so"
do
    # Handle glob
    for f in $candidate; do
        if [ -f "$f" ]; then
            OPENTUI_NODE_MODULE="$f"
            break 2
        fi
    done
done

BACKUP_FILE=""
if [ -n "$OPENTUI_NODE_MODULE" ]; then
    echo ">>> Swapping x86_64 libopentui.so with ARM64 version..."
    BACKUP_FILE="${OPENTUI_NODE_MODULE}.x64.bak"
    cp "$OPENTUI_NODE_MODULE" "$BACKUP_FILE"
    cp "$ARM64_LIBOPENTUI" "$OPENTUI_NODE_MODULE"
    echo "    Backed up to $BACKUP_FILE"
else
    echo "WARNING: Could not find x86_64 libopentui.so in node_modules"
    echo "         The build may embed the wrong architecture"
fi

# Also swap the android .so into the linux-arm64 package: at runtime the
# (linux-spoofed) Android bun resolves @opentui/core-linux-arm64, so the
# embedded library must be the bionic aarch64 build, not glibc.
echo ">>> Swapping ARM64 libopentui.so into @opentui/core-linux-arm64..."
ARM64_SWAPPED=0
for f in "$OPENCODE_SRC"/node_modules/.bun/@opentui+core-linux-arm64@*/node_modules/@opentui/core-linux-arm64/libopentui.so; do
    if [ -f "$f" ]; then
        cp "$f" "${f}.glibc.bak"
        cp "$ARM64_LIBOPENTUI" "$f"
        ARM64_SWAPPED=$((ARM64_SWAPPED + 1))
    fi
done
if [ "$ARM64_SWAPPED" -eq 0 ]; then
    echo "ERROR: @opentui/core-linux-arm64/libopentui.so not found for swap"
    exit 1
fi
echo "    Swapped $ARM64_SWAPPED location(s)"

# Create dist directory
mkdir -p "$DIST_DIR"

# Run the TypeScript build script
# Copy it into the OpenCode tree so Bun can resolve @opentui/solid/bun-plugin
# from node_modules (Bun resolves bare imports relative to the script file's location)
echo ">>> Building OpenCode standalone binary..."
BUILD_SCRIPT="$REPO_ROOT/scripts/build-opencode-android.ts"
BUILD_SCRIPT_LOCAL="$OPENCODE_PKG/build-opencode-android.ts"
cp "$BUILD_SCRIPT" "$BUILD_SCRIPT_LOCAL"
cd "$OPENCODE_PKG"

OPENCODE_VERSION="$OPENCODE_VERSION" \
    ANDROID_BUN="$ANDROID_BUN" \
    OUTPUT_DIR="$DIST_DIR" \
    OPENCODE_DIR="$OPENCODE_PKG" \
    "$HOST_BUN" run "$BUILD_SCRIPT_LOCAL"

# Clean up copied script
rm -f "$BUILD_SCRIPT_LOCAL"

# Restore original libopentui.so
if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    echo ">>> Restoring original x86_64 libopentui.so..."
    mv "$BACKUP_FILE" "$OPENTUI_NODE_MODULE"
fi

# Verify output
OPENCODE_BINARY="$DIST_DIR/opencode"
if [ ! -f "$OPENCODE_BINARY" ]; then
    echo "ERROR: OpenCode binary not found at $OPENCODE_BINARY"
    exit 1
fi

echo ""
echo "=== OpenCode build complete ==="
echo "Binary: $OPENCODE_BINARY"
echo "Size: $(du -h "$OPENCODE_BINARY" | cut -f1)"
file "$OPENCODE_BINARY"
