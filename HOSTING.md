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
export NAKAMA_SHA256=71aea14384b097e043917d0b1e8c3799594064acbab01853e71ea10d80624ce2   # see "Checksums" below
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
echo "${NAKAMA_SHA256}  nakama-${NAKAMA_VERSION}-linux-amd64.tar.gz" | sha256sum -c -   # must print OK
sudo mkdir -p /opt/nakama
sudo tar -xzf "nakama-${NAKAMA_VERSION}-linux-amd64.tar.gz" -C /opt/nakama
sudo chmod 755 /opt/nakama/nakama
/opt/nakama/nakama --version
```

Upgrading Nakama later: install the new tarball the same way, then `server/nakama/nakama.sh check`
and `pm2 reload hollowmere-nakama` (the start script runs `nakama migrate up` first). Update the
pinned checksum here and in `.github/workflows/build.yml` in the same commit.

### Checksums

| Download | Algorithm | Value | Source |
|---|---|---|---|
| `nakama-3.41.0-linux-amd64.tar.gz` | SHA-256 | `71aea14384b097e043917d0b1e8c3799594064acbab01853e71ea10d80624ce2` | Heroic Labs publishes **no** checksum file for this release (`checksums.txt` and similar are 404, the GitHub API with the asset digests was not reachable from our build machine). This is the hash of the tarball downloaded from the GitHub release on 2026-11-02; the binary in it reports `3.41.0+cab8af58`, the commit of the `v3.41.0` tag. Before trusting a new version, compare with the asset digest GitHub shows on the release page. |
| `Godot_v4.7.2-stable_linux.x86_64.zip` | SHA-512 (official) | `9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65` | `SHA512-SUMS.txt` of the Godot 4.7.2-stable release (Godot publishes SHA-512, not SHA-256) |
| `Godot_v4.7.2-stable_export_templates.tpz` | SHA-512 (official) | `ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079` | same file |

CI checks all three before using them (`sha256sum -c` / `sha512sum -c`). For other files (macOS
editor, other Nakama platforms) compare with the release's `SHA512-SUMS.txt` (Godot) or the GitHub
asset digest (Nakama) by hand.

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
| `/v2/account/authenticate/*` | Nakama, **rate-limited**: 30 sign-ins per minute per IP, burst 30, then `429` (zone `hollowmere_auth`, declared at the top of the file) |
| `/v2/*`, `/ws` | Nakama `127.0.0.1:7350` (websocket upgrade on `/ws`, no gzip on the proxy) |
| `/healthcheck` | Nakama's liveness check |
| `/api/health` | contract health JSON from `hollowmere-mcp` (Nakama health RPC incl. a DB query); 503 when not ok |
| `/privacy`, `/datenschutz`, `/terms`, `/agb`, `/impressum` | 308 to `https://tretu.de/datenschutz`, `/agb`, `/impressum` |
| `/auth/callback` | the Tretu-Konto sign-in callback page (`no-store`, `no-referrer`) |
| `/hm-*` | fingerprinted engine files, `immutable`, `application/wasm` for `.wasm`, `gzip_static` |
| everything else | `index.html` (`no-cache`) |

Every response carries `X-Content-Type-Options: nosniff` and `Strict-Transport-Security` (only
honoured over HTTPS); the game page and `/auth/callback` also `Content-Security-Policy:
frame-ancestors 'none'` (no framing of the game or its sign-in). nginx does not inherit
`add_header` into a location that sets its own, so the file repeats them per location; keep that
when you add a location.

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
username comes from `preferred_username` (with a numeric suffix if taken). The access token never
lands in the Nakama session (only `tretu_sub` does), and Nakama never logs it.

Tokens on the player's device:

| Build | Kept | Not kept |
|---|---|---|
| Desktop (Windows, macOS, Steam) | Tretu refresh token, encrypted in `user://tretu.cfg` with a key bound to the device (`OS.get_unique_id()`), for silent sign-in; revoked at the issuer on sign-out | access token (memory only) |
| Web | nothing from Tretu: it asks for `openid profile email tretu` (no `offline_access`), so no refresh token is issued; the PKCE verifier lives in `localStorage` only until the callback (stale ones are removed on the next page load) | access token (handed to Nakama once, then cleared) |
| Both | the Nakama session (`user://session.cfg`), like every other sign-in | |

If auth.tretu.de is down, Tretu sign-in answers "Die Tretu-Anmeldung ist gerade nicht erreichbar"
(Nakama remembers a failed discovery for 15 s instead of waiting on every attempt); players who are
already signed in keep playing, because their Nakama session does not depend on the issuer.

**Discord and Steam players keep their farms.** The `discord_id` and `steam_id` claims are kept
server-side (`tretu_identity/<sub>`, not readable by players); `steam_id` is also written to the
account metadata (`metadata.steam_id`, removed again when the player unlinks Steam in Mein Konto).
If the player has an old account and no `tretu:<sub>` account yet, that account is re-keyed to
`tretu:<sub>` (one guarded, idempotent `UPDATE users SET custom_id …`), so the same Nakama user
(saves, profile, AI-helper tokens) continues:

| Old account | Recognised by |
|---|---|
| Discord | custom id `discord:<discord_id>` |
| Steam | `users.steam_id = <steam_id>` (Nakama's native Steam auth) or custom id `steam:<steam_id>`. Hollowmere has no Steam sign-in today (Steam builds use the Tretu-Konto, see RELEASE.md), so this only matters if one is added later. |

A marker in storage `tretu_links/<provider>:<id>` makes the old Discord button sign into the
Tretu-Konto's farm afterwards.

**Choose a farm (both accounts exist).** When the player already has a `tretu:<sub>` account *and*
an old Discord/Steam account, nothing is merged on its own. After signing in, the game shows
"Wähle deine Farm" with the cloud saves of each account (RPC `tretu_farm_choice`), and the player
keeps one (RPC `tretu_farm_choose`, also reachable later from the account panel). The switch is one
SQL statement (a `DO` block, so all or nothing): every other account gets the custom id
`archived:<user id>`, loses its Steam id, is disabled (its sessions end), and an archive record is
written (`tretu_archive/<user id>`: sub, old custom id, old Steam id, time). The kept account becomes
`tretu:<sub>`. Each update is guarded by what the player was shown, so a concurrent change aborts
the whole switch ("Deine Konten haben sich inzwischen geändert"); choosing the active farm again is
a no-op. When the kept farm is another Nakama user, the RPC returns a fresh session for it (desktop
builds then swap it for a full session from the stored Tretu login; on the web it lasts a day, then
the player signs in again). Archived farms are **never deleted** by the game and can be restored from
the same menu for 90 days (which archives the farm played at that time).

To actually remove archives older than 90 days (data minimisation), run the purge RPC with the HTTP
key, e.g. daily from the deploy user's crontab (`dryRun: true` only counts):

```bash
# 04:31 daily; reads NAKAMA_HTTP_KEY from server/.env
31 4 * * * . /srv/hollowmere/server/.env && curl -sf -X POST "http://127.0.0.1:7350/v2/rpc/tretu_archive_purge?http_key=$NAKAMA_HTTP_KEY&unwrap" -d '{}' >/dev/null
```

Players cannot call it. Restore by hand (Nakama console or psql) is possible as long as the archive
row exists: `SELECT key, value FROM storage WHERE collection = 'tretu_archive';`.

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
After a timeout or `5xx`, Nakama skips the platform for `TRETU_PLATFORM_BACKOFF_SEC` (default 15 s,
`0` = off) instead of letting every player wait on it again; queued events go out with the next
heartbeat after that.

**In-game Tretu menu.** Players signed in with a Tretu-Konto see their **Tretu-Credits** balance and
**unread notifications** in the account panel (with buttons to `https://tretu.de/wallet` and
`https://tretu.de/benachrichtigungen`, Mein Konto and their profile) and as `· 120 TC · 3 neu` next to
their name on the title screen. The game calls RPC `tretu_account`; Nakama reads
`GET /api/v1/wallet/<sub>` and `GET /api/v1/users/<sub>/notifications/count` from the platform,
signed with `TRETU_APP_SECRET` (the secret never reaches the game), 3 s timeout each.

| Case | What the player sees |
|---|---|
| normal | values cached per player for 60 s; opening the panel asks for fresh ones at most every 15 s |
| platform down / slow | the last good value for up to 30 min, with "Stand von vor N Min.: tretu.de ist gerade nicht erreichbar", else "tretu.de ist gerade nicht erreichbar" |
| platform does not know the sub (`404`) | the same note, without starting the backoff |
| `TRETU_PLATFORM_URL` or secret missing | "Tretu-Credits und Benachrichtigungen sind auf diesem Server nicht eingerichtet." |

Rate limits (per player and Nakama node): `tretu_account` 20 platform reads per minute on top of the
cache, `tretu_farm_choice` 12 and `tretu_farm_choose` 5 calls per minute (`429` after that),
`tretu_report_battle` one per 8 s and 200 per day, `tretu_heartbeat` one per 30 s; sign-ins 30 per
minute per IP in nginx.

## 11. Analytics (optional)

GitHub variables `UMAMI_SRC` (e.g. `https://stats.tretu.de/script.js`) and `UMAMI_WEBSITE_ID`.
`tools/release/inject_web_config.py` adds the Umami tag to the web build only when both are set.

## 12. GitHub Actions

`.github/workflows/build.yml` runs on every pull request and on pushes to `main` (and `v*` tags): script
compile check, GUT, translation template check, balance + casino simulations, MCP relay self-test,
Lua unit tests + `nakama.sh check`, the Tretu integration test (fake issuer + platform, the official
Nakama 3.41.0 binary, a `postgres:16` service container, and the game client test
`tests/net/tretu_client_test.tscn` against it), the server / co-op / desync tests, then the
Windows, macOS and Web exports. Godot and Nakama downloads are checked against the pinned checksums
(§4). **GitHub Actions must be enabled for the repository** (Settings → Actions → General → "Allow all
actions") and the account needs Actions minutes; the workflow has not run on GitHub since it was
last changed, so check the first run after enabling it. On `v*` tags, `deploy-web`
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
- [ ] With the platform on: the account panel shows Tretu-Credits and notifications, and the buttons open tretu.de/wallet and tretu.de/benachrichtigungen
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
| Tretu menu always says "nicht erreichbar" | `pm2 logs hollowmere-nakama` for `Tretu platform GET /api/v1/wallet/…`: `0` = tretu.de unreachable from the server, `401` = secret/clock as above |
| Player "lost" a farm after choosing | it is archived, not gone: restore it in the game (account panel → Archivierte Farmen) within 90 days, or find it with `SELECT key, value FROM storage WHERE collection = 'tretu_archive'` |
| Sign-in says "too many tries" (`429`) | nginx `hollowmere_auth` limit (30/min per IP); raise `rate`/`burst` at the top of the site file if a venue shares one IP |
| `nginx -t` fails on `brotli_static` | leave it commented |
| certbot "failed to authenticate" | DNS not pointing here yet, or port 80 blocked |

## 19. AI helper relay

`hollowmere-mcp` serves `https://mcp.hollowmere.tretu.de` (step 7). Players create tokens in the
game; see `docs/agents.md`.
