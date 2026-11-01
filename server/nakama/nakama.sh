#!/usr/bin/env bash
# Runs the Hollowmere Nakama server without Docker. PM2 starts it as "hollowmere-nakama"
# (ecosystem.config.cjs at the repo root).
#
#   server/nakama/nakama.sh start     migrate the database, then run Nakama (PM2 uses this)
#   server/nakama/nakama.sh migrate   only "nakama migrate up" (deploy step)
#   server/nakama/nakama.sh check     load the Lua modules once and exit (CI / before a reload)
#
# Environment:
#   NAKAMA_BIN               Nakama binary (default /opt/nakama/nakama, else nakama on PATH)
#   NAKAMA_LOCAL_CONFIG      secrets + Tretu env (default server/nakama/local.yml)
#   NAKAMA_DATA_DIR          default server/nakama/data
#   NAKAMA_DATABASE_ADDRESS  dev/CI only: user[:pass]@host:port/db instead of local.yml
#   NAKAMA_ALLOW_DEFAULTS=1  dev/CI only: start without local.yml (insecure default keys)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${NAKAMA_BIN:-/opt/nakama/nakama}"
if [[ ! -x "$BIN" ]]; then
  BIN="$(command -v nakama || true)"
fi
[[ -n "$BIN" && -x "$BIN" ]] || { echo "nakama binary not found (set NAKAMA_BIN, see HOSTING.md)" >&2; exit 1; }
LOCAL="${NAKAMA_LOCAL_CONFIG:-$HERE/local.yml}"
DATA="${NAKAMA_DATA_DIR:-$HERE/data}"

cmd="${1:-start}"
[[ $# -gt 0 ]] && shift
if [[ "$cmd" == "check" ]]; then
  exec "$BIN" check --runtime.path "$HERE/modules"
fi

args=(--config "$HERE/hollowmere.yml")
if [[ -f "$LOCAL" ]]; then
  args+=(--config "$LOCAL")
elif [[ "${NAKAMA_ALLOW_DEFAULTS:-}" != "1" ]]; then
  echo "missing $LOCAL: copy server/nakama/local.example.yml and fill it in (HOSTING.md)" >&2
  exit 1
fi
if [[ -n "${NAKAMA_DATABASE_ADDRESS:-}" ]]; then
  args+=(--database.address "$NAKAMA_DATABASE_ADDRESS")
fi
mkdir -p "$DATA"
args+=(--runtime.path "$HERE/modules" --data_dir "$DATA")

case "$cmd" in
  migrate)
    exec "$BIN" migrate up "${args[@]}"
    ;;
  start)
    "$BIN" migrate up "${args[@]}"
    exec "$BIN" "${args[@]}" "$@"
    ;;
  *)
    echo "usage: $0 start|migrate|check" >&2
    exit 2
    ;;
esac
