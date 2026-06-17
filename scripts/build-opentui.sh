#!/usr/bin/env bash
# Build libopentui.so for Android aarch64
#
# Usage: ./scripts/build-opentui.sh
#
# OpenCode's TUI renderer (@opentui/core) uses a native Zig library.
# The upstream build targets aarch64-linux (musl), which fails on Android
# because getauxval cannot be resolved. We build for aarch64-linux-android.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZIG_BIN="${ZIG_BIN:-zig}"

# Pin opentui to the exact version that OpenCode depends on.
# This commit corresponds to @opentui/core v0.1.95 and builds for Android
# without patches (the v0.1.95 build.zig does not call linkLibC()).
OPENTUI_COMMIT="ebe288e0e2c85d3c7cbb44b1e3600beb68e100a2"

echo "=== Building libopentui.so for Android aarch64 ==="

# Clone opentui if needed
if [ ! -d "$OPENTUI_SRC/.git" ]; then
    echo ">>> Cloning opentui (commit $OPENTUI_COMMIT)..."
    git clone https://github.com/anomalyco/opentui.git "$OPENTUI_SRC"
    cd "$OPENTUI_SRC"
    git checkout "$OPENTUI_COMMIT"
else
    echo ">>> opentui source exists at $OPENTUI_SRC"
    # Ensure we are on the pinned commit
    cd "$OPENTUI_SRC"
    CURRENT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    if [ "$CURRENT" != "$OPENTUI_COMMIT" ]; then
        echo "    Resetting to pinned commit $OPENTUI_COMMIT (was $CURRENT)..."
        git fetch origin 2>/dev/null || true
        git checkout "$OPENTUI_COMMIT"
    fi
fi

# The v0.1.95 build.zig cross-compiles for aarch64-linux-android without
# patches because it does not call linkLibC() or other Zig features that
# trigger "unable to provide libc" on Android/Bionic.
# Keep the patch machinery commented out in case we need to re-pin later.
OPENTUI_PATCH="$REPO_ROOT/patches/opentui/android-libc-link.patch"
if [ -f "$OPENTUI_PATCH" ] && [ -n "${OPENTUI_FORCE_PATCH:-}" ]; then
    echo ">>> Applying opentui Android patch..."
    cd "$OPENTUI_SRC"
    if git apply --check "$OPENTUI_PATCH" 2>/dev/null; then
        git apply "$OPENTUI_PATCH"
        echo "    Patch applied successfully"
    else
        # Check if it was already applied (idempotent re-run)
        if git apply --check --reverse "$OPENTUI_PATCH" 2>/dev/null; then
            echo "    Patch already applied, skipping"
        else
            echo "ERROR: opentui Android patch does not apply cleanly to commit $OPENTUI_COMMIT"
            echo "       Regenerate patches/opentui/android-libc-link.patch against this commit."
            exit 1
        fi
    fi
else
    echo ">>> Skipping opentui Android patch (not needed for v0.1.95)"
fi

OPENTUI_ZIG_DIR="$OPENTUI_SRC/packages/core/src/zig"

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    exit 1
fi

echo ">>> Building with Zig (target: aarch64-linux-android)..."
cd "$OPENTUI_ZIG_DIR"

"$ZIG_BIN" build \
    -Dtarget=aarch64-linux-android \
    -Doptimize=ReleaseSafe \
    --prefix . 2>&1

# The build.zig installs to dest_dir="../lib/{output_name}" relative to
# the --prefix dir.  With --prefix=. (= OPENTUI_ZIG_DIR), the .so ends
# up one directory above: packages/core/src/lib/aarch64-linux-android/
LIBOPENTUI="$OPENTUI_ZIG_DIR/../lib/aarch64-linux-android/libopentui.so"
if [ ! -f "$LIBOPENTUI" ]; then
    echo "ERROR: libopentui.so not found"
    echo "  Expected at: $LIBOPENTUI"
    echo "  Searching for any libopentui.so under opentui-src..."
    find "$OPENTUI_SRC" -name "libopentui.so" -type f 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== libopentui.so build complete ==="
echo "Output: $LIBOPENTUI"
echo "Size: $(du -h "$LIBOPENTUI" | cut -f1)"
file "$LIBOPENTUI"

# Show dynamic section for debugging.  v0.1.95's libopentui.so has no
# NEEDED entries but loads correctly on Android/Bionic because all libc
# symbols are resolved at load time from the Bionic libc that is already
# mapped into every process.
echo ">>> Dynamic section of libopentui.so:"
readelf -d "$LIBOPENTUI" 2>/dev/null | grep -E "NEEDED|FLAGS|SONAME" || echo "    (no dynamic dependencies)"
