# Host Hollowmere (Hetzner, PM2 + nginx, shared Postgres, no Docker)

Production runs on the Tretu Hetzner server next to the other Tretu apps:

| Piece | Where | Name / port |
|---|---|---|
| Web build (static) | `/var/www/hollowmere/site` (only the build; nginx serves nothing else), served by nginx | `https://hollowmere.tretu.de` |
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
export SITE_DIR=/var/www/hollowmere/site   # web build ONLY (nginx root; never the checkout)
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
pinned checksum here and in `tools/ci/check.sh` in the same commit.

### Checksums

| Download | Algorithm | Value | Source |
|---|---|---|---|
| `nakama-3.41.0-linux-amd64.tar.gz` | SHA-256 | `71aea14384b097e043917d0b1e8c3799594064acbab01853e71ea10d80624ce2` | Heroic Labs publishes **no** checksum file for this release (`checksums.txt` and similar are 404, the GitHub API with the asset digests was not reachable from our build machine). This is the hash of the tarball downloaded from the GitHub release on 2026-11-02; the binary in it reports `3.41.0+cab8af58`, the commit of the `v3.41.0` tag. Before trusting a new version, compare with the asset digest GitHub shows on the release page. |
| `Godot_v4.7.2-stable_linux.x86_64.zip` | SHA-512 (official) | `9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65` | `SHA512-SUMS.txt` of the Godot 4.7.2-stable release (Godot publishes SHA-512, not SHA-256) |
| `Godot_v4.7.2-stable_export_templates.tpz` | SHA-512 (official) | `ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079` | same file |

`tools/ci/check.sh` checks the Nakama tarball before using it; check the Godot files the same way when you install them (`sha256sum -c` / `sha512sum -c`). For other files (macOS
editor, other Nakama platforms) compare with the release's `SHA512-SUMS.txt` (Godot) or the GitHub
asset digest (Nakama) by hand.

## 5. Checkout and secrets

```bash
sudo mkdir -p "$APP_DIR" "$SITE_DIR" && sudo chown "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR" "$SITE_DIR"
git clone https://github.com/robintrepte/hollowmere.git "$APP_DIR"
cd "$APP_DIR"

# PM2 env (MCP relay, Nakama binary path)
cp server/.env.example server/.env && chmod 600 server/.env
```

Fill in `server/.env` (generate each secret with `openssl rand -hex 24`; never commit it). Everything
secret lives there: PM2 (`ecosystem.config.cjs`) hands the keys to the two processes, and
`server/nakama/run.mjs` passes Nakama's keys and the Tretu runtime env to Nakama as command-line
flags (nothing is written to a file; every logged command line shows `***` instead of the values).

| Key | Value |
|---|---|
| `NAKAMA_BIN` | `/opt/nakama/nakama` |
| `NAKAMA_DATABASE_ADDRESS` | `nakama:<NAKAMA_DB_PASSWORD>@127.0.0.1:5432/nakama` |
| `NAKAMA_HTTP_KEY` | random (Nakama `runtime.http_key`; the MCP relay uses the same value) |
| `NAKAMA_SESSION_ENCRYPTION_KEY`, `NAKAMA_SESSION_REFRESH_ENCRYPTION_KEY` | random (changing them signs every player out) |
| `NAKAMA_CONSOLE_USERNAME`, `NAKAMA_CONSOLE_PASSWORD`, `NAKAMA_CONSOLE_SIGNING_KEY` | Nakama console login (not a game account; not `admin`) and its token key |
| `TRETU_AUTH_ISSUER` | **required**: `https://auth.tretu.de` (the Tretu-Konto is the only account sign-in) |
| `TRETU_PLATFORM_URL`, `TRETU_APP_ID`, `TRETU_APP_SECRET`, `HOLLOWMERE_PUBLIC_URL`, `TRETU_PLATFORM_BACKOFF_SEC` | step 10 (platform part off while URL or secret is empty; `TRETU_APP_SECRET` is also the webhook secret of `hollowmere-mcp`) |
| `MCP_PUBLIC_URL` | `https://$MCP_DOMAIN` |

