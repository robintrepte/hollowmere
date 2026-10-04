# Releasing Hollowmere

The order is: playtests on itch.io, a free web launch on our own domain, then Steam.
Everything after `git tag` is automated by `.github/workflows/build.yml`:

| Job | Runs on | Does |
|---|---|---|
| `test` | every push / PR | script compile, GUT unit tests, translation template check, 112-day balance sim, Nakama integration test, co-op test, host + 3 client desync test |
| `export` | every push / PR | Windows, macOS and Web exports; the web build is fingerprinted, precompressed and must stay under 50 MB of Brotli |
| `deploy-web` | `v*` tags | rsyncs the web build to `/srv/hollowmere/site` and rebuilds Nakama + the MCP relay (nginx on the host owns TLS; see HOSTING.md) |
| `sign-macos` | `v*` tags | codesign (hardened runtime), notarize, staple; warns and ships unsigned if the Apple secrets are missing |
| `itch` | `v*` tags | `butler push` to the `windows` and `mac` channels |

## 1. One-time setup

### 1.1 Server and domain (needed for login, cloud saves, co-op and the web build)

Step-by-step Hetzner + Ubuntu + nginx (the commands an agent can run): **[HOSTING.md](HOSTING.md)**.

Short version: a CX22 is enough. Point `play.example.com` at the box, run nginx + certbot on the host, Docker only for Nakama + Postgres. Put the private SSH key in `DEPLOY_SSH_KEY` and the hostname in the `HOLLOWMERE_DOMAIN` variable. Leave `NAKAMA_SERVER_KEY` equal to `hollowmere/server/key` in `game/project.godot`: it ships inside every client and is not a secret.

### 1.2 Google sign-in

Social buttons (Google / Apple / Discord) only appear when that provider's client id is injected into the web shell and the device supports it. Email and guest work without any of them. See HOSTING.md §9.

### 1.3 Apple (macOS signing and notarization)

Needs an Apple Developer Program membership ($99/year).

1. Create a **Developer ID Application** certificate, export it with its private key as `.p12`, then `base64 -i cert.p12 | pbcopy` gives `MACOS_CERT_P12_BASE64`. The export password goes in `MACOS_CERT_PASSWORD`.
2. `MACOS_SIGN_IDENTITY` is the certificate's full name, e.g. `Developer ID Application: Robin Trepte (TEAMID1234)`.
3. App Store Connect, Users and Access, Integrations: create an API key with the Developer role. Download the `.p8` (`base64 -i AuthKey_X.p8` gives `APPLE_API_KEY_BASE64`), and note the key id (`APPLE_API_KEY_ID`) and issuer id (`APPLE_API_ISSUER`).
4. The bundle id is `com.hollowmere.game` (`game/export_presets.cfg`).

Locally: `tools/release/sign_macos.sh build/macos/Hollowmere.zip` with the same variables exported.

### 1.4 itch.io (playtests and desktop downloads)

1. Create the project page (Kind: Downloadable). Use `store/STORE_PAGE.md` for the text and `store/itch/` for the cover and banner.
2. Generate an API key under Settings, API keys: that's `BUTLER_API_KEY`. Set the repository **variable** `ITCH_TARGET` to `<itch user>/<game slug>`.
3. For closed playtests, set the page to *Restricted* and hand out download keys or a password.
4. Don't upload the HTML5 build to itch: the web build talks to the server that served it, so it only works on our domain. Link to the domain from the itch page instead.

### 1.5 GitHub secrets and variables

Settings, Secrets and variables, Actions:

| Name | Kind | Used by |
|---|---|---|
| `DEPLOY_HOST` | secret | deploy-web (VPS hostname or IP) |
| `DEPLOY_SSH_KEY` | secret | deploy-web (private key of `deploy`) |
| `GOOGLE_CLIENT_ID` | secret | web export (Google button) |
| `APPLE_CLIENT_ID` | secret | web export + Nakama (Apple button, Services ID) |
| `DISCORD_CLIENT_ID` | secret | web export (Discord button) |
| `MACOS_SIGN_IDENTITY` | secret | sign-macos |
| `MACOS_CERT_P12_BASE64` | secret | sign-macos |
| `MACOS_CERT_PASSWORD` | secret | sign-macos |
| `APPLE_API_KEY_ID` | secret | sign-macos |
| `APPLE_API_ISSUER` | secret | sign-macos |
| `APPLE_API_KEY_BASE64` | secret | sign-macos |
| `BUTLER_API_KEY` | secret | itch |
| `HOLLOWMERE_DOMAIN` | variable | all exports (release builds connect to it) |
| `ITCH_TARGET` | variable | itch |

Jobs whose secrets are missing skip with a warning instead of failing.

## 2. Every release

1. Bump the version in `game/project.godot` (`application/config/version`) and in the macOS preset (`application/short_version`, `application/version`).
2. Run the local checks (all from the repo root, `G=.tools/Godot.app/Contents/MacOS/Godot`):
   ```sh
   $G --headless --path game -s addons/gut/gut_cmdln.gd -gconfig=res://.gutconfig.json
   $G --headless --path game res://tests/sim/balance_sim.tscn -- --rounds=12 --days=112
   $G --path game res://tests/perf/perf_bench.tscn -- --out=$PWD/.shots   # p95 must stay under 4 ms on an M-series Mac
   for s in smoke ui_smoke title_smoke touch_smoke creatures_smoke adventure_smoke endless_smoke; do
     $G --path game res://tests/smoke/$s.tscn -- --out=$PWD/.shots; done      # look at the screenshots
   python3 tools/content/extract_strings.py
   ```
   The co-op and account smokes need the local server (`cd server && docker compose up -d`).
   To check an exported desktop build boots (needs the full export templates in
   `~/Library/Application Support/Godot/export_templates/4.7.2.stable/`):
   ```sh
   $G --headless --path game --export-release "macOS"
   cd /tmp && unzip -oq ~/path/to/gamegame/build/macos/Hollowmere.zip
   Hollowmere.app/Contents/MacOS/Hollowmere --write-movie /tmp/f.png --fixed-fps 30 --quit-after 150
   ```
   Then look at `/tmp/f00000149.png`: it should be the title screen.
