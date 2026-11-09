#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUNDLE_DIR="$ROOT_DIR/build/linux/x64/release/bundle"
OUT_DIR="$ROOT_DIR/build/packages/deb"
PACKAGE_NAME="boomprint"
INSTALL_DIR="/opt/boomprint"

usage() {
  cat <<'EOF'
Usage: ./tools/build_deb.sh [--bundle-dir PATH] [--out-dir PATH] [--version VERSION] [--arch ARCH]

Build a .deb from an existing Flutter Linux release bundle.
Default bundle path: build/linux/x64/release/bundle
Default output dir:  build/packages/deb
EOF
}

VERSION=""
ARCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd dpkg-deb
require_cmd install
require_cmd sed

normalize_deb_version() {
  local raw="$1"
  local normalized

  normalized=$(printf '%s' "$raw" | sed -E \
    -e 's/^[vV]//' \
    -e 's/-([0-9]+)-g([0-9A-Za-z]+)/+\1.g\2/g' \
    -e 's/-dirty$/.dirty/' \
    -e 's/_/./g' \
    -e 's/[^A-Za-z0-9.+~:-]+/./g' \
    -e 's/-/./g' \
    -e 's/\.\.+/./g' \
    -e 's/^\.+//' \
    -e 's/\.+$//')

  if [[ -z "$normalized" ]]; then
    echo "Could not normalize Debian version from: $raw" >&2
    exit 1
  fi
  if [[ ! "$normalized" =~ ^[0-9] ]]; then
    normalized="0~$normalized"
  fi

  printf '%s\n' "$normalized"
}

if [[ -z "$VERSION" ]]; then
  VERSION=$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\)$/\1/p' "$ROOT_DIR/pubspec.yaml" | head -n1)
fi
if [[ -z "$VERSION" ]]; then
  echo "Could not determine version from pubspec.yaml; pass --version." >&2
  exit 1
fi
VERSION=$(normalize_deb_version "$VERSION")

if [[ -z "$ARCH" ]]; then
  ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
fi

if [[ ! -f "$BUNDLE_DIR/boomprint" ]]; then
  echo "Missing bundle executable: $BUNDLE_DIR/boomprint" >&2
  echo "Run: flutter build linux --release" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
STAGE_DIR=$(mktemp -d "$OUT_DIR/${PACKAGE_NAME}.XXXXXX")
trap 'rm -rf "$STAGE_DIR"' EXIT

install -d "$STAGE_DIR/DEBIAN"
install -d "$STAGE_DIR$INSTALL_DIR"
install -d "$STAGE_DIR/usr/bin"
install -d "$STAGE_DIR/usr/share/applications"
install -d "$STAGE_DIR/usr/share/icons/hicolor/scalable/apps"
install -d "$STAGE_DIR/usr/share/doc/$PACKAGE_NAME"

cp -a "$BUNDLE_DIR/." "$STAGE_DIR$INSTALL_DIR/"
install -m755 "$ROOT_DIR/packaging/common/boomprint" "$STAGE_DIR/usr/bin/boomprint"
install -m644 "$ROOT_DIR/packaging/common/boomprint.desktop" \
  "$STAGE_DIR/usr/share/applications/boomprint.desktop"
install -m644 "$ROOT_DIR/flatpak/icons/com.rnd.boomprint.svg" \
  "$STAGE_DIR/usr/share/icons/hicolor/scalable/apps/boomprint.svg"
install -m644 "$ROOT_DIR/LICENSE" "$STAGE_DIR/usr/share/doc/$PACKAGE_NAME/copyright"

INSTALLED_SIZE=$(du -sk "$STAGE_DIR" | awk '{print $1}')
cat > "$STAGE_DIR/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: Richard Young <richard@example.com>
Installed-Size: $INSTALLED_SIZE
Depends: libgtk-3-0, libmpv2, libpulse0, libasound2 | libasound2t64, libsecret-1-0, libssl3, libstdc++6, zlib1g
Description: BoomPrint desktop client for Bambu Lab printers
 LAN-only desktop client with MQTT, FTP/FTPS, and stream viewing support.
EOF

PACKAGE_PATH="$OUT_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$STAGE_DIR" "$PACKAGE_PATH"
echo "Built: $PACKAGE_PATH"
