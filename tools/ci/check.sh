#!/usr/bin/env bash
# Every test Hollowmere has, in one run, on a dev machine (there is no GitHub Actions CI any more).
# Run it before merging to main; main must always be green, because the deploy takes main as is.
#
#   tools/ci/check.sh              everything (about 10 minutes)
#   tools/ci/check.sh --quick      without the two long simulations and the network tests
#
# Needs: Godot 4.7.2 (GODOT, default `godot` on PATH), node 22+, python3, lua5.1 + luac5.1, nginx,
# openssl, curl, psql/createdb and a Postgres 16 reachable as CHECK_PG (default
# postgres:postgres@127.0.0.1:5432). The Nakama 3.41.0 binary comes from NAKAMA_BIN or is downloaded
# into .tools/nakama and checked against the pinned SHA-256 (HOSTING.md §4).
#
# Not for the production server: it starts its own Nakama on 127.0.0.1:7350 and drops/creates the
# databases hollowmere_check and nakama_test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

NAKAMA_VERSION="3.41.0"
NAKAMA_SHA256="71aea14384b097e043917d0b1e8c3799594064acbab01853e71ea10d80624ce2"
GODOT_VERSION="4.7.2"
export GODOT="${GODOT:-godot}"
CHECK_PG="${CHECK_PG:-postgres:postgres@127.0.0.1:5432}"
QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

NAKAMA_PID=""
cleanup() { [[ -n "$NAKAMA_PID" ]] && kill "$NAKAMA_PID" 2>/dev/null || true; }
trap cleanup EXIT

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing: $1 ($2)" >&2; exit 1; }; }
godot_ok() { local ok="$1"; shift; GODOT_OK="$ok" tools/ci/godot.sh "$@"; }

step "Tools"
need "$GODOT" "Godot $GODOT_VERSION, set GODOT=/path/to/godot"
need node "Node 22+"; need python3 "Python 3"; need lua5.1 "apt install lua5.1"; need luac5.1 "apt install lua5.1"
need nginx "apt install nginx"; need openssl "openssl"; need curl "curl"; need psql "apt install postgresql-client"
"$GODOT" --version | grep -q "^$GODOT_VERSION\." || { echo "Godot $GODOT_VERSION required, found $("$GODOT" --version)" >&2; exit 1; }
node -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' || { echo "Node 22+ required" >&2; exit 1; }
psql "postgres://$CHECK_PG/postgres" -Atqc 'select 1' >/dev/null || { echo "Postgres not reachable as $CHECK_PG (set CHECK_PG)" >&2; exit 1; }

if [[ -z "${NAKAMA_BIN:-}" ]]; then
  NAKAMA_BIN="$ROOT/.tools/nakama/nakama"
  if [[ ! -x "$NAKAMA_BIN" ]]; then
    step "Download Nakama $NAKAMA_VERSION"
    mkdir -p .tools/nakama
    curl -fsSL -o .tools/nakama.tgz "https://github.com/heroiclabs/nakama/releases/download/v${NAKAMA_VERSION}/nakama-${NAKAMA_VERSION}-linux-amd64.tar.gz"
    echo "${NAKAMA_SHA256}  .tools/nakama.tgz" | sha256sum -c -
    tar -xzf .tools/nakama.tgz -C .tools/nakama && rm .tools/nakama.tgz
    found=$(find .tools/nakama -type f -name nakama | head -1)
    [[ "$found" == ".tools/nakama/nakama" ]] || mv "$found" .tools/nakama/nakama
    chmod +x "$NAKAMA_BIN"
  fi
fi
export NAKAMA_BIN
"$NAKAMA_BIN" --version

step "Import project"
"$GODOT" --headless --path game --import >/dev/null 2>&1 || true

step "Compile all scripts"
godot_ok ", 0 failed" --headless --path game res://tests/check_scripts.tscn

step "Unit tests (GUT)"
godot_ok "All tests passed" --headless --path game -s addons/gut/gut_cmdln.gd -gconfig=res://.gutconfig.json -gjunit_xml_file=res://../test-results.xml

step "Translation template is current"
python3 tools/content/extract_strings.py --check

if [[ $QUICK == 0 ]]; then
  step "Balance simulation (112 days)"
  godot_ok "Sim finished.+OK" --headless --path game res://tests/sim/balance_sim.tscn -- --days=112
  step "Casino return-to-player simulation (1M rounds)"
  godot_ok "Casino sim.+OK" --headless --path game res://tests/sim/casino_rtp.tscn -- --rounds=1000000
fi

step "MCP relay self-test"
node server/mcp/test.mjs

step "Nakama runner (command line from the environment, production checks, redaction)"
node --test server/nakama/tests/run_test.mjs

step "nginx site file (nginx -t with dummy certificates, every location live)"
deploy/nginx/test_site.sh

step "Lua modules (syntax, Nakama load check, unit tests incl. signing test vectors)"
luac5.1 -p server/nakama/modules/*.lua
lua5.1 server/nakama/tests/tretu_test.lua
server/nakama/nakama.sh check

step "Tretu integration test (fake issuer + platform, real Nakama, game client)"
TEST_DB="$CHECK_PG/nakama_test" node server/nakama/tests/tretu_integration.mjs

if [[ $QUICK == 0 ]]; then
  step "Start Nakama (database hollowmere_check)"
  psql "postgres://$CHECK_PG/postgres" -qc 'drop database if exists hollowmere_check' -c 'create database hollowmere_check'
  if curl -sf http://127.0.0.1:7350/healthcheck >/dev/null; then echo "something already listens on :7350" >&2; exit 1; fi
  NAKAMA_ALLOW_DEFAULTS=1 NAKAMA_DATABASE_ADDRESS="$CHECK_PG/hollowmere_check" \
    server/nakama/nakama.sh start > nakama.log 2>&1 &
  NAKAMA_PID=$!
  for _ in $(seq 1 60); do curl -sf http://127.0.0.1:7350/healthcheck >/dev/null && break; sleep 2; done
  curl -sf http://127.0.0.1:7350/healthcheck >/dev/null || { tail -40 nakama.log; exit 1; }

  step "Server integration test"
  godot_ok "SERVER TEST DONE, 0 failures" --headless --path game res://tests/net/server_test.tscn -- --require-server
  step "Co-op network test"
  godot_ok "NET TEST DONE, 0 failures" --headless --path game res://tests/net/net_test.tscn
  step "Desync test (host + 3 clients)"
  godot_ok "DESYNC TEST DONE, 0 failures" --headless --path game res://tests/net/desync_test.tscn
fi

printf '\n\033[1;32mAll checks passed.\033[0m\n'
