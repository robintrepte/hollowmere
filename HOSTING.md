# Host Hollowmere (Hetzner, PM2 + nginx, shared Postgres, no Docker)

Production runs on the Tretu Hetzner server next to the other Tretu apps:

| Piece | Where | Name / port |
|---|---|---|
| Web build (static) | `/var/www/hollowmere`, served by nginx | `https://hollowmere.tretu.de` |
| Nakama (accounts, cloud saves, co-op relay, Lua module) | PM2 | `hollowmere-nakama`, API `127.0.0.1:7350`, console `127.0.0.1:7351` |
| MCP relay for AI helpers, also `/api/health` | PM2 | `hollowmere-mcp`, `127.0.0.1:8787`, `https://mcp.hollowmere.tretu.de` |
| Database | the shared Postgres server | database `nakama`, role `nakama` |
| Git checkout (server code, configs) | `/srv/hollowmere` | owned by the deploy user |

Every command below runs as written after you fill in step 0. Commands marked **(root)** need `sudo`;
everything else runs as the deploy user that owns the other PM2 apps.

## 0. Variables

```bash
export DOMAIN=hollowmere.tretu.de
export MCP_DOMAIN=mcp.hollowmere.tretu.de
export SERVER_IP=203.0.113.10          # Hetzner server IPv4
export DEPLOY_USER=deploy              # the user that runs PM2 for the Tretu apps
export APP_DIR=/srv/hollowmere         # git checkout
export SITE_DIR=/var/www/hollowmere    # web build
export NAKAMA_VERSION=3.41.0           # https://github.com/heroiclabs/nakama/releases
```

## 1. DNS

| Type | Name | Value |
|---|---|---|
| A | `hollowmere` | `$SERVER_IP` |
| A | `mcp.hollowmere` | `$SERVER_IP` |
| AAAA | both | the server's IPv6, if it has one |

```bash
dig +short A "$DOMAIN" "$MCP_DOMAIN"   # both must print $SERVER_IP before certbot
```

## 2. Packages (root, once per server)

The Tretu server usually has these already (nginx, certbot, Postgres, Node 22, PM2). Skip what exists.

```bash
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx postgresql rsync curl brotli ufw
# Node 22 + PM2 (shared by all Tretu apps)
command -v pm2 || sudo npm install -g pm2
sudo ufw allow OpenSSH && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw --force enable
```

Nakama's ports stay on `127.0.0.1` (`server/nakama/hollowmere.yml`). Never open 7350, 7351 or 8787.

## 3. Database on the shared Postgres (root)

```bash
export NAKAMA_DB_PASSWORD=$(openssl rand -hex 24)
echo "keep this for step 5: $NAKAMA_DB_PASSWORD"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE nakama LOGIN PASSWORD '$NAKAMA_DB_PASSWORD';
CREATE DATABASE nakama OWNER nakama;
SQL
```

## 4. Nakama binary (root)

```bash
cd /tmp
curl -fsSLO "https://github.com/heroiclabs/nakama/releases/download/v${NAKAMA_VERSION}/nakama-${NAKAMA_VERSION}-linux-amd64.tar.gz"
sha256sum "nakama-${NAKAMA_VERSION}-linux-amd64.tar.gz"   # compare with the checksum on the release page
sudo mkdir -p /opt/nakama
sudo tar -xzf "nakama-${NAKAMA_VERSION}-linux-amd64.tar.gz" -C /opt/nakama
sudo chmod 755 /opt/nakama/nakama
/opt/nakama/nakama --version
```

Upgrading Nakama later: install the new tarball the same way, then `server/nakama/nakama.sh check`
and `pm2 reload hollowmere-nakama` (the start script runs `nakama migrate up` first).

## 5. Checkout and secrets

```bash
sudo mkdir -p "$APP_DIR" "$SITE_DIR" && sudo chown "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR" "$SITE_DIR"
git clone https://github.com/robintrepte/hollowmere.git "$APP_DIR"
cd "$APP_DIR"

# PM2 env (MCP relay, Nakama binary path)
cp server/.env.example server/.env && chmod 600 server/.env
# Nakama secrets + Tretu runtime env
cp server/nakama/local.example.yml server/nakama/local.yml && chmod 600 server/nakama/local.yml
```

