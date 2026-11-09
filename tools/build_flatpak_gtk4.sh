#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_id=com.rnd.boomprint
manifest="$root_dir/flatpak/$app_id.gtk4.yml"
output_dir="$root_dir/build/linux-gtk4/flatpak-output"
bundle_dir=""

while (( $# )); do
  case "$1" in
    --out-dir|--bundle-dir)
      if (( $# < 2 )); then echo "$1 requires a path" >&2; exit 2; fi
      if [[ "$1" == --out-dir ]]; then output_dir="$2"; else bundle_dir="$2"; fi
      shift 2 ;;
    *) echo "Usage: $0 [--out-dir PATH] [--bundle-dir PATH]" >&2; exit 2 ;;
  esac
done

for tool in flatpak flatpak-builder patchelf; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

if [[ -z "$bundle_dir" ]]; then
  bash "$root_dir/tools/flutter_linux.sh" gtk4 build --release
  bundle_dir="$root_dir/build/linux-gtk4/x64/release/bundle"
fi
test -x "$bundle_dir/boomprint"

# Stage independently of the native package bundle. Resolve only libraries
# missing from the GNOME runtime.
staging_dir="$(mktemp -d "$root_dir/build/linux-gtk4/flatpak-stage.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir/bundle"
cp -a "$bundle_dir/." "$staging_dir/bundle/"
patchelf --set-rpath '$ORIGIN/lib' "$staging_dir/bundle/boomprint"
while IFS= read -r -d '' library; do
  patchelf --set-rpath '$ORIGIN' "$library"
done < <(find "$staging_dir/bundle/lib" -maxdepth 1 -type f -name '*.so*' -print0)

if readelf -d "$staging_dir/bundle/lib/libcnativeapi.so" | grep -q 'Shared library: \[libgtk-3.so'; then
  echo "cnativeapi links GTK3 into the GTK4 bundle. Rebuild the plugin without GTK3/appindicator before packaging." >&2
  exit 1
fi
mpv_library=$(ldconfig -p | awk '$1 == "libmpv.so.2" {print $NF; exit}')
if [[ -z "$mpv_library" ]]; then echo "libmpv.so.2 is required." >&2; exit 1; fi
cp -L "$mpv_library" "$staging_dir/bundle/lib/libmpv.so.2"
patchelf --set-rpath '$ORIGIN' "$staging_dir/bundle/lib/libmpv.so.2"
LD_LIBRARY_PATH="$staging_dir/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  ldd "$staging_dir/bundle/boomprint" "$staging_dir/bundle"/lib/*.so* > "$staging_dir/host-libraries.txt"
# Prefer an installed user runtime; keep all runs explicit when both scopes
# contain the same GNOME version.
flatpak_scope=--system
if flatpak info --user org.gnome.Platform//51 >/dev/null 2>&1; then
  flatpak_scope=--user
fi
flatpak info "$flatpak_scope" org.gnome.Platform//51 >/dev/null
flatpak info "$flatpak_scope" org.gnome.Sdk//51 >/dev/null
for attempt in {1..10}; do
  flatpak run "$flatpak_scope" --filesystem="$staging_dir:ro" --command=sh \
    org.gnome.Platform//51 -c '
      export LD_LIBRARY_PATH="$1/lib"
      set -e
      for target in "$1/boomprint" "$1"/lib/*.so*; do ldd "$target" || true; done
    ' sh "$staging_dir/bundle" > "$staging_dir/runtime-libraries.txt" 2>&1
  if grep -q 'version .* not found' "$staging_dir/runtime-libraries.txt"; then
    cat "$staging_dir/runtime-libraries.txt" >&2
    echo "Bundle requires library versions newer than the Flatpak runtime." >&2
    exit 1
  fi
  mapfile -t missing < <(awk '/=> not found/ {print $1}' "$staging_dir/runtime-libraries.txt" | sort -u)
  if (( ${#missing[@]} == 0 )); then break; fi
  for soname in "${missing[@]}"; do
    source_library="$(awk -v name="$soname" '$1 == name && $2 == "=>" && $3 ~ /^\// {print $3; exit}' "$staging_dir/host-libraries.txt")"
    if [[ -z "$source_library" ]]; then
      echo "Cannot resolve runtime dependency: $soname" >&2; exit 1
    fi
    cp -L "$source_library" "$staging_dir/bundle/lib/$soname"
    patchelf --set-rpath '$ORIGIN' "$staging_dir/bundle/lib/$soname"
  done
  if (( attempt == 10 )); then echo "Runtime dependencies did not converge" >&2; exit 1; fi
done

# Relative staged sources also keep host checkout paths out of the exported
# /app/manifest.json.
cp -a "$root_dir/flatpak" "$staging_dir/flatpak"
cp "$root_dir/LICENSE" "$staging_dir/LICENSE"
python3 - "$manifest" "$staging_dir/manifest.yml" <<'PY'
from pathlib import Path
import sys
source, target = sys.argv[1:]
text = Path(source).read_text()
text = text.replace('path: ../build/linux-gtk4/x64/release/bundle', 'path: bundle')
text = text.replace('path: .\n', 'path: flatpak\n')
text = text.replace('path: ../LICENSE', 'path: LICENSE')
Path(target).write_text(text)
PY

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
builder_args=(--disable-rofiles-fuse --force-clean)
flatpak-builder "$flatpak_scope" "${builder_args[@]}" --repo="$output_dir/repo" \
  "$output_dir/build" "$staging_dir/manifest.yml"
flatpak build --runtime "$output_dir/build" sh -c '
  set -e
  export LD_LIBRARY_PATH=/app/bin/lib
  for target in /app/bin/boomprint /app/bin/lib/*.so*; do ldd "$target"; done
' > "$staging_dir/exported-libraries.txt" 2>&1
if grep -Eq '=> not found|version .* not found|libgtk-3.so' "$staging_dir/exported-libraries.txt"; then
  cat "$staging_dir/exported-libraries.txt" >&2
  echo "Exported GTK4 Flatpak failed library verification." >&2
  exit 1
fi
flatpak build-bundle "$output_dir/repo" "$output_dir/$app_id.gtk4.flatpak" "$app_id" gtk4
echo "GTK4 Flatpak: $output_dir/$app_id.gtk4.flatpak"
