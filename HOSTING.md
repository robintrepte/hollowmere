# Host Hollowmere on Hetzner (Ubuntu + nginx)

This is the production path: a Hetzner Ubuntu VPS, **nginx** on the host for TLS and static files, **Docker** only for Nakama + Postgres. An agent can run every command as written after filling in the variables.

Caddy is an optional alternative (`docker compose --profile prod`). Do **not** start that profile on a box that already runs nginx: both want ports 80 and 443.

## 0. Fill these in first

Copy the block. Replace the example values. Every later command uses these names.

```bash
# Public hostname players open in a browser. Use a subdomain.
export DOMAIN=play.example.com

# Hetzner VPS IPv4 (Cloud Console → your server → Public IP).
export SERVER_IP=203.0.113.10

# SSH user that owns the app. Created in step 2.
export DEPLOY_USER=deploy

# Where the compose stack and the web build live on the server.
export APP_DIR=/srv/hollowmere
export SITE_DIR=/srv/hollowmere/site

# Nakama, bound to localhost only. nginx proxies to this.
export NAKAMA=127.0.0.1:7350
```

Optional, only if this machine will also export the web build:

```bash
# Local checkout of this repo (the machine you are typing on).
export REPO="$PWD"
export GODOT="${GODOT:-.tools/Godot.app/Contents/MacOS/Godot}"
```

Sanity check before touching the server:

```bash
echo "Will serve https://$DOMAIN  from  $DEPLOY_USER@$SERVER_IP:$SITE_DIR"
```

## 1. DNS

In the domain's DNS (Hetzner DNS, Cloudflare, whatever points the zone):

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `play` (or the host part of `$DOMAIN`) | `$SERVER_IP` | 300 |
| AAAA | same | the VPS IPv6, if it has one | 300 |

Wait until it resolves from your laptop:

```bash
dig +short A "$DOMAIN"
# must print $SERVER_IP
```

Do not run certbot until this is true.

## 2. Bootstrap the VPS

SSH in as root (Hetzner rescue / first login). Export the same `DOMAIN`, `DEPLOY_USER`, `APP_DIR` and `SITE_DIR` values from step 0, then paste.

```bash
apt update && apt upgrade -y
apt install -y docker.io docker-compose-v2 nginx certbot python3-certbot-nginx \
  rsync ufw fail2ban brotli
systemctl enable --now docker nginx

id -u "$DEPLOY_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$DEPLOY_USER"
usermod -aG docker,sudo "$DEPLOY_USER"
mkdir -p "$APP_DIR" "$SITE_DIR" /var/www/html
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"

# SSH key: on your laptop, ssh-copy-id $DEPLOY_USER@$SERVER_IP
# or append the public half of a fresh ed25519 key to ~$DEPLOY_USER/.ssh/authorized_keys

ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

Nakama's ports stay on localhost (`127.0.0.1:7350` / `:7351`). Do not open 7350 or 7351 on the firewall.

## 3. Secrets on the server

SSH as `$DEPLOY_USER`. Never commit the real `.env`.

```bash
ssh "$DEPLOY_USER@$SERVER_IP"
# --- on the server ---
cd "$APP_DIR"
# First time only: copy this repo's server/ tree here (step 4 does it from your laptop).
# Then:
cp .env.example .env
chmod 600 .env
```

Edit `.env` (nano is fine). Generate each `change-me` with `openssl rand -hex 24`.

| Variable | What it is |
|---|---|
| `HOLLOWMERE_DOMAIN` | same as `$DOMAIN` |
| `POSTGRES_PASSWORD` | Postgres password (long random) |
| `NAKAMA_SERVER_KEY` | **must** stay `hollowmere_dev` unless you also change `hollowmere/server/key` in `game/project.godot` and rebuild every client. It ships inside the game. |
| `NAKAMA_SESSION_KEY` | long random |
| `NAKAMA_REFRESH_KEY` | long random |
| `NAKAMA_HTTP_KEY` | long random |
| `NAKAMA_CONSOLE_USER` | Nakama console login (not the game) |
| `NAKAMA_CONSOLE_PASSWORD` | long random, not `localdevpassword` |
| `GOOGLE_CLIENT_ID` | empty to hide Google sign-in |
| `APPLE_CLIENT_ID` | empty to hide Apple; Services ID e.g. `com.hollowmere.web` |
| `DISCORD_CLIENT_ID` | empty to hide Discord |

## 4. Upload the server tree

From your laptop, in the repo root. This does **not** start Caddy.

```bash
rsync -az --delete \
  --exclude .env --exclude site/ --exclude pgdata \
  server/ "$DEPLOY_USER@$SERVER_IP:$APP_DIR/"

