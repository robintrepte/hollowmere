<p align="center">
  <img src="store/steam/header_capsule_920x430.png" alt="Hollowmere" width="920">
</p>

<h1 align="center">Hollowmere</h1>

<p align="center">
  A cozy Godot 4 farming game where the creatures you befriend live on your farm and work it with you.
</p>

<p align="center">
  <a href="https://github.com/robintrepte/hollowmere/actions/workflows/build.yml?query=branch%3Amain"><img src="https://github.com/robintrepte/hollowmere/actions/workflows/build.yml/badge.svg?branch=main" alt="Build & Test"></a>
  <img src="https://img.shields.io/badge/Godot-4.7.2-478cbf?logo=godotengine&logoColor=white" alt="Godot 4.7.2">
  <img src="https://img.shields.io/badge/version-1.0.0-blue.svg" alt="1.0.0">
  <img src="https://img.shields.io/badge/license-MIT-yellow.svg" alt="MIT License">
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Web-2ea44f" alt="Windows, macOS, Web">
  <img src="https://img.shields.io/badge/tests-344%20GUT-success" alt="344 GUT tests">
</p>

<p align="center">
  <a href="#play">Play</a> ·
  <a href="#screenshots">Screenshots</a> ·
  <a href="#features">Features</a> ·
  <a href="#run-it-locally">Run locally</a> ·
  <a href="HOSTING.md">Host it</a> ·
  <a href="docs/agents.md">AI helpers</a> ·
  <a href="RELEASE.md">Release</a>
</p>

Inherit your grandmother's overgrown farm in a hidden valley and befriend **106 Wildlings**. They water crops, guard fields and fight beside you in turn-based battles. Farm in real time, fish the coast, mine Eisenkamm, enchant your tools, follow quests, get to know the village, and play together in online co-op — or hand a token to an AI helper.

The same account and cloud saves work in the **browser** (installable home-screen web app), on **Windows** and on **macOS**.

## Screenshots

<p align="center">
  <img src="store/screenshots/01_farm_summer.png" alt="Summer farm" width="48%">
  <img src="store/screenshots/02_farm_dusk.png" alt="Farm at dusk" width="48%">
</p>
<p align="center">
  <img src="store/screenshots/06_village.png" alt="The village" width="48%">
  <img src="store/screenshots/07_mine.png" alt="The mines" width="48%">
</p>
<p align="center">
  <img src="store/screenshots/03_backpack_containers.png" alt="Grid backpack with nested containers" width="48%">
  <img src="store/screenshots/04_wildlings_at_work.png" alt="Party and farm jobs" width="48%">
</p>
<p align="center">
  <img src="store/screenshots/08_dex.png" alt="Wildling dex" width="48%">
</p>

## Features

- **106 Wildlings** to befriend, raise, breed and battle
- **10 farm jobs** — watering, growing, clearing, smelting, pollinating, powering machines, preserving, guarding, luck and harvesting, with hourly rates on job cards
- **Real-time farm** — crops, machines, eggs and jobs tick by the clock, including offline (up to 14 days), with seasons from the real calendar
- **Turn-based 1v1 battles** — 10 types, 79 moves, natures, traits, genes and switching
- **Fishing** — cast-and-reel minigame, 48 fish, crab pots, smoker, rod upgrades, and Möwenbucht harbor
- **Mining** — persistent Deep Mine layers under Eisenkamm, plus breakable regional mines, geodes and a museum
- **Enchanting** — table, anvil and grindstone; sixteen tool enchantments with bookshelf boosts
- **Skill tree** — player levels and 110 skills across farming, care, battle, exploration, craft and trade
- **Lumière** — Grand Casino with play-money chips (hideable), boutique, hotel and jukebox
- **Quests** — main story, side, daily and seasonal chains, plus a skippable tutorial
- **A life in the valley** — 40 crops, four seasons, festivals, cooking, crafting, 32 villagers (11 you can court)
- **Nine regions** — each frontier has a Warden, a shrine and a mine
- **Grid inventory** — items take real space, rotate, and nest inside pouches and cases
- **Online co-op** — host-authoritative farms, trading, friendly PvP, emotes and chat bubbles
- **AI helpers** — hosted MCP relay, spectator mode, and up to three virtual farmhands ([setup](docs/agents.md))
- **Play anywhere** — Windows, macOS, mobile browser + Add to Home Screen, full controller support
- **English and German** — pick a language in Settings, or follow the system language

Store copy and capsule art live in [`store/STORE_PAGE.md`](store/STORE_PAGE.md). Age-rating notes: [`store/RATING.md`](store/RATING.md).

## Play

| Build | How |
|---|---|
| Browser | Host the web export (see [HOSTING.md](HOSTING.md)) and open `https://play.example.com` |
| Phone | Same URL, landscape. Safari / Chrome → **Add to Home Screen** for fullscreen |
| Desktop | Windows and macOS exports from CI (`v*` tags) or a local Godot export |

Accounts: email, guest, or Google. Cloud saves and co-op go through Nakama on your own server. AI clients talk to the MCP relay at `mcp.<your-domain>` with a token created in-game.

## Run it locally

Needs **Godot 4.7.2**. Drop the editor at `.tools/Godot.app` (macOS) or put `godot` on your `PATH`.

```bash
# Game only (offline, local saves, no accounts / co-op)
godot --path game
```

Backend (accounts, cloud saves, co-op, MCP) is Docker:

```bash
cd server
cp .env.example .env          # defaults are fine on localhost
docker compose up -d --build
# API     http://127.0.0.1:7350
# Console http://127.0.0.1:7351  (admin / localdevpassword)
# MCP     http://127.0.0.1:8787
```

Then run the game again. `game/project.godot` already points debug builds at `127.0.0.1:7350`.

```bash
# Compile check, unit tests, translations, one smoke
godot --headless --path game res://tests/check_scripts.tscn
godot --headless --path game -s addons/gut/gut_cmdln.gd -gconfig=res://.gutconfig.json
python3 tools/content/extract_strings.py --check
godot --path game res://tests/smoke/smoke.tscn
```

Release checklist, signing, itch and Steam: [RELEASE.md](RELEASE.md).

## Host it

Production is a **Hetzner Ubuntu** box, **nginx** on the host, Docker for Nakama + Postgres + the MCP relay. The guide is written for humans and agents: one variable block at the top, then copy-paste commands.

**[HOSTING.md](HOSTING.md)** — DNS, nginx + certbot, secrets, first web deploy, GitHub Actions, backups, MCP subdomain.

Example: `play.example.com` → your VPS. Replace the names in the variable block and keep going.

## Repo map

```
game/          Godot 4.7 project (scenes, data, i18n, tests)
server/        Nakama + Postgres + MCP compose, Lua module, nginx / Caddy
docs/          Agent MCP setup (docs/agents.md)
store/         Steam / itch capsules, screenshots, rating and store copy
tools/         Art pipeline, string extraction, web fingerprint + precompress
.github/       CI: 344 tests, Windows / macOS / Web export, tagged deploy
```

CI (every push and PR): script compile, GUT, translation template check, 112-day balance sim, casino RTP sim, Nakama integration, co-op and 4-peer desync tests, then Windows / macOS / Web exports. Tagged `v*` releases can sign macOS, push itch and rsync the web build.

## Made with

Godot 4, Nakama, pixel art through a small Replicate → quantize → atlas pipeline (`tools/art_pipeline`). Copyright [Robin Trepte](https://github.com/robintrepte). MIT — see [LICENSE](LICENSE).
