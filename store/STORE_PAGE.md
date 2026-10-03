# Hollowmere: store page copy

Images: `store/steam/` (capsules, library art, icons), `store/itch/` (cover, banner), `store/screenshots/` (1920x1080).
Rebuild them with `.venv/bin/python tools/release/store_assets.py` and
`godot --path game res://tests/smoke/store_shots.tscn -- --out=$PWD/store/screenshots`.

## Short description (Steam, max 300 characters)

Inherit your grandmother's overgrown farm in a hidden valley and befriend 97 Wildlings: creatures that water your crops, guard your fields and fight beside you in turn-based battles. Farm, breed, explore nine wild regions, find love in town and play it all together in online co-op.

## About this game

**A cozy farm with a wild frontier.**
Your grandmother Hazel left you her farm at the edge of Hollowmere, a valley where shrines have gone dark and the wild creatures called Wildlings have grown restless. Clear the fields, plant your first parsnips and make friends with whoever comes sniffing around the crops.

**Wildlings that live on your farm.**
Befriend Wildlings in tall grass, caves and forests, then bring them home. Each one can take one of ten farm jobs: watering, growing, clearing, smelting, pollinating, powering machines, preserving, guarding, bringing luck or harvesting. Feed them, groom them and they work harder. Neglect them and they'd rather nap.

**Turn-based 1v1 battles.**
Ten types, 79 moves, natures, traits, status effects and switching. Battle wild Wildlings, rival trainers and the Wardens who guard each region's shrine. Weaken a wild one and offer a charm or a treat to befriend it.

**Breeding with real genetics.**
Every Wildling carries genes for each stat, a nature and up to two traits. Pair them at the den, hatch the eggs in your hatchery and chase the rare Starry colorings.

**A life in the valley.**
40 crops across four seasons, a greenhouse, sprinklers and machines. Cook 16 dishes, craft 24 items, upgrade your tools at the blacksmith and build up your farm with the carpenter. Get to know 20 villagers, and court and marry one of 8 if you like.

**A backpack that's a puzzle.**
Your inventory is a grid. Items take up real space, rotate and nest inside containers: seed pouches, gem cases, forage baskets, treat tins. Packing for a trip to the mines is half the fun.

**Endless after the credits.**
Weekly Creature Shows with a ranking ladder, weekly bounties, Warden rematches, Starry chains, legendary Wildlings and the bottomless Deep Hollow mine.

**Better together.**
Invite friends to your farm in online co-op (best with 2 to 4 players). Everyone farms the same fields, trades Wildlings and items, and battles each other in friendly duels.

**Play anywhere.**
Windows, macOS, or right in your browser with the same account and cloud saves. Full controller support, adjustable text size, a colorblind-friendly mode and remappable keys.

## Key features (bullets for capsules, itch.io and press)

- 97 Wildlings to befriend, raise, breed and battle with
- 10 farm jobs for your Wildlings
- Turn-based 1v1 battles: 10 types, 79 moves, natures, traits and genes
- 40 crops, four seasons, festivals, cooking and crafting
- 20 villagers, 8 of whom you can court and marry
- 9 regions; 8 frontier regions each have a Warden, a shrine and a mine
- Tetris-style grid inventory with nesting containers
- Online co-op, trading and friendly PvP
- Windows, macOS and browser with cloud saves
- Free to play

## Tags (Steam, in order of relevance)

Farming Sim, Creature Collector, Cozy, Pixel Graphics, Life Sim, Online Co-Op, Turn-Based Combat, Relaxing, RPG, Free to Play, Cute, Exploration, Dating Sim, Casual, Multiplayer, 2D, Top-Down, Singleplayer, Crafting, Inventory Management

## Genre / categories

Genre: Casual, Indie, RPG, Simulation, Free to Play.
Categories: Single-player, Online Co-op, Online PvP, Cross-Platform Multiplayer, Full controller support. (Cloud saves go through Hollowmere accounts, not Steam Cloud, so don't tick Steam Cloud.)

## System requirements

| | Minimum | Recommended |
|---|---|---|
| OS | Windows 10 64-bit / macOS 10.15 | Windows 11 / macOS 13 |
| Processor | Dual-core 2 GHz | Quad-core 2.5 GHz |
| Memory | 2 GB RAM | 4 GB RAM |
| Graphics | OpenGL 3.3 / Metal capable GPU | Any GPU from 2016 or later |
| Storage | 200 MB | 200 MB |
| Network | Broadband for co-op and cloud saves | |

Browser: a current Chrome, Edge, Firefox or Safari with WebGL 2.

## Languages

English (interface, text). The game ships a translation template (`game/i18n/hollowmere.pot`) for community translations.

## Content descriptors

No mature content. Creatures faint in battle, nobody is harmed. Optional online play with friends.

## itch.io page

**Tagline:** Farm, befriend 97 Wildlings and play together. Free, in your browser or on desktop.

**Body:** use "About this game" above. Set the cover to `store/itch/cover_630x500.png` and the banner to `store/itch/banner_960x300.png`. Upload the HTML5 build as "playable in browser" (viewport 1280x720, fullscreen button on, mobile friendly off), plus the Windows and macOS channels pushed by CI.

**itch.io tags:** farming, creature-collector, cozy, pixel-art, co-op, turn-based, life-simulation, monsters, relaxing, free

## Press blurb (one paragraph)

Hollowmere is a free cozy farming game where the creatures you befriend live on your farm and work it with you. Raise and breed 97 Wildlings with real genetics, give them farm jobs, battle in turn-based duels, explore nine regions and court the locals, alone or with friends in online co-op. It runs on Windows, macOS and in the browser with cloud saves.
