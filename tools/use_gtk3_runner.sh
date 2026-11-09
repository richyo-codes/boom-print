#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

"$ROOT_DIR/tools/configure_linux_variant.sh" gtk3
echo "Build with: FLUTTER_LINUX_GTK=gtk3 flutter run -d linux"