Fill in (generate each secret with `openssl rand -hex 24`; never commit these files):

| File | Key | Value |
|---|---|---|
| `server/nakama/local.yml` | `database.address` | `nakama:<NAKAMA_DB_PASSWORD>@127.0.0.1:5432/nakama` |
| | `session.encryption_key`, `session.refresh_encryption_key` | random |
| | `runtime.http_key` | random, **same** as `NAKAMA_HTTP_KEY` below |
| | `console.username`, `console.password` | Nakama console login (not a game account) |
| | `social.apple.bundle_id` | Apple Services ID if Apple sign-in is used |
| | `runtime.env` `TRETU_*` | see step 10 (leave empty = off) |
| `server/.env` | `NAKAMA_HTTP_KEY` | same as `runtime.http_key` |
| | `NAKAMA_BIN` | `/opt/nakama/nakama` |
| | `MCP_PUBLIC_URL` | `https://$MCP_DOMAIN` |

The Nakama **server key** `hollowmere_dev` is in `server/nakama/hollowmere.yml` and in every game
build (`hollowmere/server/key` in `game/project.godot`). It is not a secret; change both or neither.

Check the Lua modules and migrate:

```bash
server/nakama/nakama.sh check      # loads every module once, prints nothing when fine
server/nakama/nakama.sh migrate    # nakama migrate up
```

## 6. PM2

```bash
cd "$APP_DIR"
pm2 start ecosystem.config.cjs
pm2 save
pm2 status                          # hollowmere-nakama and hollowmere-mcp: online
curl -sf http://127.0.0.1:7350/healthcheck && echo
curl -sf http://127.0.0.1:8787/api/health && echo
# {"status":"ok","app":"hollowmere","version":"1.0.0","time":"…","checks":{"nakama":"ok","db":"ok"}}
```

If PM2 is not yet started at boot on this server: `pm2 startup` and run the command it prints (root).
Logs: `pm2 logs hollowmere-nakama --lines 100`.

## 7. nginx and TLS (root)

```bash
cd "$APP_DIR"
sudo cp deploy/nginx/hollowmere.tretu.de.conf deploy/nginx/mcp.hollowmere.tretu.de.conf /etc/nginx/sites-available/
sudo ln -sfn ../sites-available/hollowmere.tretu.de.conf /etc/nginx/sites-enabled/hollowmere.tretu.de.conf
sudo ln -sfn ../sites-available/mcp.hollowmere.tretu.de.conf /etc/nginx/sites-enabled/mcp.hollowmere.tretu.de.conf
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d "$DOMAIN" --redirect --agree-tos -m admin@tretu.de --non-interactive
sudo certbot --nginx -d "$MCP_DOMAIN" --redirect --agree-tos -m admin@tretu.de --non-interactive
```

What the site file does:

| Path | Goes to |
|---|---|
| `/v2/*`, `/ws` | Nakama `127.0.0.1:7350` (websocket upgrade on `/ws`, no gzip on the proxy) |
| `/healthcheck` | Nakama's liveness check |
| `/api/health` | contract health JSON from `hollowmere-mcp` (Nakama health RPC incl. a DB query); 503 when not ok |
| `/privacy`, `/datenschutz`, `/terms`, `/agb`, `/impressum` | 308 to `https://tretu.de/datenschutz`, `/agb`, `/impressum` |
| `/auth/callback` | the Tretu-Konto sign-in callback page (`no-store`, `no-referrer`) |
| `/hm-*` | fingerprinted engine files, `immutable`, `application/wasm` for `.wasm`, `gzip_static` |
| everything else | `index.html` (`no-cache`) |

The web export is single-threaded: no COOP/COEP headers. Do not add them (COEP breaks Google
sign-in, `COOP: same-origin` cuts the sign-in popups off from the game).
For Brotli: `sudo apt install libnginx-mod-http-brotli-static` and uncomment `brotli_static on;`.

