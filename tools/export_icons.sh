#!/usr/bin/env bash
set -euo pipefail

size="${1:-1024}"
icons_dir="assets/icons"
renders_dir="$icons_dir/renders"

mkdir -p "$renders_dir"

if command -v inkscape >/dev/null 2>&1; then
  exporter="inkscape"
elif command -v rsvg-convert >/dev/null 2>&1; then
  exporter="rsvg-convert"
else
  echo "Error: install inkscape or rsvg-convert to export PNGs." >&2
  exit 1
fi

for svg in "$icons_dir"/icon_*.svg; do
  [ -e "$svg" ] || continue
  base="$(basename "$svg")"
  name="${base#icon_}"
  name="${name%.svg}"
  out="$renders_dir/$name.png"

  if [ "$exporter" = "inkscape" ]; then
    inkscape "$svg" --export-type=png --export-filename="$out" --export-width="$size" --export-height="$size" >/dev/null
  else
    rsvg-convert -w "$size" -h "$size" -o "$out" "$svg"
  fi
done

echo "Exported PNGs to $renders_dir"
