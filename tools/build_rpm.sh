#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUNDLE_DIR="$ROOT_DIR/build/linux/x64/release/bundle"
OUT_DIR="$ROOT_DIR/build/packages/rpm"
PACKAGE_NAME="boomprint"
INSTALL_DIR="/opt/boomprint"
GTK_VARIANT=gtk3

usage() {
  cat <<'EOF'
Usage: ./tools/build_rpm.sh [--bundle-dir PATH] [--out-dir PATH] [--version VERSION] [--release RELEASE]

Build an RPM from an existing Flutter Linux release bundle.
Default bundle path: build/linux/x64/release/bundle
Default output dir:  build/packages/rpm
EOF
}

RAW_VERSION=""
RPM_VERSION=""
RPM_RELEASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gtk)
      GTK_VARIANT="$2"
      shift 2
      ;;
    --bundle-dir)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --version)
      RAW_VERSION="$2"
      shift 2
      ;;
    --release)
      RPM_RELEASE="$2"
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

case "$GTK_VARIANT" in
  gtk3) GTK_REQUIRES=gtk3 ;;
  gtk4) GTK_REQUIRES=gtk4 ;;
  *) echo "Expected --gtk gtk3 or gtk4" >&2; exit 2 ;;
esac
if [[ "$GTK_VARIANT" == gtk4 && "$BUNDLE_DIR" == "$ROOT_DIR/build/linux/x64/release/bundle" ]]; then
  BUNDLE_DIR="$ROOT_DIR/build/linux-gtk4/x64/release/bundle"
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_patchelf() {
  if command -v patchelf >/dev/null 2>&1; then
    return
  fi

  cat >&2 <<'EOF'
Missing required command: patchelf
Install it with your system package manager (for example, `sudo dnf install patchelf`),
or run this build in a Nix shell that provides it:
  nix shell nixpkgs#patchelf --command ./tools/build_rpm.sh
EOF
  exit 1
}

require_cmd rpmbuild
require_cmd install
require_cmd sed
require_cmd tar
require_patchelf

normalize_rpm_token() {
  printf '%s' "$1" | sed -E \
    -e 's/^[vV]//' \
    -e 's/[^A-Za-z0-9._+~]+/./g' \
    -e 's/-/./g' \
    -e 's/\.\.+/./g' \
    -e 's/^\.+//' \
    -e 's/\.+$//'
}

if [[ -z "$RAW_VERSION" ]]; then
  RAW_VERSION=$(sed -n 's/^version:[[:space:]]*\([^[:space:]]*\)$/\1/p' "$ROOT_DIR/pubspec.yaml" | head -n1)
fi
if [[ -z "$RAW_VERSION" ]]; then
  echo "Could not determine version from pubspec.yaml; pass --version." >&2
  exit 1
fi

