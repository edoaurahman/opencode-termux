#!/usr/bin/env bash
# Create distribution packages for OpenCode Android
#
# Usage: ./scripts/make-packages.sh
#
# Creates three package formats:
# 1. ZIP: opencode-${VERSION}-android-aarch64.zip (standalone)
# 2. Pacman: opencode-${VERSION}-1-aarch64.pkg.tar.xz (Termux pacman format)
# 3. Deb: opencode_${VERSION}_aarch64.deb (old Termux deb format)
#
# Package layout (all formats):
#   bin/opencode                  — wrapper script: sets LD_PRELOAD then execs real binary
#   libexec/opencode/opencode.bin — real opencode ELF binary
#   lib/libtagfix.so              — disables Android bionic TBI heap tagging at process start
#
# The wrapper + libtagfix.so fix "Pointer tag ... was truncated" SIGABRT on Android 11+.
# Root cause: Bun/JSC NaN-boxing clears the top byte of heap pointers; bionic's default
# software TBI tagging expects tag 0xB4 there and aborts on free() when it finds 0x00.
# Fix: mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE) called via an
# LD_PRELOAD constructor *inside* the opencode process (execv-based wrappers don't work
# because execv resets the tagging level on the new image).
#
# ZIP install (flat layout — wrapper resolves siblings via $dir):
#   unzip opencode-...-android-aarch64.zip -d $PREFIX/bin/
#   chmod +x $PREFIX/bin/opencode $PREFIX/bin/opencode.bin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

OPENCODE_BINARY="$DIST_DIR/opencode"
WRAPPER_SCRIPT="$REPO_ROOT/bin/opencode"
TAGFIX_SRC="$REPO_ROOT/src/libtagfix.c"
PKG_DIR="$WORK_DIR/packages"

if [ ! -f "$OPENCODE_BINARY" ]; then
    echo "ERROR: OpenCode binary not found at $OPENCODE_BINARY"
    echo "       Run scripts/build-opencode.sh first."
    exit 1
fi

if [ ! -f "$WRAPPER_SCRIPT" ]; then
    echo "ERROR: Wrapper script not found at $WRAPPER_SCRIPT"
    exit 1
fi

if [ ! -f "$TAGFIX_SRC" ]; then
    echo "ERROR: libtagfix.c not found at $TAGFIX_SRC"
    exit 1
fi

echo "=== Creating packages for OpenCode v${OPENCODE_VERSION} ==="

BINARY_SIZE=$(stat -c%s "$OPENCODE_BINARY")
BUILD_DATE=$(date +%s)

# Clean up
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# ==========================================
# Compile libtagfix.so (Android aarch64)
# ==========================================
echo ">>> Compiling libtagfix.so..."
TAGFIX_SO="$PKG_DIR/libtagfix.so"
"$ANDROID_CC" -shared -fPIC -O2 -o "$TAGFIX_SO" "$TAGFIX_SRC"
echo "    Compiled $(stat -c%s "$TAGFIX_SO") bytes"

TAGFIX_SIZE=$(stat -c%s "$TAGFIX_SO")
INSTALLED_SIZE=$(( (BINARY_SIZE + TAGFIX_SIZE + 8192) / 1024 ))  # rough kB estimate

# ==========================================
# 1. ZIP package (flat layout)
# ==========================================
# All three files are placed at the top level so a single
#   unzip opencode-...-android-aarch64.zip -d $PREFIX/bin/
# drops wrapper, real binary, and libtagfix.so together.
# The wrapper resolves siblings via $dir (dirname of $0).
echo ">>> Creating ZIP package..."
ZIP_NAME="opencode-${OPENCODE_VERSION}-android-aarch64.zip"
cp "$OPENCODE_BINARY" "$PKG_DIR/opencode.bin"
cp "$WRAPPER_SCRIPT"  "$PKG_DIR/opencode"
chmod 755 "$PKG_DIR/opencode" "$PKG_DIR/opencode.bin"
cd "$PKG_DIR"
zip -9 "$PKG_DIR/$ZIP_NAME" opencode opencode.bin libtagfix.so
echo "    Created $ZIP_NAME"

# ==========================================
# 2. Pacman package (Termux)
# ==========================================
echo ">>> Creating pacman package..."
PACMAN_STAGING="$PKG_DIR/pacman-staging"
PACMAN_USR="$PACMAN_STAGING/data/data/com.termux/files/usr"
mkdir -p "$PACMAN_USR/bin" "$PACMAN_USR/libexec/opencode" "$PACMAN_USR/lib"

