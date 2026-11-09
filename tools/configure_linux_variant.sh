#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VARIANT="${1:-gtk3}"
CONFIG_FILE="$ROOT_DIR/linux/.gtk_variant.cmake"

case "$VARIANT" in
  gtk3|gtk4)
    ;;
  *)
    echo "Unsupported Linux GTK variant: $VARIANT" >&2
    echo "Expected one of: gtk3, gtk4" >&2
    exit 1
    ;;
esac

NEXT_CONTENT="set(LINUX_GTK_VARIANT \"$VARIANT\")"
if [[ -f "$CONFIG_FILE" ]] && [[ "$(cat "$CONFIG_FILE")" == "$NEXT_CONTENT" ]]; then
  echo "Linux runner already configured for $VARIANT."
  exit 0
fi

printf '%s\n' "$NEXT_CONTENT" > "$CONFIG_FILE"
echo "Configured Linux runner for $VARIANT."