## 8. Web build

CI builds it on every push (artifact `hollowmere-web`) and deploys it on `v*` tags (step 12).
By hand, on a machine with Godot 4.7.2 and its export templates:

```bash
sed -i.bak "s/%HOLLOWMERE_DOMAIN%/$DOMAIN/" game/project.godot
# Optional: Tretu-Konto button (step 10)
# sed -i 's|^auth_issuer=""|auth_issuer="https://auth.tretu.de"|' game/project.godot
godot --headless --path game --export-release "Web" "$PWD/build/web/index.html"
mv game/project.godot.bak game/project.godot          # never commit a live domain

# Public per-deployment values (each optional; unset = that feature off)
GOOGLE_CLIENT_ID= APPLE_CLIENT_ID= DISCORD_CLIENT_ID= \
UMAMI_SRC=https://stats.tretu.de/script.js UMAMI_WEBSITE_ID=<uuid> \
  python3 tools/release/inject_web_config.py build/web/index.html
tools/release/fingerprint_web.sh build/web     # hm-<hash> names, PWA files, legal redirects, /auth/callback
tools/release/precompress_web.sh build/web
rsync -az --delete build/web/ "$DEPLOY_USER@$SERVER_IP:$SITE_DIR/"
```

## 9. Release clients point at the live server

Desktop and web release builds read `hollowmere/server/host.release` (`%HOLLOWMERE_DOMAIN%` in the
repo). CI fills it from the repository variable `HOLLOWMERE_DOMAIN` = `hollowmere.tretu.de`.

## 10. Tretu ecosystem (all optional, all off by default)

Nothing here changes a build or a server until it is configured. Email, guest, Google, Apple and
Discord keep working either way.

**Mit Tretu-Konto anmelden** needs both sides:

1. auth.tretu.de: client `hollowmere`, public (PKCE only, no secret), redirect URIs
   `https://hollowmere.tretu.de/auth/callback` and `http://127.0.0.1/callback` (any port, RFC 8252).
   The issuer must allow CORS from `https://hollowmere.tretu.de` on discovery and the token endpoint
   (the web build exchanges the code in the browser).
2. Server: `TRETU_AUTH_ISSUER=https://auth.tretu.de` in `runtime.env` of `server/nakama/local.yml`,
   then `pm2 reload hollowmere-nakama`.
3. Game builds: GitHub variable `TRETU_AUTH_ISSUER=https://auth.tretu.de` (CI writes it into
   `tretu/auth_issuer` in `game/project.godot`; `tretu/client_id` is already `hollowmere`).
   Builds without it show no Tretu button.

How it works: desktop builds open the system browser and receive the code on
`http://127.0.0.1:<random port>/callback`; the web build uses a popup (or a full-page redirect
when popups are blocked) to `/auth/callback`. Both use PKCE S256 + state + nonce, then call
Nakama `AuthenticateCustom` with `vars.tretu_token`. The server asks the issuer's userinfo endpoint
(from discovery, cached for an hour) who that is and signs into the account `tretu:<sub>`; the
username comes from `preferred_username` (with a numeric suffix if taken). Desktop keeps the refresh
token encrypted in `user://tretu.cfg` for silent sign-in. The access token never lands in the
Nakama session (only `tretu_sub` does).

**Discord players keep their farms.** If the Tretu claims carry `discord_id` and the player has an
old `discord:<id>` account but no `tretu:<sub>` account yet, that account is re-keyed to
`tretu:<sub>` (one guarded, idempotent `UPDATE users SET custom_id …`), so the same Nakama user
(saves, profile, AI-helper tokens) continues. A marker in storage `tretu_links/discord:<id>` makes
the old Discord button sign into the same account afterwards. If both accounts already exist,
nothing is merged automatically (see the Nakama console: Accounts → search `discord:`).

**Platform events and presence** need, in `runtime.env`:

