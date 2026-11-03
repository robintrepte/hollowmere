# Releasing Hollowmere

The order is: playtests on itch.io, a free web launch on our own domain, then Steam.
There is no GitHub Actions CI. Changes are tested on the dev machine and only land on `main` when
every check passes; `main` is what gets deployed. The deploy itself (server checkout, web build to
the site directory, PM2 reload) is done by the owner's deploy agent with the steps in HOSTING.md §12.

| Script | Does |
|---|---|
| `tools/ci/check.sh` | every test: script compile, GUT unit tests, translation template check, 112-day balance sim, 1M-round casino sim, MCP relay self-test, Nakama runner tests, nginx site file test, Lua checks, Tretu integration test (real Nakama 3.41.0), server / co-op / host + 3 client desync tests (`--quick` skips the sims and the network tests) |
| `tools/release/build_web.sh` | the production web export in `build/web`: fingerprinted, precompressed, under 50 MB of Brotli, served correctly by the nginx site file |
| `tools/release/sign_macos.sh` | codesign (hardened runtime), notarize, staple a macOS export (on a Mac) |

## 1. One-time setup

### 1.1 Server and domain (needed for login, cloud saves, co-op and the web build)

Step-by-step Hetzner + Ubuntu + nginx (the commands an agent can run): **[HOSTING.md](HOSTING.md)**.

Short version: it runs on the Tretu Hetzner server: nginx + certbot on the host, Nakama and the MCP relay as PM2 processes (`ecosystem.config.cjs`), the `nakama` database on the shared Postgres. No Docker. The web build talks to `HOLLOWMERE_DOMAIN` (default `hollowmere.tretu.de` in `tools/release/build_web.sh`). Leave `socket.server_key` in `server/nakama/hollowmere.yml` equal to `hollowmere/server/key` in `game/project.godot`: it ships inside every client and is not a secret.

### 1.2 Sign-in: Tretu-Konto only

"Mit Tretu-Konto anmelden" is the only account sign-in; guest play stays, and a guest keeps its farm with "Save to Tretu-Konto". Every build ships with `tretu/auth_issuer="https://auth.tretu.de"` and `tretu/client_id="hollowmere"` (`TRETU_AUTH_ISSUER=… tools/release/build_web.sh` only overrides the issuer, e.g. for staging). The server needs `TRETU_AUTH_ISSUER` in `server/.env` (required, `server/nakama/run.mjs` refuses to start without it). The email, Google, Apple and Discord sign-ins were removed; their accounts are carried over on the first Tretu login (`legacy_ids.hollowmere`, then Discord/Steam). Release order: auth.tretu.de live and the legacy import done first. See HOSTING.md §10.

### 1.3 Tretu platform events

Events and presence for tretu.de need `TRETU_PLATFORM_URL`, `TRETU_APP_ID`, `TRETU_APP_SECRET` in `server/.env`; off until set. See HOSTING.md §10.

### 1.4 Apple (macOS signing and notarization)

Needs an Apple Developer Program membership ($99/year).

1. Create a **Developer ID Application** certificate, export it with its private key as `.p12`, then install it in the login keychain (or pass it as `MACOS_CERT_P12_BASE64` + `MACOS_CERT_PASSWORD`).
2. `MACOS_SIGN_IDENTITY` is the certificate's full name, e.g. `Developer ID Application: Robin Trepte (TEAMID1234)`.
3. App Store Connect, Users and Access, Integrations: create an API key with the Developer role. Download the `.p8` (`base64 -i AuthKey_X.p8` gives `APPLE_API_KEY_BASE64`), and note the key id (`APPLE_API_KEY_ID`) and issuer id (`APPLE_API_ISSUER`).
4. The bundle id is `com.hollowmere.game` (`game/export_presets.cfg`).

Then `tools/release/sign_macos.sh build/macos/Hollowmere.zip` with these variables exported.

### 1.5 itch.io (playtests and desktop downloads)