ssh "$DEPLOY_USER@$SERVER_IP" "cd $APP_DIR && docker compose up -d --build"
ssh "$DEPLOY_USER@$SERVER_IP" "docker compose -f $APP_DIR/docker-compose.yml ps"
```

Healthy looks like `postgres` and `nakama` **Up**, no `caddy` container.

```bash
ssh "$DEPLOY_USER@$SERVER_IP" "curl -sf http://127.0.0.1:7350/healthcheck && echo"
# prints: {"health":"ok"} or similar
```

Nightly database backup (crontab of `$DEPLOY_USER`):

```bash
crontab -e
# add:
0 4 * * * docker exec hollowmere-postgres-1 pg_dump -U nakama nakama | gzip > /srv/hollowmere/backup-$(date +\%a).sql.gz
```

Copy those `backup-*.sql.gz` files off the box now and then.

## 5. nginx site

Still from your laptop:

```bash
# Render the committed template with this session's variables.
sed -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__SITE_DIR__|$SITE_DIR|g" \
    -e "s|__NAKAMA__|$NAKAMA|g" \
    server/nginx/hollowmere.conf \
  | ssh root@$SERVER_IP "cat > /etc/nginx/sites-available/hollowmere"

ssh root@$SERVER_IP "ln -sfn /etc/nginx/sites-available/hollowmere /etc/nginx/sites-enabled/hollowmere && rm -f /etc/nginx/sites-enabled/default && nginx -t && systemctl reload nginx"
```

Until a web build is uploaded, `/` may 404. That is fine. `/healthcheck` should already proxy:

```bash
curl -sI "http://$DOMAIN/healthcheck" | head -5
```

## 6. TLS

```bash
ssh root@$SERVER_IP "certbot --nginx -d $DOMAIN --redirect --agree-tos -m admin@$DOMAIN --non-interactive"
```

certbot rewrites the site file to listen on 443 and redirect HTTP → HTTPS. Renewal is a systemd timer (`certbot.timer`). Check:

```bash
curl -sI "https://$DOMAIN/healthcheck" | head -8
```

## 7. Export and upload the web build

The browser build must be pointed at `$DOMAIN` (CI does this with the `HOLLOWMERE_DOMAIN` repo variable). Locally:

```bash
# In the repo root, on a machine with Godot 4.7.2 export templates.
sed -i.bak "s/%HOLLOWMERE_DOMAIN%/$DOMAIN/" game/project.godot
"$GODOT" --headless --path game --export-release "Web" "$PWD/build/web/index.html"
# restore the placeholder so you do not commit a live domain
mv game/project.godot.bak game/project.godot

tools/release/fingerprint_web.sh build/web
tools/release/precompress_web.sh build/web

# Optional: inject OAuth client ids (leave the placeholders to hide those buttons).
# sed -i "s/%GOOGLE_CLIENT_ID%/YOUR_GOOGLE_ID/" build/web/index.html
# sed -i "s/%APPLE_CLIENT_ID%/YOUR_APPLE_SERVICES_ID/" build/web/index.html
# sed -i "s/%DISCORD_CLIENT_ID%/YOUR_DISCORD_APP_ID/" build/web/index.html

rsync -az --delete build/web/ "$DEPLOY_USER@$SERVER_IP:$SITE_DIR/"
```

Check cache headers:

```bash
curl -sI "https://$DOMAIN/" | grep -i cache
# Cache-Control: no-cache

WASM=$(curl -s "https://$DOMAIN/" | sed -n 's/.*\(hm-[a-f0-9]*\.wasm\).*/\1/p' | head -1)
curl -sI "https://$DOMAIN/$WASM" | grep -iE 'cache|content-encoding|HTTP'
# 200, immutable, and (if the client accepts it) gzip or br
```

## 8. Point release clients at the live server

Desktop and web release builds read `hollowmere/server/host.release` from `game/project.godot`. That placeholder is `%HOLLOWMERE_DOMAIN%`.

- **GitHub Actions:** Settings → Secrets and variables → Actions → Variables → `HOLLOWMERE_DOMAIN` = `play.example.com` (no `https://`).
- **Local export:** the `sed` in step 7.

## 9. Social sign-in (optional)

Email and guest always work. Each extra button is shown **only** when its client id is in the page (not a leftover `%PLACEHOLDER%`) **and** the device can use it (Apple only on iPhone / iPad / Mac).

**Google**
1. Google Cloud Console → Credentials → OAuth client → type **Web application**.
2. Authorized JavaScript origins: `https://$DOMAIN`
3. GitHub secret `GOOGLE_CLIENT_ID`, or `sed` into `index.html` as in step 7.

