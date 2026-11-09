#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="$ROOT_DIR/flatpak/com.rnd.boomprint.yml"
DEFAULT_OUT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/boomprint/flatpak"
TMP_OUT_DIR="/tmp/rnd_bambu_rtsp-flatpak"

usage() {
  cat <<'EOF'
Usage: ./tools/build_flatpak.sh [--tmp] [--out-dir PATH]

  --tmp           Store Flatpak builder artifacts under /tmp.
  --out-dir PATH   Store Flatpak builder artifacts under PATH.
EOF
}

OUT_DIR="$DEFAULT_OUT_DIR"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tmp)
      OUT_DIR="$TMP_OUT_DIR"
      shift
      ;;
    --out-dir)
      if [[ $# -lt 2 ]]; then
        echo "--out-dir requires a path." >&2
        exit 1
      fi
      OUT_DIR="$2"
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

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
BUILD_DIR="$OUT_DIR/flatpak"
REPO_DIR="$OUT_DIR/flatpak-repo"
BUNDLE_PATH="$OUT_DIR/com.rnd.boomprint.flatpak"

if ! command -v flatpak-builder >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    echo "flatpak-builder not found. Install: sudo dnf install -y flatpak flatpak-builder" >&2
  else
    echo "flatpak-builder not found. Install: sudo apt-get install flatpak flatpak-builder" >&2
  fi
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter not found in PATH." >&2
  exit 1
fi

# Build Flutter Linux bundle first (manifest expects build/linux/x64/release/bundle).
flutter build linux --release

# Keep only Flutter-produced libs in bundle/lib (avoid stale vendored trees).
BUNDLE_LIB_DIR="$ROOT_DIR/build/linux/x64/release/bundle/lib"
mkdir -p "$BUNDLE_LIB_DIR"
for so in "$BUNDLE_LIB_DIR"/*.so*; do
  [ -e "$so" ] || continue
  base="$(basename "$so")"
  case "$base" in
    libapp.so|libflutter_linux_gtk.so|libfile_saver_plugin.so|libmedia_kit_libs_linux_plugin.so|libmedia_kit_video_plugin.so)
      ;;
    *)
      rm -f "$so"
      ;;
  esac
done

# libmpv and its transitive dependencies are resolved from host runtime paths
# exposed inside Flatpak (see flatpak/com.rnd.boomprint.yml launcher).

# Build flatpak.
flatpak-builder --force-clean "$BUILD_DIR" "$MANIFEST"

# Create a repo and bundle for easy install/share.
flatpak-builder --force-clean --repo="$REPO_DIR" "$BUILD_DIR" "$MANIFEST"
flatpak build-bundle "$REPO_DIR" "$BUNDLE_PATH" com.rnd.boomprint

echo "Flatpak bundle created: $BUNDLE_PATH"