1. Create the project page (Kind: Downloadable). Use `store/STORE_PAGE.md` for the text and `store/itch/` for the cover and banner.
2. Install [butler](https://itch.io/docs/butler/) and run `butler login` once. Push with `butler push build/windows <itch user>/<game slug>:windows --userversion <version>` and `butler push build/macos/Hollowmere.zip <itch user>/<game slug>:mac --userversion <version>`.
3. For closed playtests, set the page to *Restricted* and hand out download keys or a password.
4. Don't upload the HTML5 build to itch: the web build talks to the server that served it, so it only works on our domain. Link to the domain from the itch page instead.

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
   The co-op and account smokes need the local server (`NAKAMA_ALLOW_DEFAULTS=1 NAKAMA_DATABASE_ADDRESS=postgres@127.0.0.1:5432/nakama server/nakama/nakama.sh start`, see README).
   To check an exported desktop build boots (needs the full export templates in
   `~/Library/Application Support/Godot/export_templates/4.7.2.stable/`):
   ```sh
   $G --headless --path game --export-release "macOS"
   cd /tmp && unzip -oq ~/path/to/gamegame/build/macos/Hollowmere.zip
   Hollowmere.app/Contents/MacOS/Hollowmere --write-movie /tmp/f.png --fixed-fps 30 --quit-after 150
   ```
   Then look at `/tmp/f00000149.png`: it should be the title screen.
3. `tools/ci/check.sh` must end with "All checks passed." Then PR, merge to `main`, and tag the merge: `git tag v1.0.0 && git push --tags`.
4. Web: `tools/release/build_web.sh`, then the deploy agent ships `main` (HOSTING.md §12). Desktop: export Windows and macOS locally, sign the macOS build and push both to itch (1.4, 1.5). Then:
   - Open `https://<domain>` in a private window: title screen, guest login, new farm, save, reload, continue.
   - Download the macOS build from itch and check that it opens without a Gatekeeper warning (`spctl -a -vv Hollowmere.app` should say "Notarized Developer ID").
   - Start a co-op session between the web build and a desktop build.
   - On a phone (one iPhone with Safari, one Android with Chrome): open the domain in landscape, walk with the stick, open the bag, then add it to the home screen and check it opens full screen with the sprout icon.
5. Check crash reports a day later (section 4).

Rollback: check out the previous tag on the server, build its web export, rsync it and reload PM2 (HOSTING.md §12). The engine files carry a content hash in their names, so browsers pick up the old build at once.

## 3. Launch plan

### Phase 1: playtests (itch.io, restricted)
- 2 to 3 rounds of 10 to 30 players, one week each. Each round ships as a tag.
- Ask testers to opt in to anonymous play stats (the game asks once, after the intro).
- What to look at: day-1 drop-off (`active_days` = 1), session length, where people stop in the story (`game_day`), and any new error signatures.
- Rerun the balance sim after every change to `creatures.json`, `moves.json` or `types.json`.

### Phase 2: free web launch
- Make the itch page public, linking to the domain for browser play.
- Launch-day checklist:
  - [ ] Backups running, `pm2 status` shows `hollowmere-nakama` and `hollowmere-mcp` online, `https://<domain>/api/health` is ok, disk under 50%
  - [ ] `curl -I https://<domain>/` shows `Cache-Control: no-cache`, and an `hm-*.wasm` shows `immutable` and `Content-Encoding: br`
  - [ ] "Mit Tretu-Konto anmelden" works on the live domain (popup and, with popups blocked, the full-page redirect), and a guest's "Save to Tretu-Konto" keeps the farm
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
7. **Sign-in on Steam builds: the Tretu-Konto, in the browser.** The Steam depots are the normal desktop exports, so "Mit Tretu-Konto anmelden" works unchanged: the game opens the system browser at auth.tretu.de (where players can also sign in *with Steam*, Steam OpenID) and receives the code on `http://127.0.0.1:<random port>/callback`; the refresh token is kept encrypted for silent sign-in on the next start. Requirements and notes:
   - The depots are the normal exports, which ship with the Tretu issuer (HOSTING.md §10); guest play works too.
   - On Steam Deck in Gaming Mode, `OS.shell_open` opens the Steam overlay browser only if the overlay is available; otherwise the player switches to Desktop Mode once. After that first sign-in the stored refresh token signs in silently, so this is a one-time step. Mention it in the store FAQ.
   - The `steam_id` claim (when the player linked Steam in Mein Konto) is stored on the Nakama account (`metadata.steam_id`). Old Steam-only accounts (`users.steam_id` / custom id `steam:<id>`) are carried over or offered in "Wähle deine Farm" exactly like Discord accounts.
   - There is **no native Steam login** (Steam session tickets need GodotSteam and a Steam Web API publisher key on the server). If one is added later, use Nakama's `AuthenticateSteam` so it lands on `users.steam_id`: the farm choice already moves that id to the farm the player keeps.

## 4. Crash reports and play stats

Release builds send error reports (on by default, toggle in Settings, Privacy) and, if the player opted in, a session heartbeat. Both land in Nakama storage:

```sh
ssh deploy@<host> psql -h 127.0.0.1 -U nakama nakama
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
- **Web download under 50 MB.** `tools/release/build_web.sh` fails if the Brotli files add up to 50 MB or more (currently about 10 MB).
