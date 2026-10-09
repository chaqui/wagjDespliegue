#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
UPDATE_SCRIPT="${UPDATE_SCRIPT:-${SCRIPT_DIR}/update_images.sh}"
LOOP_MODE="${LOOP_MODE:-true}"
countdown() { local n="$1"; while [ "$n" -gt 0 ]; do printf '\rProxima comprobacion en %3d segundos...\033[K' "$n"; sleep 1; n=$((n-1)); done; printf '\r\033[K'; }
[ -x "$UPDATE_SCRIPT" ] || { echo "No se puede ejecutar $UPDATE_SCRIPT" >&2; exit 1; }
while true; do "$UPDATE_SCRIPT" || true; [ "$LOOP_MODE" = true ] || break; countdown "$POLL_INTERVAL"; done
