#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VARIANT=${1:-gtk4}
ACTION=${2:-run}
if (( $# > 0 )); then shift; fi
if (( $# > 0 )); then shift; fi
case "$VARIANT" in
  gtk3|gtk4) ;;
  *) echo "Expected gtk3 or gtk4." >&2; exit 2 ;;
esac
case "$ACTION" in
  run) ARGS=(run -d linux); MODE=debug ;;
  build) ARGS=(build linux); MODE=release ;;
  *) echo "Usage: $0 {gtk3|gtk4} {run|build} [Flutter arguments...]" >&2; exit 2 ;;
esac
for arg in "$@"; do
  case "$arg" in
    --debug) MODE=debug ;;
    --profile) MODE=profile ;;
    --release) MODE=release ;;
    --local-engine*) echo "Use LOCAL_ENGINE, LOCAL_ENGINE_HOST, and LOCAL_ENGINE_SRC for local engine selection." >&2; exit 2 ;;
    --linux-gtk*) echo "Select GTK using the script's first argument." >&2; exit 2 ;;
  esac
done
cd "$ROOT_DIR"
if [[ "$VARIANT" == gtk4 && -z ${LOCAL_ENGINE_SRC:-} ]]; then
  source "$ROOT_DIR/tools/gtk4_artifacts.env"
fi
FLUTTER_BIN=${FLUTTER_BIN:-}
if [[ -z "$FLUTTER_BIN" ]]; then
  if [[ -x "$ROOT_DIR/.fvm/flutter_sdk/bin/flutter" ]]; then
    FLUTTER_BIN="$ROOT_DIR/.fvm/flutter_sdk/bin/flutter"
  else
    FLUTTER_BIN=flutter
  fi
fi
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  echo "Flutter executable not found: $FLUTTER_BIN" >&2
  exit 1
fi
if [[ $(uname -s) != Linux ]]; then
  echo "Linux GTK builds require a Linux host." >&2
  exit 1
fi
if [[ "$VARIANT" == gtk4 && -z ${LOCAL_ENGINE_SRC:-} ]]; then
  if [[ -z ${FLUTTER_PREBUILT_ENGINE_VERSION:-} ||
        -z ${FLUTTER_ENGINE_STORAGE_BASE_URL:-${FLUTTER_STORAGE_BASE_URL:-}} ]]; then
    echo "GTK4 requires LOCAL_ENGINE_SRC or a prebuilt engine version and storage URL." >&2
    exit 1
  fi
fi
ARGS+=("--$MODE")
if [[ -n ${LOCAL_ENGINE_SRC:-} ]]; then
  case "$MODE" in
    debug) DEFAULT_ENGINE=host_debug_unopt ;;
    profile) DEFAULT_ENGINE=host_profile_unopt ;;
    release) DEFAULT_ENGINE=host_release ;;
  esac
  ENGINE=${LOCAL_ENGINE:-$DEFAULT_ENGINE}
  HOST_ENGINE=${LOCAL_ENGINE_HOST:-$ENGINE}
  LIBRARY=libflutter_linux_gtk.so
  if [[ "$VARIANT" == gtk4 ]]; then LIBRARY=libflutter_linux_gtk4.so; fi
  if [[ ! -f "$LOCAL_ENGINE_SRC/out/$ENGINE/$LIBRARY" ||
        ! -d "$LOCAL_ENGINE_SRC/out/$HOST_ENGINE" ]]; then
    echo "Missing $VARIANT local engine: $LOCAL_ENGINE_SRC/out/$ENGINE/$LIBRARY or host output $HOST_ENGINE" >&2
    exit 1
  fi
  ARGS+=("--local-engine=$ENGINE" "--local-engine-host=$HOST_ENGINE"
    "--local-engine-src-path=$LOCAL_ENGINE_SRC")
fi
if [[ "$VARIANT" == gtk4 ]]; then
  INTEROP=${MEDIA_KIT_GTK4_TEXTURE_INTEROP:-direct}
  case "$INTEROP" in
    direct|egl-image) ;;
    *) echo "Expected MEDIA_KIT_GTK4_TEXTURE_INTEROP=direct or egl-image." >&2; exit 2 ;;
  esac
  ARGS+=(--linux-gtk=gtk4 "--dart-define=MEDIA_KIT_GTK4_TEXTURE_INTEROP=$INTEROP")
fi
export FLUTTER_LINUX_GTK="$VARIANT"
ARGS+=("--dart-define=FLUTTER_LINUX_GTK=$VARIANT"
  "--dart-define=RUNTIME_GTK_VERSION=${VARIANT#gtk}")
mkdir -p "$ROOT_DIR/logs"
LOG_FILE="$ROOT_DIR/logs/${VARIANT}_${ACTION}_${MODE}_$(date +%Y%m%d_%H%M%S)_$$.log"
printf 'SDK: %s\nGTK: %s | Action: %s | Mode: %s\nLog: %s\n' "$FLUTTER_BIN" "$VARIANT" "$ACTION" "$MODE" "$LOG_FILE"
"$FLUTTER_BIN" "${ARGS[@]}" "$@" 2>&1 | tee "$LOG_FILE"