```yaml
    - "TRETU_PLATFORM_URL=https://tretu.de"
    - "TRETU_APP_ID=hollowmere"
    - "TRETU_APP_SECRET=<the hollowmere secret from TRETU_APPS_JSON on tretu.de>"
```

Only players signed in with a Tretu-Konto are reported. Requests are signed (`x-tretu-*` headers,
HMAC-SHA256, contract §3; the module checks the contract test vector at every start and logs
`Tretu signing self-test ok`).

| Sent | When |
|---|---|
| `stat.increment` `hollowmere.days.played` | a cloud save shows more in-game days than the last one (per slot, max 14 per save, first save = baseline) |
| `stat.increment` `hollowmere.creatures.befriended` | a cloud save shows more befriended Wildlings (max 40 per save) |
| `game.finished` `{game:"battle", result:"win"\|"loss", mode:"bot"\|"multiplayer"}` | the game reports a finished battle (RPC `tretu_report_battle`, rate-limited) |
| `PUT /presence/<sub>` `{status:"playing", activity:"Hollowmere", joinUrl?}` | every 60 s while the game is open (RPC `tretu_heartbeat`); `joinUrl` = `https://hollowmere.tretu.de/?join=<code>` while hosting co-op |
| `DELETE /presence/<sub>` | sign-out (RPC `tretu_offline`) |

Saves only queue events (storage `tretu_outbox`); the heartbeat sends them in batches with a 5 s
timeout and keeps them for retries for up to 24 h. A slow or offline platform never blocks a save.

## 11. Analytics (optional)

GitHub variables `UMAMI_SRC` (e.g. `https://stats.tretu.de/script.js`) and `UMAMI_WEBSITE_ID`.
`tools/release/inject_web_config.py` adds the Umami tag to the web build only when both are set.

## 12. GitHub Actions

`.github/workflows/build.yml` tests every push (GUT, Lua, Tretu integration test against a real
Nakama + Postgres, network tests) and exports Windows, macOS and Web. On `v*` tags, `deploy-web`
rsyncs the web build to `$SITE_DIR`, checks out the tag in `$APP_DIR`, runs
`server/nakama/nakama.sh check` and `pm2 reload ecosystem.config.cjs --update-env`, then checks
`/api/health`.

| Name | Kind | Value |
|---|---|---|
| `DEPLOY_HOST` | secret | server hostname or IP |
| `DEPLOY_SSH_KEY` | secret | private ed25519 key of the deploy user |
| `DEPLOY_USER`, `DEPLOY_APP_DIR`, `DEPLOY_SITE_DIR` | variables | optional, default `deploy`, `/srv/hollowmere`, `/var/www/hollowmere` |
| `HOLLOWMERE_DOMAIN` | variable | `hollowmere.tretu.de` |
| `TRETU_AUTH_ISSUER` | variable | optional, `https://auth.tretu.de` (step 10) |
| `UMAMI_SRC`, `UMAMI_WEBSITE_ID` | variables | optional (step 11) |
| `GOOGLE_CLIENT_ID`, `APPLE_CLIENT_ID`, `DISCORD_CLIENT_ID` | secrets | optional (step 14) |

## 13. Deploy an update

Same steps as every Tretu app (CI does this on tags):

```bash
cd /srv/hollowmere
git pull --ff-only                       # or: git fetch --tags && git checkout --detach vX.Y.Z
# no npm ci: the MCP relay has no dependencies
server/nakama/nakama.sh check            # Lua modules load
server/nakama/nakama.sh migrate          # nakama migrate up (also runs on every PM2 start)
# build = the web export from CI, rsynced to /var/www/hollowmere (step 8)
pm2 reload ecosystem.config.cjs --update-env
curl -sf https://hollowmere.tretu.de/api/health
```

Rollback: check out the previous tag and reload; rsync the previous web artifact. Engine files are
named `hm-<content hash>.*`, so browsers cannot keep a stale wasm under a new name.

## 14. Social sign-in (optional)

Each button appears only when its public client id is injected into the page (step 8) and the device
can use it (Apple only on Apple devices).