cp "$WRAPPER_SCRIPT" "$PACMAN_USR/bin/opencode"
chmod 755 "$PACMAN_USR/bin/opencode"

cp "$OPENCODE_BINARY" "$PACMAN_USR/libexec/opencode/opencode.bin"
chmod 755 "$PACMAN_USR/libexec/opencode/opencode.bin"

cp "$TAGFIX_SO" "$PACMAN_USR/lib/libtagfix.so"
chmod 644 "$PACMAN_USR/lib/libtagfix.so"

# Create .PKGINFO
cat > "$PACMAN_STAGING/.PKGINFO" << EOF
pkgname = opencode
pkgver = ${OPENCODE_VERSION}-1
pkgdesc = AI-powered coding assistant for the terminal
url = https://github.com/anomalyco/opencode
builddate = ${BUILD_DATE}
packager = opencode-termux
size = ${INSTALLED_SIZE}
arch = aarch64
license = MIT
depend = ripgrep
EOF

PACMAN_NAME="opencode-${OPENCODE_VERSION}-1-aarch64.pkg.tar.xz"
cd "$PACMAN_STAGING"
tar cf - .PKGINFO data | xz -9 > "$PKG_DIR/$PACMAN_NAME"
echo "    Created $PACMAN_NAME"

# ==========================================
# 3. Deb package (old Termux format)
# ==========================================
echo ">>> Creating deb package..."
DEB_STAGING="$PKG_DIR/deb-staging"
# Note: the extra leading 'data/' under deb-staging is intentional.
# The packaging step does: cd deb-staging/data && tar ... data
# so the data.tar.gz contains data/data/com.termux/... which dpkg
# extracts to /data/data/com.termux/... (the real Termux prefix).
DEB_USR="$DEB_STAGING/data/data/data/com.termux/files/usr"
mkdir -p "$DEB_USR/bin" "$DEB_USR/libexec/opencode" "$DEB_USR/lib"
mkdir -p "$DEB_STAGING/DEBIAN"

cp "$WRAPPER_SCRIPT" "$DEB_USR/bin/opencode"
chmod 755 "$DEB_USR/bin/opencode"

cp "$OPENCODE_BINARY" "$DEB_USR/libexec/opencode/opencode.bin"
chmod 755 "$DEB_USR/libexec/opencode/opencode.bin"

cp "$TAGFIX_SO" "$DEB_USR/lib/libtagfix.so"
chmod 644 "$DEB_USR/lib/libtagfix.so"

# Create control file
cat > "$DEB_STAGING/DEBIAN/control" << EOF
Package: opencode
Version: ${OPENCODE_VERSION}
Architecture: aarch64
Maintainer: Guy Sheffer <guysoft@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: ripgrep
Section: utils
Priority: optional
Homepage: https://github.com/anomalyco/opencode
Description: AI-powered coding assistant for the terminal
 OpenCode is an AI-powered coding assistant that runs in the terminal.
 This package provides a standalone binary compiled for Android/Termux,
 with a heap-tagging fix for Android 11+ (fixes SIGABRT on Pixel 8,
 S24 Ultra, Poco F7, and other devices with bionic TBI tagging enabled).
EOF

DEB_NAME="opencode_${OPENCODE_VERSION}_aarch64.deb"

# Build deb manually (dpkg-deb may not be available)
cd "$DEB_STAGING/data"
tar czf "$DEB_STAGING/data.tar.gz" data
cd "$DEB_STAGING/DEBIAN"
tar czf "$DEB_STAGING/control.tar.gz" control
echo "2.0" > "$DEB_STAGING/debian-binary"
cd "$DEB_STAGING"
ar rc "$PKG_DIR/$DEB_NAME" debian-binary control.tar.gz data.tar.gz
echo "    Created $DEB_NAME"

# ==========================================
# Summary
# ==========================================
echo ""
echo "=== Packages created ==="
echo ""
ls -lh "$PKG_DIR"/*.{zip,xz,deb} 2>/dev/null
echo ""
echo "Install on Termux:"
echo "  Pacman: pacman -U $PACMAN_NAME"
echo "  Deb:    dpkg -i $DEB_NAME"
echo ""
echo "  Standalone (zip) — installs wrapper + binary + libtagfix.so into bin/:"
echo "    unzip $ZIP_NAME -d \$PREFIX/bin/"
echo "    chmod +x \$PREFIX/bin/opencode \$PREFIX/bin/opencode.bin"
