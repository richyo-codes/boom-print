#!/usr/bin/env bash
set -euo pipefail

unset MEDIA_KIT_GTK4_DEBUG 2>/dev/null || true
exec bash "$(dirname "${BASH_SOURCE[0]}")/flutter_linux.sh" gtk3 build --release "$@"