- **Google**: OAuth client "Web application", JavaScript origin `https://$DOMAIN`.
- **Apple**: Services ID with Sign in with Apple, return URL `https://$DOMAIN/`; also
  `social.apple.bundle_id` in `local.yml` (Nakama checks the audience).
- **Discord**: OAuth2 redirect `https://$DOMAIN/`.

Consent screens can use the Tretu legal pages: `https://tretu.de/datenschutz`, `https://tretu.de/agb`.

## 15. Backups

```bash
crontab -e
# 04:12 daily, keeps one dump per weekday
12 4 * * * pg_dump -h 127.0.0.1 -U nakama nakama | gzip > /srv/backups/hollowmere-$(date +\%a).sql.gz
```

Put the password in `~/.pgpass` (`127.0.0.1:5432:nakama:nakama:<password>`, `chmod 600`) and copy
the dumps off the server now and then. If the shared Postgres already has a server-wide backup,
this database is included there.

## 16. Moving from the old Docker setup

The data is in the old `hollowmere-postgres-1` container. One-time move into the shared Postgres:

```bash
docker exec hollowmere-postgres-1 pg_dump -U nakama -Fc nakama > /tmp/nakama.dump   # old box
# after steps 3-5 on the new setup (do not start PM2 yet):
pg_restore -h 127.0.0.1 -U nakama -d nakama --no-owner /tmp/nakama.dump
server/nakama/nakama.sh migrate
pm2 start ecosystem.config.cjs
docker compose -f /srv/hollowmere/docker-compose.yml down   # old stack, once the new one is healthy
```

Keep the old `NAKAMA_SESSION_KEY` / `NAKAMA_REFRESH_KEY` / `NAKAMA_HTTP_KEY` values from the old
`.env` in `local.yml` so signed-in players stay signed in.

## 17. Smoke the live site

- [ ] `https://hollowmere.tretu.de/` shows the title screen; Datenschutz / AGB / Impressum open tretu.de
- [ ] Guest login → New farm → walk, sleep, reload → Continue
- [ ] With Tretu on: "Mit Tretu-Konto anmelden" on web and desktop; `pm2 logs hollowmere-nakama` shows no Tretu warnings
- [ ] Phone landscape: on-screen controls; Add to Home Screen opens full screen
- [ ] `curl -sf https://hollowmere.tretu.de/api/health` is `"status":"ok"`
- [ ] Nakama console through a tunnel only: `ssh -L 7351:127.0.0.1:7351 $DEPLOY_USER@$SERVER_IP`, then `http://127.0.0.1:7351`

## 18. If something is wrong

| Symptom | Check |
|---|---|
| `/healthcheck` or `/v2` 502 | `pm2 status`, `pm2 logs hollowmere-nakama`; `local.yml` missing or DB login wrong |
| `/api/health` 503 | `checks.db` = Postgres down or `database.address`; `checks.nakama` = Nakama down or `NAKAMA_HTTP_KEY` ≠ `runtime.http_key` |
| Game cannot reach the server | release build still has `%HOLLOWMERE_DOMAIN%`, or `http://` after certbot's redirect |
| Co-op connects then drops | `/ws` upgrade headers; compare with `deploy/nginx/hollowmere.tretu.de.conf` |
| Tretu button missing | build without `TRETU_AUTH_ISSUER` (step 10) |
| "Tretu sign-in is not enabled on this server." | `TRETU_AUTH_ISSUER` missing in `local.yml`, or Nakama not reloaded |
| Tretu web sign-in fails right away | CORS on the issuer's discovery / token endpoint, or redirect URI not registered |
| Log `Tretu platform POST /api/v1/events -> 401` | `TRETU_APP_SECRET` differs from `TRETU_APPS_JSON.hollowmere.secret` on tretu.de, or clock skew > 300 s |
| `nginx -t` fails on `brotli_static` | leave it commented |
| certbot "failed to authenticate" | DNS not pointing here yet, or port 80 blocked |

## 19. AI helper relay

`hollowmere-mcp` serves `https://mcp.hollowmere.tretu.de` (step 7). Players create tokens in the
game; see `docs/agents.md`.
