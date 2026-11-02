#!/usr/bin/env bash
# Runs the Hollowmere Nakama server without Docker: a thin wrapper around server/nakama/run.mjs
# (Node), which builds Nakama's command line from the environment / server/.env (secrets and the
# Tretu runtime env as flags, never written to a file, redacted in every log line) and refuses to
# start in production when a key is missing or still a default. PM2 runs run.mjs directly
# (ecosystem.config.cjs).
#
#   server/nakama/nakama.sh start     migrate the database, then run Nakama
#   server/nakama/nakama.sh migrate   only "nakama migrate up" (deploy step)
#   server/nakama/nakama.sh check     load the Lua modules once and exit (CI / before a reload)
#   server/nakama/nakama.sh args      print the redacted command line and any problems
#
# Environment: see the header of run.mjs (NAKAMA_BIN, NAKAMA_HTTP_KEY, NAKAMA_SESSION_*,
# NAKAMA_CONSOLE_*, NAKAMA_DATABASE_ADDRESS, TRETU_*, HOLLOWMERE_PUBLIC_URL, NAKAMA_LOCAL_CONFIG,
# NAKAMA_DATA_DIR, NAKAMA_ALLOW_DEFAULTS=1 for dev/CI only).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null || { echo "node (22+) is required to run Nakama (HOSTING.md step 2)" >&2; exit 1; }
exec node "$HERE/run.mjs" "$@"
