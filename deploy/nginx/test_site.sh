#!/usr/bin/env bash
# Local test of deploy/nginx/hollowmere.tretu.de.conf without root and without real certificates:
# a copy of the site file with high ports, dummy (self-signed) certificates, a temporary web root
# and fake upstreams for Nakama (:7350) and hollowmere-mcp (:8787). Runs `nginx -t`, starts nginx,
# and checks every location with curl. Needs nginx, openssl, curl and node. Runs on Linux and macOS
# (Homebrew nginx, bash 3.2, BSD sed/sort, LibreSSL).
#
#   deploy/nginx/test_site.sh [path/to/web/build]     (default: a tiny fake build)
set -euo pipefail
command -v nginx >/dev/null || { echo "nginx not installed (Linux: apt install nginx, macOS: brew install nginx)" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_CONF="$HERE/hollowmere.tretu.de.conf"
T="$(mktemp -d)"
NGX_PID=""; FAKE_PID=""
cleanup() {
  [[ -n "$NGX_PID" ]] && kill "$NGX_PID" 2>/dev/null || true
  [[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
free_port() { node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }
P80=$(free_port); P443=$(free_port); PNK=$(free_port); PMCP=$(free_port)

# Web root = only the build. A "checkout" next to it holds secrets that must never be served.
mkdir -p "$T/www/site/auth/callback" "$T/acme/.well-known/acme-challenge" "$T/le/live/hollowmere.tretu.de" "$T/logs" "$T/tmp"
if [[ -n "${1:-}" ]]; then cp -r "$1/." "$T/www/site/"; else
  echo '<!doctype html><title>Hollowmere</title>' > "$T/www/site/index.html"
  echo 'callback page' > "$T/www/site/auth/callback/index.html"
  echo 'wasm' > "$T/www/site/hm-0123abcd.wasm"
fi
echo 'SECRET=checkout' > "$T/www/.env"
echo 'SECRET=inroot' > "$T/www/site/.env"
echo 'acme-token' > "$T/acme/.well-known/acme-challenge/tok"
chmod -R a+rX "$T"   # nginx workers run as an unprivileged user when started by root

# Dummy certificate + the two files certbot normally provides.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=hollowmere.tretu.de" \
  -keyout "$T/le/live/hollowmere.tretu.de/privkey.pem" -out "$T/le/live/hollowmere.tretu.de/fullchain.pem" 2>/dev/null
printf 'ssl_session_cache shared:le_nginx_SSL:1m;\nssl_session_timeout 1440m;\nssl_protocols TLSv1.2 TLSv1.3;\nssl_prefer_server_ciphers off;\n' > "$T/le/options-ssl-nginx.conf"
openssl dhparam -dsaparam -out "$T/le/ssl-dhparams.pem" 2048 2>/dev/null

# The site uses `http2 on;` (nginx 1.25.1+). Older nginx (Ubuntu 24.04: 1.24) gets the equivalent listen parameter.
# version_lt a b: true if version a < b (numeric per dot-separated field; no `sort -V`, which older macOS lacks).
version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); m = split(b, y, "."); if (m > n) n = m
    for (i = 1; i <= n; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 } exit 1 }'
}
LEGACY_HTTP2=()
NGX_VERSION="$(nginx -v 2>&1 | sed -E 's#.*nginx/([0-9.]+).*#\1#')"
if version_lt "$NGX_VERSION" 1.25.1; then
  LEGACY_HTTP2=(-e "/^[[:space:]]*http2 on;/d" -e "s#listen 127.0.0.1:$P443 ssl;#listen 127.0.0.1:$P443 ssl http2;#")
fi
# mime.types: Debian/Ubuntu, Homebrew on Apple silicon, Homebrew on Intel, else next to nginx's
# compiled-in conf-path (`nginx -V`). NGINX_MIME_TYPES overrides the search.
find_mime_types() {
  local f conf
  if [[ -n "${NGINX_MIME_TYPES:-}" ]]; then echo "$NGINX_MIME_TYPES"; return; fi
  for f in /etc/nginx/mime.types /opt/homebrew/etc/nginx/mime.types /usr/local/etc/nginx/mime.types; do
    [[ -f "$f" ]] && { echo "$f"; return; }
  done
  conf="$(nginx -V 2>&1 | tr ' ' '\n' | sed -n 's#^--conf-path=##p' | head -n1)"
  [[ -n "$conf" && -f "$(dirname "$conf")/mime.types" ]] && { echo "$(dirname "$conf")/mime.types"; return; }
  return 1
}
MIME_TYPES="$(find_mime_types)" || { echo "FAIL mime.types not found (looked in /etc/nginx, /opt/homebrew/etc/nginx, /usr/local/etc/nginx and nginx -V --conf-path; set NGINX_MIME_TYPES)"; exit 1; }
[[ -f "$MIME_TYPES" ]] || { echo "FAIL NGINX_MIME_TYPES=$MIME_TYPES does not exist"; exit 1; }
# ${a[@]+"${a[@]}"}: an empty array is "unbound" under set -u in bash < 4.4 (macOS ships 3.2).
sed -e "s#listen 80;#listen 127.0.0.1:$P80;#; s#listen \[::\]:80;##" \
    -e "s#listen 443 ssl;#listen 127.0.0.1:$P443 ssl;#; s#listen \[::\]:443 ssl;##" ${LEGACY_HTTP2[@]+"${LEGACY_HTTP2[@]}"} \
    -e "s#/etc/letsencrypt#$T/le#g; s#/var/www/hollowmere/site#$T/www/site#g; s#root /var/www/html;#root $T/acme;#" \
    -e "s#127.0.0.1:7350#127.0.0.1:$PNK#g; s#127.0.0.1:8787#127.0.0.1:$PMCP#g" "$SITE_CONF" > "$T/site.conf"
grep -q "/var/www/hollowmere/site" "$SITE_CONF" || { echo "FAIL site root is not /var/www/hollowmere/site"; exit 1; }
cat > "$T/nginx.conf" <<EOF
pid $T/nginx.pid;
error_log $T/logs/error.log;
events {}
http {
  access_log off;
  client_body_temp_path $T/tmp; proxy_temp_path $T/tmp; fastcgi_temp_path $T/tmp; uwsgi_temp_path $T/tmp; scgi_temp_path $T/tmp;
  include $MIME_TYPES;
  include $T/site.conf;
}
EOF
nginx -t -c "$T/nginx.conf" -p "$T" 2>&1 | grep -v "http2\" directive is deprecated" || true   # only with the 1.24 fallback
nginx -t -q -c "$T/nginx.conf" -p "$T"

# Fake upstreams: answer with what they received.
cat > "$T/fake.mjs" <<'EOF'
import http from "node:http";
const [nk, mcp] = process.argv.slice(2).map(Number);
for (const [port, name] of [[nk, "nakama"], [mcp, "mcp"]]) {
  http.createServer((req, res) => {
    let n = 0; req.on("data", (c) => (n += c.length));
    req.on("end", () => { res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ upstream: name, method: req.method, url: req.url, bytes: n })); });
  }).listen(port, "127.0.0.1");
}
EOF
node "$T/fake.mjs" "$PNK" "$PMCP" & FAKE_PID=$!
nginx -c "$T/nginx.conf" -p "$T" -g "daemon off;" & NGX_PID=$!
for _ in $(seq 1 50); do curl -sk "https://127.0.0.1:$P443/" -o /dev/null && break; sleep 0.1; done

fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
H="https://127.0.0.1:$P443"
code() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }
hdr() { curl -sk -D - -o /dev/null "$@" | tr -d '\r'; }

check "http redirects to https" '[[ "$(curl -s -o /dev/null -w "%{http_code} %{redirect_url}" "http://127.0.0.1:$P80/x?y=1")" == "301 https://127.0.0.1/x?y=1" ]]'
check "ACME webroot on port 80" '[[ "$(curl -s "http://127.0.0.1:$P80/.well-known/acme-challenge/tok")" == "acme-token" ]]'
check "TLS + HTTP/2" '[[ "$(curl -sk --http2 -o /dev/null -w "%{http_version}" "$H/")" == "2" ]]'
idx=$(hdr "$H/")
check "game page served" '[[ "$(curl -sk "$H/")" == *Hollowmere* ]]'
check "game page: no-cache, HSTS, nosniff, CSP, referrer policy" 'grep -q "^cache-control: no-cache" <<<"$idx" && grep -q "^strict-transport-security: max-age=31536000" <<<"$idx" && grep -q "^x-content-type-options: nosniff" <<<"$idx" && grep -q "^content-security-policy: frame-ancestors" <<<"$idx" && grep -q "^referrer-policy:" <<<"$idx"'
check "dotfiles in the web root are refused" '[[ "$(code "$H/.env")" == "404" && "$(code "$H/.git/config")" == "404" ]]'
check "nothing outside the web root (checkout)" '[[ "$(curl -sk --path-as-is "$H/../.env")" != *checkout* && "$(curl -sk "$H/%2e%2e/.env")" != *checkout* ]]'
check "SPA fallback serves index.html" '[[ "$(curl -sk "$H/some/deep/link")" == *Hollowmere* ]]'
check "/auth/callback page, no-store, no-referrer" '[[ "$(curl -sk "$H/auth/callback?code=x")" == *callback* ]] && hdr "$H/auth/callback" | grep -q "^referrer-policy: no-referrer"'
check "fingerprinted files immutable" 'hdr "$H/hm-0123abcd.wasm" | grep -q "immutable" || [[ -n "${1:-}" ]]'
check "legal redirects to tretu.de" '[[ "$(curl -sk -o /dev/null -w "%{http_code} %{redirect_url}" "$H/datenschutz")" == "308 https://tretu.de/datenschutz" ]]'
h=$(curl -sk -D "$T/h.txt" "$H/api/health"); hh=$(tr -d '\r' < "$T/h.txt")
check "/api/health -> hollowmere-mcp /api/health, no-store, HSTS" '[[ "$h" == *"\"upstream\":\"mcp\""* && "$h" == *"\"url\":\"/api/health\""* ]] && grep -q "^cache-control: no-store" <<<"$hh" && grep -q "^strict-transport-security" <<<"$hh"'
w=$(curl -sk -X POST -H "content-type: application/json" --data '{"a":1}' "$H/api/tretu/webhook?x=1")
check "/api/tretu/webhook POST -> hollowmere-mcp, URI unchanged" '[[ "$w" == *"\"upstream\":\"mcp\""* && "$w" == *"\"method\":\"POST\""* && "$w" == *"\"url\":\"/api/tretu/webhook?x=1\""* ]]'
check "/api/tretu/webhook refuses GET/PUT (405)" '[[ "$(code "$H/api/tretu/webhook")" == "405" && "$(code -X PUT "$H/api/tretu/webhook")" == "405" ]]'
check "/api/tretu/webhook body limit 64k (413)" '[[ "$(head -c 70000 /dev/zero | tr "\0" a | curl -sk -o /dev/null -w "%{http_code}" -X POST --data-binary @- "$H/api/tretu/webhook")" == "413" ]]'
hw=$(hdr -X POST --data '{}' "$H/api/tretu/webhook")
check "/api/tretu/webhook security headers" 'grep -q "^strict-transport-security" <<<"$hw" && grep -q "^x-content-type-options: nosniff" <<<"$hw" && grep -q "^cache-control: no-store" <<<"$hw"'
codes=""; for _ in $(seq 1 75); do codes+="$(code -X POST --data '{}' "$H/api/tretu/webhook") "; done
check "/api/tretu/webhook rate limit (120/min, burst 60) answers 429" '[[ "$codes" == *429* && "$codes" == 200* ]]'
check "Nakama API proxied" '[[ "$(curl -sk "$H/v2/rpc/health")" == *"\"upstream\":\"nakama\""* ]]'
check "sign-in and guest upgrade proxied (rate-limited zone)" '[[ "$(curl -sk -X POST --data "{}" "$H/v2/account/authenticate/custom")" == *nakama* && "$(curl -sk -X POST --data "{}" "$H/v2/account/link/custom")" == *nakama* ]]'
check "Nakama liveness" '[[ "$(curl -sk "$H/healthcheck")" == *"\"url\":\"/healthcheck\""* ]]'

echo "NGINX SITE TEST DONE, $fails failures"
exit $(( fails > 0 ))