RAW_VERSION=${RAW_VERSION#v}
RAW_VERSION=${RAW_VERSION#V}
if [[ "$RAW_VERSION" =~ ^(.+)-([0-9]+)-g([0-9A-Za-z]+)(-dirty)?$ ]]; then
  RPM_VERSION=$(normalize_rpm_token "${BASH_REMATCH[1]}")
  DEFAULT_RELEASE="${BASH_REMATCH[2]}.g${BASH_REMATCH[3]}"
  if [[ -n "${BASH_REMATCH[4]}" ]]; then
    DEFAULT_RELEASE="${DEFAULT_RELEASE}.dirty"
  fi
elif [[ "$RAW_VERSION" == *"+"* ]]; then
  RPM_VERSION=$(normalize_rpm_token "${RAW_VERSION%%+*}")
  DEFAULT_RELEASE=$(normalize_rpm_token "${RAW_VERSION#*+}")
else
  RPM_VERSION=$(normalize_rpm_token "$RAW_VERSION")
  DEFAULT_RELEASE=1
fi
RPM_RELEASE=$(normalize_rpm_token "${RPM_RELEASE:-$DEFAULT_RELEASE}")

if [[ -z "$RPM_VERSION" ]]; then
  echo "Could not normalize RPM version from: $RAW_VERSION" >&2
  exit 1
fi
if [[ ! "$RPM_VERSION" =~ ^[0-9] ]]; then
  RPM_VERSION="0.${RPM_VERSION}"
fi
if [[ -z "$RPM_RELEASE" ]]; then
  RPM_RELEASE=1
fi

if [[ ! -f "$BUNDLE_DIR/boomprint" ]]; then
  echo "Missing bundle executable: $BUNDLE_DIR/boomprint" >&2
  echo "Run: flutter build linux --release" >&2
  exit 1
fi

if [[ "$GTK_VARIANT" == gtk4 ]]; then
  require_cmd readelf
  if readelf -d "$BUNDLE_DIR/lib/libcnativeapi.so" | grep -q 'Shared library: \[libgtk-3.so'; then
    echo "cnativeapi links GTK3 into the GTK4 bundle. Rebuild the plugin without GTK3/appindicator before packaging." >&2
    exit 1
  fi
fi

mkdir -p "$OUT_DIR"
RPMROOT=$(mktemp -d "$OUT_DIR/rpmbuild.XXXXXX")
trap 'rm -rf "$RPMROOT"' EXIT
install -d "$RPMROOT"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

SOURCE_DIR="$RPMROOT/SOURCES/${PACKAGE_NAME}-${RPM_VERSION}"
install -d "$SOURCE_DIR$INSTALL_DIR"
install -d "$SOURCE_DIR/usr/bin"
install -d "$SOURCE_DIR/usr/share/applications"
install -d "$SOURCE_DIR/usr/share/icons/hicolor/scalable/apps"
install -d "$SOURCE_DIR/usr/share/licenses/$PACKAGE_NAME"

cp -a "$BUNDLE_DIR/." "$SOURCE_DIR$INSTALL_DIR/"
if [[ "$GTK_VARIANT" == gtk4 ]]; then
  test -f "$BUNDLE_DIR/lib/libflutter_linux_gtk4.so"
fi
patchelf --set-rpath '$ORIGIN/lib' "$SOURCE_DIR$INSTALL_DIR/boomprint"
while IFS= read -r -d '' library; do
  patchelf --set-rpath '$ORIGIN' "$library"
done < <(find "$SOURCE_DIR$INSTALL_DIR/lib" -maxdepth 1 -type f -name '*.so*' -print0)
install -m755 "$ROOT_DIR/packaging/common/boomprint" "$SOURCE_DIR/usr/bin/boomprint"
install -m644 "$ROOT_DIR/packaging/common/boomprint.desktop" \
  "$SOURCE_DIR/usr/share/applications/boomprint.desktop"
install -m644 "$ROOT_DIR/flatpak/icons/com.rnd.boomprint.svg" \
  "$SOURCE_DIR/usr/share/icons/hicolor/scalable/apps/boomprint.svg"
install -m644 "$ROOT_DIR/LICENSE" "$SOURCE_DIR/usr/share/licenses/$PACKAGE_NAME/LICENSE"

tar -C "$RPMROOT/SOURCES" -czf "$RPMROOT/SOURCES/${PACKAGE_NAME}-${RPM_VERSION}.tar.gz" \
  "${PACKAGE_NAME}-${RPM_VERSION}"

sed \
  -e "s/@VERSION@/$RPM_VERSION/g" \
    -e "s/@RELEASE@/$RPM_RELEASE/g" \
    -e "s/@GTK_REQUIRES@/$GTK_REQUIRES/g" \
  "$ROOT_DIR/packaging/rpm/boomprint.spec.in" > "$RPMROOT/SPECS/${PACKAGE_NAME}.spec"

rpmbuild \
  --define "_topdir $RPMROOT" \
  --define "_rpmdir $OUT_DIR" \
  --define "_srcrpmdir $OUT_DIR" \
  -ba "$RPMROOT/SPECS/${PACKAGE_NAME}.spec"

echo "Built RPMs under: $OUT_DIR"