3. Commit, then `git tag v1.0.0 && git push --tags`.
4. Watch the workflow. When it's green:
   - Open `https://<domain>` in a private window: title screen, guest login, new farm, save, reload, continue.
   - Download the macOS build from itch and check that it opens without a Gatekeeper warning (`spctl -a -vv Hollowmere.app` should say "Notarized Developer ID").
   - Start a co-op session between the web build and a desktop build.
   - On a phone (one iPhone with Safari, one Android with Chrome): open the domain in landscape, walk with the stick, open the bag, then add it to the home screen and check it opens full screen with the sprout icon.
5. Check crash reports a day later (section 4).

Rollback: re-run the `deploy-web` job of the previous tag. The engine files carry a content hash in their names, so browsers pick up the old build at once.

## 3. Launch plan

### Phase 1: playtests (itch.io, restricted)
- 2 to 3 rounds of 10 to 30 players, one week each. Each round ships as a tag.
- Ask testers to opt in to anonymous play stats (the game asks once, after the intro).
- What to look at: day-1 drop-off (`active_days` = 1), session length, where people stop in the story (`game_day`), and any new error signatures.
- Rerun the balance sim after every change to `creatures.json`, `moves.json` or `types.json`.

### Phase 2: free web launch
- Make the itch page public, linking to the domain for browser play.
- Launch-day checklist:
  - [ ] VPS backups running, `docker compose ps` healthy, disk under 50%
  - [ ] `curl -I https://<domain>/` shows `Cache-Control: no-cache`, and an `hm-*.wasm` shows `immutable` and `Content-Encoding: br`
  - [ ] Google sign-in works on the live domain
  - [ ] Nakama console (`ssh -L 7351:127.0.0.1:7351 deploy@<host>`, then http://127.0.0.1:7351) reachable, with the default password changed
  - [ ] Store screenshots are up to date (`store/screenshots/`, regenerate with `tests/smoke/store_shots.tscn`)
- Post where cozy and creature-collector players are: r/CozyGamers, r/StardewValley (self-promo days), r/monstertamers, TIGSource, Bluesky/X with `#screenshotsaturday`.

### Phase 3: Steam
1. Pay the Steam Direct fee ($100 per app) in Steamworks and fill in the tax and bank forms. Approval takes a few days.
2. Store page: copy from `store/STORE_PAGE.md`. Image sizes in `store/steam/` match Steam's current requirements:
   | File | Steam slot |
   |---|---|
   | `header_capsule_920x430.png` | Header capsule |
   | `small_capsule_462x174.png` | Small capsule |
   | `main_capsule_1232x706.png` | Main capsule |
   | `vertical_capsule_748x896.png` | Vertical capsule |
   | `library_capsule_600x900.png` | Library capsule |
   | `library_header_920x430.png` | Library header |
   | `library_hero_3840x1240.png` | Library hero (no text) |
   | `library_logo_1280.png` | Library logo (transparent) |
   | `community_icon_184.png`, `client_icon_32.png` | Community and client icons |
   | `store/screenshots/*.png` | Screenshots (1920x1080, at least 5) |
3. Put up a "Coming soon" page at least 2 weeks before release (Steam requires it) and collect wishlists.
4. Builds: one depot each for Windows and macOS. Upload with `steamcmd +login <builder> +run_app_build app_build.vdf`; that can be a fourth tagged job once there's an app id. Steam doesn't need notarization, but the notarized app works there too.
5. Steam's review checks the page and the build (3 to 5 days). Release from the Steamworks dashboard.
6. Not wired up yet, if wanted later: Steam achievements, Steam Cloud and the Steam overlay need GodotSteam (GDExtension) in the desktop builds only.

## 4. Crash reports and play stats

Release builds send error reports (on by default, toggle in Settings, Privacy) and, if the player opted in, a session heartbeat. Both land in Nakama storage:

```sh
ssh deploy@<host> docker exec -it hollowmere-postgres-1 psql -U nakama nakama
```
```sql
-- Most frequent errors (one row per signature)
SELECT value->>'count' AS n, value->>'reporters' AS players, value->>'msg' AS msg, value->>'where' AS at,
       value->'versions' AS versions, update_time
FROM storage WHERE collection = 'errors' ORDER BY (value->>'count')::int DESC LIMIT 20;

-- Players, days active, minutes played
SELECT count(*) AS players,
       avg((value->>'active_days')::int) AS avg_days,
       avg((value->>'minutes')::int) AS avg_minutes
FROM storage WHERE collection = 'analytics' AND key = 'sessions';
```

## 5. Performance budget

- **60 fps on a 2015 MacBook.** `tests/perf/perf_bench.tscn` measures the busiest scenes (a full farm at dusk with 30 Wildlings, the village, a region with wild spawns, a battle). Keep the p95 frame time under 4 ms on an Apple M-series machine, roughly 4 to 5 times faster than a 2015 MacBook.
- **Web download under 50 MB.** CI fails the export if the Brotli files add up to 50 MB or more (currently about 10 MB).