**Apple**
1. Apple Developer → Identifiers → Services ID (e.g. `com.hollowmere.web`), enable Sign In with Apple.
2. Return URL: `https://$DOMAIN/`
3. Same id in `.env` as `APPLE_CLIENT_ID` (Nakama checks the token audience) and GitHub secret `APPLE_CLIENT_ID`.

**Discord**
1. Discord Developer Portal → Application → OAuth2.
2. Redirect: `https://$DOMAIN/`
3. GitHub secret `DISCORD_CLIENT_ID` (public application id). No bot needed.

Home-screen iOS PWAs often block Google's popup; Apple and email still work there.

## 10. GitHub Actions deploy (after the box exists)

`.github/workflows/build.yml` job `deploy-web` runs on `v*` tags. It rsyncs `build/web/` to `$SITE_DIR` and restarts **only** Nakama + Postgres (`docker compose up -d --build`, no `--profile prod`).

| GitHub name | Kind | Value |
|---|---|---|
| `DEPLOY_HOST` | secret | `$SERVER_IP` or the hostname |
| `DEPLOY_SSH_KEY` | secret | **private** half of `$DEPLOY_USER`'s ed25519 key |
| `HOLLOWMERE_DOMAIN` | variable | `$DOMAIN` |
| `GOOGLE_CLIENT_ID` | secret | optional; hides the Google button if empty |
| `APPLE_CLIENT_ID` | secret | optional; Apple Services ID |
| `DISCORD_CLIENT_ID` | secret | optional; Discord application id |

The deploy user must be able to `docker compose` without sudo (step 2 added them to the `docker` group).

## 11. Smoke the live site

Do this after the first upload.

- [ ] `https://$DOMAIN/` shows the Hollowmere title screen
- [ ] Guest login → New farm → walk, open the bag, sleep, reload → Continue
- [ ] Phone Safari / Chrome, landscape: on-screen stick and buttons; Add to Home Screen opens full screen
- [ ] Turn the phone to portrait: the “turn your device sideways” overlay
- [ ] `docker compose -f $APP_DIR/docker-compose.yml ps` is healthy
- [ ] Disk under 50%: `df -h $APP_DIR`
- [ ] Nakama console (do not expose 7351 publicly):

```bash
ssh -L 7351:127.0.0.1:7351 "$DEPLOY_USER@$SERVER_IP"
# then open http://127.0.0.1:7351 with NAKAMA_CONSOLE_USER / NAKAMA_CONSOLE_PASSWORD
```

## 12. Updates

**Game only** (new web build, same server code):

```bash
rsync -az --delete build/web/ "$DEPLOY_USER@$SERVER_IP:$SITE_DIR/"
```

**Server code** (Lua module, compose file):

```bash
rsync -az --exclude .env --exclude site/ server/ "$DEPLOY_USER@$SERVER_IP:$APP_DIR/"
ssh "$DEPLOY_USER@$SERVER_IP" "cd $APP_DIR && docker compose up -d --build"
```

**Rollback a web build:** rsync the previous `build/web/` (or re-run the `deploy-web` job of the previous git tag). Engine files are named `hm-<content-hash>.*`, so browsers cannot keep a stale wasm under the new name.

## 13. Sizing

| Hetzner Cloud | Fine for |
|---|---|
| CX22 (2 vCPU / 4 GB) | launch, a few dozen concurrent players |
| CX32 (4 vCPU / 8 GB) | if the box also does other sites |

The web download is ~10 MB Brotli. Nakama + Postgres are the only always-on processes besides nginx.

## 14. If something is wrong

| Symptom | Check |
|---|---|
| `nginx -t` fails on `brotli_static` | leave it commented (the committed file already does) |
| certbot “failed to authenticate” | `dig +short A $DOMAIN` is not `$SERVER_IP` yet, or ufw blocked 80 |
| `/healthcheck` 502 | `docker compose ps` — nakama not up; `docker compose logs nakama` |
| Game says it cannot reach the server | release build still has `%HOLLOWMERE_DOMAIN%`, or you opened `http://` after certbot redirected |
| Co-op connects then drops | `/ws` upgrade headers missing; compare your site file to `server/nginx/hollowmere.conf` |
| Port 80 already in use | another site or a leftover `caddy` container (`docker compose --profile prod down`) |
| Google button does nothing | client id still `%GOOGLE_CLIENT_ID%`, or the origin is not exactly `https://$DOMAIN` |

## Caddy instead of nginx

If you would rather not run nginx, skip steps 5–6 and:

```bash
# .env must contain HOLLOWMERE_DOMAIN=$DOMAIN
ssh "$DEPLOY_USER@$SERVER_IP" "cd $APP_DIR && docker compose --profile prod up -d --build"
```

Caddy then binds 80/443, issues TLS, and serves `$APP_DIR/site`. Do not also enable the nginx site.