`run.mjs` **refuses to start** (and PM2 shows why in `pm2 logs hollowmere-nakama`) while any
`NAKAMA_*` key above is missing, still a Nakama default (`defaulthttpkey`, `defaultencryptionkey`,
`defaultsigningkey`, `admin`/`password`, …) or a `CHANGE_ME` placeholder, or while
`TRETU_AUTH_ISSUER` is missing. `NAKAMA_ALLOW_DEFAULTS=1` lifts that for dev and tests only.
`server/nakama/local.yml` is optional now (other Nakama options only, see `local.example.yml`); on
a server that still has one with keys in it, move them to `server/.env`: the values in the
environment win, and the start is refused until they are there. `server/nakama/nakama.sh args`
prints the (redacted) command line and any problems.

The Nakama **server key** `hollowmere_dev` is in `server/nakama/hollowmere.yml` and in every game
build (`hollowmere/server/key` in `game/project.godot`). It is not a secret; change both or neither.

Check the Lua modules and migrate:

```bash
server/nakama/nakama.sh check      # loads every module once, prints nothing when fine
server/nakama/nakama.sh args       # the redacted Nakama command line; lists problems (missing keys)
server/nakama/nakama.sh migrate    # nakama migrate up (same keys and checks as start)
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

The game site file is complete (TLS server block included), so its certificate is fetched first,
through the default site's webroot `/var/www/html` (Ubuntu's nginx default site serves it on port 80;
later renewals go through the ACME location of the site file itself):

```bash
cd "$APP_DIR"
sudo mkdir -p /var/www/html "$SITE_DIR"
sudo certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --agree-tos -m admin@tretu.de --non-interactive
test -f /etc/letsencrypt/options-ssl-nginx.conf || sudo cp /usr/lib/python3/dist-packages/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf /etc/letsencrypt/
test -f /etc/letsencrypt/ssl-dhparams.pem || sudo openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
sudo cp deploy/nginx/hollowmere.tretu.de.conf deploy/nginx/mcp.hollowmere.tretu.de.conf /etc/nginx/sites-available/
sudo ln -sfn ../sites-available/hollowmere.tretu.de.conf /etc/nginx/sites-enabled/hollowmere.tretu.de.conf
sudo ln -sfn ../sites-available/mcp.hollowmere.tretu.de.conf /etc/nginx/sites-enabled/mcp.hollowmere.tretu.de.conf
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d "$MCP_DOMAIN" --redirect --agree-tos -m admin@tretu.de --non-interactive
sudo certbot renew --dry-run      # renewals use the webroot for $DOMAIN
```

Do **not** run `certbot --nginx` on `hollowmere.tretu.de.conf` (it already has its TLS block). The
web root is `/var/www/hollowmere/site` and nothing else: the checkout (with `server/.env`) lives in
`$APP_DIR` (`/srv/hollowmere`), and the site refuses dotfiles anyway. **Moving an older setup** whose
build sat directly in `/var/www/hollowmere`: `sudo mkdir -p /var/www/hollowmere/site`, rsync the build
there, then install the new site file. If the
checkout ever lived under `/var/www/hollowmere`, move it to `/srv/hollowmere` (and the PM2 apps
with it: `pm2 delete` the old ones, `pm2 start ecosystem.config.cjs` from the new path).

Test the site file locally (no root, dummy certificates, fake upstreams; `tools/ci/check.sh` and `tools/release/build_web.sh` run it too):
`deploy/nginx/test_site.sh [build/web]` checks `nginx -t`, the HTTP→HTTPS redirect, the ACME
webroot, HTTP/2, the security headers on every location, that dotfiles and the checkout are never
served, `/api/health` and `/api/tretu/webhook` (POST only, 64 KB, rate limit) to `127.0.0.1:8787`,
and the Nakama locations.

What the site file does:

| Path | Goes to |
|---|---|
| port 80 | only `/.well-known/acme-challenge/` (webroot `/var/www/html`) and a `301` to HTTPS |
| `/v2/account/authenticate/*`, `/v2/account/link/*` | Nakama, **rate-limited**: 30 sign-ins / guest upgrades per minute per IP, burst 30, then `429` (zone `hollowmere_auth`, declared at the top of the file) |
| any path with a dotfile (`/.env`, `/.git/…`) | `404` |
| `/v2/*`, `/ws` | Nakama `127.0.0.1:7350` (websocket upgrade on `/ws`, no gzip on the proxy) |
| `/healthcheck` | Nakama's liveness check |
| `/api/health` | contract health JSON from `hollowmere-mcp` (Nakama health RPC incl. a DB query); 503 when not ok |
| `/api/tretu/webhook` | Tretu platform webhook → `hollowmere-mcp` (POST only, 64 KB max, 120/min per IP, burst 60) |
| `/privacy`, `/datenschutz`, `/terms`, `/agb`, `/impressum` | 308 to `https://tretu.de/datenschutz`, `/agb`, `/impressum` |
| `/auth/callback` | the Tretu-Konto sign-in callback page (`no-store`, `no-referrer`) |
| `/hm-*` | fingerprinted engine files, `immutable`, `application/wasm` for `.wasm`, `gzip_static` |
| everything else | `index.html` (`no-cache`) |

Every response carries `X-Content-Type-Options: nosniff` and `Strict-Transport-Security` (only
honoured over HTTPS); the game page and `/auth/callback` also `Content-Security-Policy:
frame-ancestors 'none'` (no framing of the game or its sign-in). nginx does not inherit
`add_header` into a location that sets its own, so the file repeats them per location; keep that
when you add a location.

The web export is single-threaded: no COOP/COEP headers. Do not add them (`COOP: same-origin` cuts
the Tretu sign-in popup off from the game).
For Brotli: `sudo apt install libnginx-mod-http-brotli-static` and uncomment `brotli_static on;`.

## 8. Web build

Built on the dev machine (Linux or macOS) from the commit that is deployed, normally HEAD of `main`:

```bash
tools/release/build_web.sh
# HOLLOWMERE_DOMAIN=hollowmere.tretu.de is the default; TRETU_AUTH_ISSUER=https://auth.staging.example
# only for staging. game/project.godot is restored afterwards (never commit a live domain).
```

It exports the "Web" preset, renames the engine files to `hm-<hash>.*`, adds the PWA files, legal
redirects, `/auth/callback`, `robots.txt` and `sitemap.xml`, writes `.br`/`.gz`, enforces the 50 MB
Brotli budget and runs `deploy/nginx/test_site.sh` against the result. If nginx is not installed,
that last check is skipped with a `WARNING` (the build is still complete); install nginx to run it.
`build/web` is then copied as is to the site directory:

```bash
rsync -az --delete build/web/ "$DEPLOY_USER@$SERVER_IP:$SITE_DIR/"
```

**Linux** (Ubuntu): Godot 4.7.2 as `godot` on `PATH` (or `GODOT=/path/to/godot`), its web export
templates in `~/.local/share/godot/export_templates/4.7.2.stable/`, and
`sudo apt install brotli nginx openssl curl` plus Node 22 for the site test.

**macOS** (Apple silicon or Intel; the scripts use only bash 3.2, BSD tools and `perl -pi`, no GNU
coreutils needed):

1. Godot 4.7.2: `Godot_v4.7.2-stable_macos.universal.zip` from the GitHub release (check it against
   that release's `SHA512-SUMS.txt` with `shasum -a 512`), move `Godot.app` to `/Applications`, then
   `export GODOT=/Applications/Godot.app/Contents/MacOS/Godot`.
2. Export templates: in the editor, Editor → Manage Export Templates → Download and Install, or
   unpack `Godot_v4.7.2-stable_export_templates.tpz` (SHA-512 in §4) so that
   `~/Library/Application Support/Godot/export_templates/4.7.2.stable/web_release.zip` exists. Only
   the `web_*` files are needed for this build.
3. `brew install brotli` (required; the system `gzip` and `perl` are enough for the rest).
4. Optional, for the site file test: `brew install nginx node` (`openssl` and `curl` ship with macOS).
   `test_site.sh` finds `mime.types` in `/etc/nginx`, `/opt/homebrew/etc/nginx`,
   `/usr/local/etc/nginx` or next to nginx's compiled-in `--conf-path` (`nginx -V`);
   `NGINX_MIME_TYPES=/path/to/mime.types` overrides that. It never touches the Homebrew nginx
   service or its config: it runs its own nginx on free high ports from a temp directory.

`tools/ci/check.sh` (all tests, §11) stays Linux-only (`sha256sum`, `lua5.1`, Postgres).

## 9. Release clients point at the live server

Desktop and web release builds read `hollowmere/server/host.release` (`%HOLLOWMERE_DOMAIN%` in the
repo). `tools/release/build_web.sh` fills it from `HOLLOWMERE_DOMAIN` (default `hollowmere.tretu.de`).

## 10. Tretu ecosystem

**"Mit Tretu-Konto anmelden" is the only account sign-in.** The in-game email, Google, Apple and
Discord sign-ins were removed; guest (device) play stays. The platform part (events, presence,
Tretu-Credits) stays off until `TRETU_PLATFORM_URL` and `TRETU_APP_SECRET` are set.

**Deploy order (GO-LIVE):** auth.tretu.de must be live, the client `hollowmere` registered and the
legacy import done (so `legacy_ids.hollowmere` is known for old players) **before** this version of
the server and the game ships.

Both sides:

1. auth.tretu.de: client `hollowmere`, public (PKCE only, no secret), redirect URIs
   `https://hollowmere.tretu.de/auth/callback` and `http://127.0.0.1/callback` (any port, RFC 8252).
   The issuer must allow CORS from `https://hollowmere.tretu.de` on discovery and the token endpoint
   (the web build exchanges the code in the browser). Userinfo carries the `legacy_ids` claim
   (scope `tretu`).
2. Server (required): `TRETU_AUTH_ISSUER=https://auth.tretu.de` in `server/.env` (the example has
   it), then `pm2 reload ecosystem.config.cjs --update-env`. Without it `run.mjs` refuses to start
   ("TRETU_AUTH_ISSUER is missing (Tretu sign-in not configured)"); only `NAKAMA_ALLOW_DEFAULTS=1`
   dev/test runs start without it, and then only guest play works.
3. Game builds: `game/project.godot` ships `tretu/auth_issuer="https://auth.tretu.de"` and
   `tretu/client_id="hollowmere"`. `TRETU_AUTH_ISSUER=… tools/release/build_web.sh` only overrides the
   issuer (e.g. staging); the build fails if the setting is missing.

**Server-side, the removed sign-ins are refused** (old clients, direct API calls): Nakama before-hooks
answer `AuthenticateEmail/Google/Apple/Facebook/FacebookInstantGame/GameCenter/Steam`, the matching
`Link*` calls and `UnlinkCustom` with "This sign-in is no longer available. Sign in with your Tretu
account." A custom login needs a Tretu token (or a farm-switch ticket). The Discord token check
(`discord.com` from Nakama) is gone.

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

**Old players keep their farms (email, Google, Apple, Discord, Steam, guest).** The `legacy_ids`,
`discord_id` and `steam_id` claims are kept server-side (`tretu_identity/<sub>`, not readable by
players); `steam_id` is also written to the account metadata (`metadata.steam_id`, removed again when
the player unlinks Steam in Mein Konto). On the first Tretu login (no `tretu:<sub>` account yet) the
old account is re-keyed to `tretu:<sub>` (one guarded, idempotent `UPDATE users SET custom_id …`), so
the same Nakama user (saves, profile, AI-helper tokens) continues. Matched in this order:

| Order | Old account | Recognised by |
|---|---|---|
| 1 | any (email, Google, Apple, Discord, Steam, device) | `legacy_ids.hollowmere` = its Nakama user id (from the legacy import at auth.tretu.de); never an account that already belongs to another Tretu-Konto (`tretu:<other>`) or is archived/disabled |
| 2 | Discord | custom id `discord:<discord_id>` |
| 3 | Steam | `users.steam_id = <steam_id>` (Nakama's native Steam auth) or custom id `steam:<steam_id>` |

A marker in storage `tretu_links/<provider>:<id>` records a Discord/Steam carry-over (cleaned up
with the account). Old email/Google/Apple data stays in the `users` row (no column is dropped in
this change; a later cleanup can clear `email`, `password`, `google_id`, `apple_id` and the
`tretu_links` markers once every old player has signed in).

**Guests: "Save to Tretu-Konto".** A guest (device account) signs in with the same Tretu button; the
game first calls Nakama `LinkCustom` with `vars.tretu_token`, the hook checks the token and links
`tretu:<sub>` to the guest's own account, so the guest's farm (local and cloud saves) is the Tretu
farm from then on. If the Tretu-Konto already has a Hollowmere account, Nakama answers
`AlreadyExists` and the game signs in normally (the guest's saves stay on the device). An account
that belongs to another Tretu-Konto is never moved. If `legacy_ids` (or Discord/Steam) also names an
old account, it waits in the farm choice below.

**Choose a farm (both accounts exist).** When the player already has a `tretu:<sub>` account *and*
an old account (legacy_ids, Discord or Steam; e.g. after a guest upgrade), nothing is merged on its
own. After signing in, the game shows
"Wähle deine Farm" with the cloud saves of each account (RPC `tretu_farm_choice`), and the player
keeps one (RPC `tretu_farm_choose`, also reachable later from the account panel). The switch is one
SQL statement (a `DO` block, so all or nothing): every other account gets the custom id
`archived:<user id>`, loses its Steam id, is disabled (its sessions end), and an archive record is
written (`tretu_archive/<user id>`: sub, old custom id, old Steam id, time). The kept account becomes
`tretu:<sub>`. Each update is guarded by what the player was shown, so a concurrent change aborts
the whole switch ("Deine Konten haben sich inzwischen geändert"); choosing the active farm again is
a no-op. When the kept farm is another Nakama user, the RPC also returns a one-time **switch ticket**
(random, only its hash stored in `tretu_switch`, valid 2 minutes, single use). The game redeems it
with `AuthenticateCustom` `vars.tretu_switch`, which is a normal Nakama login of the kept farm (token
**and refresh token**, on web and desktop alike). A plain session token for the kept farm comes along
only as a fallback if that login fails. Archived farms are **never deleted** by the game and can be restored from
the same menu for 90 days (which archives the farm played at that time).

To actually remove archives older than 90 days (data minimisation), run the purge RPC with the HTTP
key, e.g. daily from the deploy user's crontab (`dryRun: true` only counts):

```bash
# 04:31 daily; reads NAKAMA_HTTP_KEY from server/.env
31 4 * * * . /srv/hollowmere/server/.env && curl -sf -X POST "http://127.0.0.1:7350/v2/rpc/tretu_archive_purge?http_key=$NAKAMA_HTTP_KEY&unwrap" -d '{}' >/dev/null
```

Players cannot call it. Restore by hand (Nakama console or psql) is possible as long as the archive
row exists: `SELECT key, value FROM storage WHERE collection = 'tretu_archive';`.

**Account deletion and updates (platform webhook).** On tretu.de, set the Hollowmere entry of
`TRETU_APPS_JSON` to

```json
"hollowmere": { "secret": "<same as TRETU_APP_SECRET>", "webhook": "https://hollowmere.tretu.de/api/tretu/webhook" }
```

and put the same `TRETU_APP_SECRET` into `server/.env` (read by `hollowmere-mcp`), then
`pm2 reload ecosystem.config.cjs --update-env`. `hollowmere-mcp` checks the contract §3 signature
(`x-tretu-app: platform`, HMAC with Hollowmere's own secret over the raw body, ±300 s,
constant-time) and answers `401` otherwise; unknown event types get `204`. It calls two Nakama RPCs
with the HTTP key (players get `403`):

| Event | Nakama RPC | Effect (one SQL statement each, idempotent) |
|---|---|---|
| `user.deleted` | `tretu_user_deleted {sub}` | deletes the `tretu:<sub>` account and every archived farm of that sub (with their saves, profile, queued events, progress marks), their AI-helper tokens and inboxes, co-op codes they host (the presence join link), the identity and archive records and the Discord/Steam markers; ends their sessions |
| `user.deleted` with `{"mergedInto": "<sub2>"}` | `tretu_user_deleted {sub, mergedInto}` | if `<sub2>` has no Hollowmere farm yet: the farm is re-keyed to `tretu:<sub2>` (old sessions end; the player signs in with the surviving Tretu-Konto). Otherwise it is archived under `<sub2>` and appears in that player's farm choice for 90 days. Archived farms of the old sub move to `<sub2>`, its queued events are dropped |
| `user.updated` | `tretu_user_updated {sub, data, occurredAt}` | refreshes the linked Discord/Steam ids and `metadata.steam_id` / `metadata.tretu_username` (used for the in-game profile link); nothing is stored for Tretu users who never played Hollowmere |
| `user.updated` with `"locked": true` / `false` | same RPC | account lock from the central Tretu admin (tretu.de): `true` disables ("bans") the `tretu:<sub>` Nakama account (every token and refresh token issued so far stops working, its sockets close, sign-in is refused with "Your Tretu account is locked …"); `false` enables it again (the player signs in anew). Recorded in storage `tretu_locks/<sub>` (server-only); an unlock only lifts a disable the lock set (archived farms stay archived), and a late retry of an older event (`occurredAt`) never undoes a newer one. If the unlock event gets lost, the next successful Tretu sign-in lifts the lock: auth.tretu.de answers userinfo only for unlocked accounts, so a lock recorded before that question is lifted (one recorded after it still refuses). No schema change |

A failed Nakama call answers `503`, so the platform retries (up to 24 h); repeats are harmless.
Presence on tretu.de itself expires there within 120 s once the deleted player's session is gone.
Without `TRETU_APP_SECRET` in `server/.env` the webhook answers `503 not_configured`.

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

## 11. Tests (no GitHub Actions)

There is no GitHub Actions workflow. `tools/ci/check.sh` runs every test on the dev machine and must
end with "All checks passed." before anything is merged to `main`: script compile check, GUT,
translation template check, balance + casino simulations, MCP relay self-test, Nakama runner tests,
the nginx site file test, Lua unit tests + `nakama.sh check`, the Tretu integration test (fake
issuer + platform, the official Nakama 3.41.0 binary, the game client test
`tests/net/tretu_client_test.tscn` against it), then the server / co-op / desync tests.
`--quick` skips the two simulations and the last three network tests.

Needs Godot 4.7.2 (`GODOT`), Node 22+, Python 3, `lua5.1`, nginx, openssl, `psql` and a Postgres 16
reachable as `CHECK_PG` (default `postgres:postgres@127.0.0.1:5432`). The Nakama binary comes from
`NAKAMA_BIN` or is downloaded into `.tools/nakama` and checked against the pinned SHA-256 (§4). Do not
run it on the production server: it starts its own Nakama on `127.0.0.1:7350` and drops/creates the
databases `hollowmere_check` and `nakama_test`.

The former GitHub secrets and variables (`DEPLOY_HOST`, `DEPLOY_SSH_KEY`, `DEPLOY_*`,
`HOLLOWMERE_DOMAIN`, `TRETU_AUTH_ISSUER`, the Apple and itch ones, and the old `GOOGLE_CLIENT_ID`,
`APPLE_CLIENT_ID`, `DISCORD_CLIENT_ID`) are no longer used; delete them in the repository settings.

## 12. Deploy an update

Same steps as every Tretu app (the deploy agent runs them for HEAD of `main` once `tools/ci/check.sh` passed there):

```bash
cd /srv/hollowmere
git pull --ff-only                       # or: git fetch --tags && git checkout --detach vX.Y.Z
# no npm ci: the MCP relay has no dependencies
server/nakama/nakama.sh check            # Lua modules load
server/nakama/nakama.sh migrate          # nakama migrate up (also runs on every PM2 start)
# build = tools/release/build_web.sh for the same commit, rsynced to /var/www/hollowmere/site (step 8)
pm2 reload ecosystem.config.cjs --update-env
curl -sf https://hollowmere.tretu.de/api/health
```

Rollback: check out the previous commit or tag, reload, and rsync its web build (`tools/release/build_web.sh` on that commit). Engine files are
named `hm-<content hash>.*`, so browsers cannot keep a stale wasm under a new name.

## 13. Social sign-in (removed)

The Google, Apple and Discord buttons are gone: players sign in with the Tretu-Konto (which offers
those providers itself at auth.tretu.de). Their old Hollowmere accounts are carried over (step 10).
The Google OAuth client, the Apple Services ID and the Discord OAuth app of Hollowmere can be
retired once the game version with Tretu-only sign-in is live; `social.apple` is no longer needed in
a `local.yml`.

## 14. Backups

```bash
crontab -e
# 04:12 daily, keeps one dump per weekday
12 4 * * * pg_dump -h 127.0.0.1 -U nakama nakama | gzip > /srv/backups/hollowmere-$(date +\%a).sql.gz
```

Put the password in `~/.pgpass` (`127.0.0.1:5432:nakama:nakama:<password>`, `chmod 600`) and copy
the dumps off the server now and then. If the shared Postgres already has a server-wide backup,
this database is included there.

## 15. Moving from the old Docker setup

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
`.env` as `NAKAMA_SESSION_ENCRYPTION_KEY` / `NAKAMA_SESSION_REFRESH_ENCRYPTION_KEY` / `NAKAMA_HTTP_KEY`
in `server/.env` so signed-in players stay signed in.

## 16. Smoke the live site

- [ ] `https://hollowmere.tretu.de/` shows the title screen; Datenschutz / AGB / Impressum open tretu.de
- [ ] Guest login → New farm → walk, sleep, reload → Continue
- [ ] "Mit Tretu-Konto anmelden" on web and desktop (the only account sign-in; no email/Google/Apple/Discord buttons); guest → "Save to Tretu-Konto" keeps the guest's farm; `pm2 logs hollowmere-nakama` shows no Tretu warnings
- [ ] With the platform on: the account panel shows Tretu-Credits and notifications, and the buttons open tretu.de/wallet and tretu.de/benachrichtigungen
- [ ] Phone landscape: on-screen controls; Add to Home Screen opens full screen
- [ ] `curl -sf https://hollowmere.tretu.de/api/health` is `"status":"ok"`
- [ ] Nakama console through a tunnel only: `ssh -L 7351:127.0.0.1:7351 $DEPLOY_USER@$SERVER_IP`, then `http://127.0.0.1:7351`

**Logs of `hollowmere-mcp`** are JSON lines, one object per line: `ts` (ISO-8601), `level`
(`info` on stdout, `warn`/`error` on stderr), `msg`, plus context. Startup (`hollowmere-mcp started`:
host, port, Nakama URL, version, webhook on/off), health changes (`health ok` / `health error` with
the checks), relay tool calls (tool name, ok, duration; never the token) and every webhook delivery:
`tretu webhook handled` / `ignored`, or `tretu webhook rejected` with `reason` (`bad_signature`,
`stale_timestamp`, `wrong_app`, `body_too_large`, `malformed`, `not_configured`, `nakama_error`,
`method_not_allowed`), `status`, `app` (the `x-tretu-app` header), `eventId` / `eventType` when the body
parses, and `remote` (the client address from nginx's `X-Real-IP`). Secrets, signatures, tokens and
bodies are never logged. Filter with e.g. `pm2 logs hollowmere-mcp --raw | grep '"reason"'` or `jq`.

## 17. If something is wrong

| Symptom | Check |
|---|---|
| `/healthcheck` or `/v2` 502 | `pm2 status`, `pm2 logs hollowmere-nakama`: "refusing to start: …" names the missing `server/.env` key; else the DB login (`NAKAMA_DATABASE_ADDRESS`) is wrong |
| `/api/health` 503 | `checks.db` = Postgres down or `database.address`; `checks.nakama` = Nakama down or `NAKAMA_HTTP_KEY` ≠ `runtime.http_key` |
| Game cannot reach the server | release build still has `%HOLLOWMERE_DOMAIN%`, or `http://` after certbot's redirect |
| Co-op connects then drops | `/ws` upgrade headers; compare with `deploy/nginx/hollowmere.tretu.de.conf` |
| Tretu button missing ("Tretu sign-in is not set up for this build.") | `tretu/auth_issuer` or `tretu/client_id` emptied in `game/project.godot` (step 10) |
| "Tretu sign-in is not enabled on this server." | `TRETU_AUTH_ISSUER` missing in `server/.env` (only possible with `NAKAMA_ALLOW_DEFAULTS=1`), or PM2 not reloaded with `--update-env` |
| PM2 restarts `hollowmere-nakama`, log "refusing to start: … TRETU_AUTH_ISSUER is missing" | add `TRETU_AUTH_ISSUER=https://auth.tretu.de` to `server/.env`, then `pm2 reload ecosystem.config.cjs --update-env` |
| Old player starts with an empty farm | the legacy import at auth.tretu.de did not link the Hollowmere account (`legacy_ids.hollowmere`), and no Discord/Steam claim matched: find the old account (`SELECT id, username, email FROM users WHERE …`), have auth.tretu.de add the legacy link, then the player keeps it in "Wähle deine Farm" |
| Tretu web sign-in fails right away | CORS on the issuer's discovery / token endpoint, or redirect URI not registered |
| Log `Tretu platform POST /api/v1/events -> 401` | `TRETU_APP_SECRET` differs from `TRETU_APPS_JSON.hollowmere.secret` on tretu.de, or clock skew > 300 s |
| Webhook deliveries fail with `401` (tretu.de admin / worker log) | `TRETU_APP_SECRET` in `server/.env` differs from `TRETU_APPS_JSON.hollowmere.secret`, or `hollowmere-mcp` was not reloaded with `--update-env`; `pm2 logs hollowmere-mcp` shows `{"level":"warn","msg":"tretu webhook rejected","reason":"bad_signature",…}` |
| Tretu menu always says "nicht erreichbar" | `pm2 logs hollowmere-nakama` for `Tretu platform GET /api/v1/wallet/…`: `0` = tretu.de unreachable from the server, `401` = secret/clock as above |
| Player "lost" a farm after choosing | it is archived, not gone: restore it in the game (account panel → Archivierte Farmen) within 90 days, or find it with `SELECT key, value FROM storage WHERE collection = 'tretu_archive'` |
| Sign-in says "too many tries" (`429`) | nginx `hollowmere_auth` limit (30/min per IP); raise `rate`/`burst` at the top of the site file if a venue shares one IP |
| `nginx -t` fails on `brotli_static` | leave it commented |
| certbot "failed to authenticate" | DNS not pointing here yet, or port 80 blocked |

## 18. AI helper relay

`hollowmere-mcp` serves `https://mcp.hollowmere.tretu.de` (step 7). Players create tokens in the
game; see `docs/agents.md`.
