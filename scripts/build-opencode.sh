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

# Find all @opentui/core-linux-x64 package directories under node_modules.
# We must patch every occurrence because Bun's module resolver can pick up
# the package from multiple hoisted locations, and the .so inside each one
# must be ARM64 and must load from a real filesystem path on Android
# (Bun's /$bunfs/root/ virtual paths are not reliably intercepted on Android).
OPENTUI_PACKAGES=()
while IFS= read -r -d '' pkg_dir; do
    OPENTUI_PACKAGES+=("$pkg_dir")
done < <(find "$OPENCODE_SRC" -path '*/node_modules/@opentui/core-linux-x64' -type d -print0 2>/dev/null || true)

if [ ${#OPENTUI_PACKAGES[@]} -eq 0 ]; then
    echo "ERROR: Could not find @opentui/core-linux-x64 in node_modules"
    echo "       The build will embed the wrong architecture"
    exit 1
fi

# Backup list: "so_path:backup_path index_path:backup_path ..."
OPENTUI_BACKUPS=()

echo ">>> Patching @opentui/core-linux-x64 packages for Android aarch64..."
for pkg_dir in "${OPENTUI_PACKAGES[@]}"; do
    so_file="$pkg_dir/libopentui.so"
    idx_file=""
    if [ -f "$pkg_dir/index.js" ]; then
        idx_file="$pkg_dir/index.js"
    elif [ -f "$pkg_dir/index.ts" ]; then
        idx_file="$pkg_dir/index.ts"
    fi

    if [ ! -f "$so_file" ]; then
        echo "WARNING: $so_file not found, skipping $pkg_dir"
        continue
    fi

    # Backup and swap the .so
    so_backup="${so_file}.x64.bak"
    cp "$so_file" "$so_backup"
    cp "$ARM64_LIBOPENTUI" "$so_file"
    OPENTUI_BACKUPS+=("$so_file:$so_backup")
    echo "    Swapped $so_file"

    # Patch the index file to load from filesystem on Android.
    # Bun's /$bunfs/root/ virtual path works on desktop Linux but is not
    # intercepted by the Android runtime, so the dlopen/openat fails with ENOENT.
    # We fall back to a real Termux filesystem path via OPENTUI_LIB_PATH.
    if [ -n "$idx_file" ]; then
        idx_backup="${idx_file}.bak"
        cp "$idx_file" "$idx_backup"
        cat > "$idx_file" <<'IDXEOF'
module.exports = process.env.OPENTUI_LIB_PATH || "/data/data/com.termux/files/usr/lib/libopentui.so";
IDXEOF
        OPENTUI_BACKUPS+=("$idx_file:$idx_backup")
        echo "    Patched $idx_file"
    fi
done

# Also stage libopentui.so into dist so make-packages.sh can ship it
mkdir -p "$DIST_DIR"
cp "$ARM64_LIBOPENTUI" "$DIST_DIR/libopentui.so"
echo ">>> Staged ARM64 libopentui.so for packaging"

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

# Restore original @opentui/core-linux-x64 files
if [ ${#OPENTUI_BACKUPS[@]} -gt 0 ]; then
    echo ">>> Restoring original @opentui/core-linux-x64 files..."
    for backup_spec in "${OPENTUI_BACKUPS[@]}"; do
        orig="${backup_spec%%:*}"
        backup="${backup_spec##*:}"
        if [ -f "$backup" ]; then
            mv "$backup" "$orig"
        fi
    done
fi

# ============================================================
# Optional: build opencode-debug using bun-profile (unstripped)
# ============================================================
# bun-profile keeps DWARF symbols so Zig's panic handler prints
# file:line stack traces. Non-fatal: skip gracefully if absent.
ANDROID_DEBUG_BUN="$BUN_BUILD/bun-profile"
if [ -f "$ANDROID_DEBUG_BUN" ]; then
    echo ""
    echo ">>> Building OpenCode debug variant (bun-profile, unstripped)..."
    DEBUG_OUTPUT_DIR="$DIST_DIR/.debug-tmp"
    DEBUG_BINARY="$DIST_DIR/opencode-debug"

    # Re-patch @opentui/core-linux-x64 for the second build pass
    DEBUG_OPENTUI_BACKUPS=()
    for pkg_dir in "${OPENTUI_PACKAGES[@]}"; do
        so_file="$pkg_dir/libopentui.so"
        idx_file=""
        if [ -f "$pkg_dir/index.js" ]; then
            idx_file="$pkg_dir/index.js"
        elif [ -f "$pkg_dir/index.ts" ]; then
            idx_file="$pkg_dir/index.ts"
        fi
        if [ -f "$so_file" ]; then
            debug_backup="${so_file}.x64.debug-bak"
            cp "$so_file" "$debug_backup"
            cp "$ARM64_LIBOPENTUI" "$so_file"
            DEBUG_OPENTUI_BACKUPS+=("$so_file:$debug_backup")
        fi
        if [ -n "$idx_file" ] && [ -f "$idx_file" ]; then
            debug_idx_backup="${idx_file}.debug-bak"
            cp "$idx_file" "$debug_idx_backup"
            cat > "$idx_file" <<'IDXEOF'
module.exports = process.env.OPENTUI_LIB_PATH || "/data/data/com.termux/files/usr/lib/libopentui.so";
IDXEOF
            DEBUG_OPENTUI_BACKUPS+=("$idx_file:$debug_idx_backup")
        fi
    done

    cp "$BUILD_SCRIPT" "$BUILD_SCRIPT_LOCAL"
    cd "$OPENCODE_PKG"
    OPENCODE_VERSION="$OPENCODE_VERSION" \
        ANDROID_BUN="$ANDROID_DEBUG_BUN" \
        OUTPUT_DIR="$DEBUG_OUTPUT_DIR" \
        OPENCODE_DIR="$OPENCODE_PKG" \
        "$HOST_BUN" run "$BUILD_SCRIPT_LOCAL" && \
        mv "$DEBUG_OUTPUT_DIR/opencode" "$DEBUG_BINARY" && \
        echo "    Debug binary: $DEBUG_BINARY ($(du -h "$DEBUG_BINARY" | cut -f1))" || \
        echo "    WARNING: Debug variant build failed, skipping"

    rm -f "$BUILD_SCRIPT_LOCAL"
    rm -rf "$DEBUG_OUTPUT_DIR"

    # Restore @opentui/core-linux-x64 files after debug build
    if [ ${#DEBUG_OPENTUI_BACKUPS[@]} -gt 0 ]; then
        echo ">>> Restoring @opentui/core-linux-x64 files after debug build..."
        for backup_spec in "${DEBUG_OPENTUI_BACKUPS[@]}"; do
            orig="${backup_spec%%:*}"
            backup="${backup_spec##*:}"
            if [ -f "$backup" ]; then
                mv "$backup" "$orig"
            fi
        done
    fi
else
    echo ">>> bun-profile not found, skipping debug variant"
    echo "    (run 'ninja bun-profile' in the bun-build dir to enable it)"
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
