#!/usr/bin/env python3
"""Builds game/data/skills.json: six branches radiating from the centre of the skill tree.

Each node: {id, branch, tier, name, icon, ranks, mods: {key: per_rank}, req: [any of], pos: [x, y],
need?: branch points before it opens, unlock?: feature flag}. Effect text is built in the game
from `mods`, so only names need translating.

Usage: python3 tools/content/make_skills.py [--de out.json]
"""
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# (id, name, tier, icon, ranks, mods, unlock)
BRANCHES = {
    "farming": {"name": "Farming", "icon": "parsnip", "color": "#6cbf4a", "nodes": [
        ("green_thumb", "Green Thumb", 1, "parsnip_seeds", 3, {"crop_growth": 0.03}, ""),
        ("deep_roots", "Deep Roots", 2, "potato", 3, {"crop_yield": 0.03}, ""),
        ("gentle_hands", "Gentle Hands", 2, "strawberry", 3, {"crop_quality": 0.03}, ""),
        ("light_hoe", "Light Hoe", 2, "hoe", 2, {"farm_energy": -0.08}, ""),
        ("wide_spray", "Wide Spray", 3, "watering_can", 1, {"water_range": 1}, ""),
        ("soaked_soil", "Soaked Soil", 3, "gold_sprinkler", 3, {"water_duration": 0.15}, ""),
        ("seed_saver", "Seed Saver", 3, "_seed_packet", 2, {"seed_return": 0.06}, ""),
        ("season_wise", "Season Wise", 4, "pumpkin", 3, {"season_relief": 0.12}, ""),
        ("bountiful", "Bountiful", 4, "corn", 2, {"crop_yield": 0.04}, ""),
        ("fertile_ground", "Fertile Ground", 4, "basic_fertilizer", 2, {"crop_growth": 0.04}, ""),
        ("bee_friend", "Bee Friend", 4, "honey", 2, {"crop_quality": 0.03, "crop_growth": 0.02}, ""),
        ("prize_grower", "Prize Grower", 5, "starfruit", 2, {"crop_quality": 0.05}, ""),
        ("downpour", "Downpour", 5, "quality_sprinkler", 1, {"water_range": 1, "water_duration": 0.2}, ""),
        ("tireless", "Tireless Farmer", 5, "_energy", 2, {"farm_energy": -0.1}, ""),
        ("compost", "Compost", 5, "quality_fertilizer", 2, {"crop_growth": 0.03, "crop_yield": 0.02}, ""),
        ("evergreen", "Evergreen", 6, "frost_cabbage", 1, {"season_relief": 0.2}, ""),
        ("harvest_moon", "Harvest Moon", 6, "melon", 1, {"crop_yield": 0.05, "crop_quality": 0.03}, ""),
        ("quick_sprout", "Quick Sprout", 6, "speed_gro", 1, {"crop_growth": 0.06}, ""),
        ("harvest_sweep", "Harvest Sweep", 7, "scythe", 1, {"crop_growth": 0.05}, "harvest_sweep"),
    ]},
    "care": {"name": "Wildling Care", "icon": "basic_treat", "color": "#e8a33c", "nodes": [
        ("kind_words", "Kind Words", 1, "_heart", 3, {"happiness": 0.1}, ""),
        ("work_song", "Work Song", 2, "hay_bale", 3, {"job_power": 0.04}, ""),
        ("cozy_den", "Cozy Den", 2, "_bed", 3, {"wildling_regen": 0.08}, ""),
        ("light_load", "Light Load", 3, "fluff", 3, {"job_energy": -0.06}, ""),
        ("matchmaker", "Matchmaker", 3, "heirloom_charm", 2, {"breed_speed": 0.12}, ""),
        ("warm_nest", "Warm Nest", 3, "egg_carrier", 2, {"hatch_speed": 0.12}, ""),
        ("treat_maker", "Treat Maker", 3, "basic_treat", 2, {"happiness": 0.1, "produce": 0.05}, ""),
        ("roomy_den", "Roomy Den", 4, "picket_fence", 2, {"den_slots": 1}, ""),
        ("fresh_produce", "Fresh Produce", 4, "milk", 3, {"produce": 0.08}, ""),
        ("foreman", "Foreman", 4, "brush", 2, {"job_power": 0.06}, ""),
        ("spa_day", "Spa Day", 5, "honey", 2, {"wildling_regen": 0.12}, ""),
        ("big_family", "Big Family", 5, "festival_egg", 2, {"breed_speed": 0.15, "hatch_speed": 0.1}, ""),
        ("best_friends", "Best Friends", 5, "deluxe_treat", 2, {"happiness": 0.15}, ""),
        ("tough_workers", "Tough Workers", 5, "hardwood", 2, {"job_energy": -0.08}, ""),
        ("night_shift", "Night Shift", 6, "moonbloom", 1, {"job_energy": -0.12}, ""),
        ("golden_eggs", "Golden Eggs", 6, "cluckle_egg", 1, {"produce": 0.15}, ""),
        ("open_range", "Open Range", 6, "flower_bed", 1, {"den_slots": 2}, ""),
        ("pack_leader", "Pack Leader", 7, "great_charm", 1, {"job_power": 0.1, "den_slots": 2}, ""),
    ]},
    "battle": {"name": "Battle", "icon": "potion", "color": "#d8504a", "nodes": [
        ("sharp_mind", "Sharp Mind", 1, "potion", 3, {"battle_damage": 0.03}, ""),
        ("field_medic", "Field Medic", 2, "max_potion", 3, {"battle_heal": 0.1}, ""),
        ("soft_voice", "Soft Voice", 2, "lure_charm", 3, {"befriend": 0.06}, ""),
        ("veteran", "Veteran", 2, "_star", 3, {"battle_xp": 0.08}, ""),
        ("leaf_lore", "Leaf Lore", 3, "kale", 2, {"dmg_leaf": 0.06}, ""),
        ("tide_lore", "Tide Lore", 3, "aquamarine", 2, {"dmg_tide": 0.06}, ""),
        ("ember_lore", "Ember Lore", 3, "hot_pepper", 2, {"dmg_ember": 0.06}, ""),
        ("stone_lore", "Stone Lore", 3, "stone", 2, {"dmg_stone": 0.06}, ""),
        ("gale_lore", "Gale Lore", 4, "fiber", 2, {"dmg_gale": 0.06}, ""),
        ("spark_lore", "Spark Lore", 4, "topaz", 2, {"dmg_spark": 0.06}, ""),
        ("frost_lore", "Frost Lore", 4, "frostberry", 2, {"dmg_frost": 0.06}, ""),
        ("shade_lore", "Shade Lore", 4, "amethyst", 2, {"dmg_shade": 0.06}, ""),
        ("glow_lore", "Glow Lore", 5, "glow_tea", 2, {"dmg_glow": 0.06}, ""),
        ("wild_lore", "Wild Lore", 5, "mushroom", 2, {"dmg_wild": 0.06}, ""),
        ("thick_skin", "Thick Skin", 5, "hardwood", 3, {"battle_guard": 0.04}, ""),
        ("trusted", "Trusted", 6, "great_charm", 2, {"befriend": 0.1}, ""),
        ("mentor", "Mentor", 6, "hollow_pendant", 2, {"battle_xp": 0.12}, ""),
        ("battle_hymn", "Battle Hymn", 6, "blue_jazz", 1, {"battle_heal": 0.2}, ""),
        ("champion", "Champion", 7, "diamond", 1, {"battle_damage": 0.1, "battle_guard": 0.05}, ""),
    ]},
    "explore": {"name": "Exploration", "icon": "forage_basket", "color": "#4aa8c8", "nodes": [
        ("light_feet", "Light Feet", 1, "_energy", 3, {"move_speed": 0.03}, ""),
        ("stamina", "Stamina", 2, "farmer_lunch", 3, {"max_energy": 0.06}, ""),
        ("forager", "Forager", 2, "forage_basket", 3, {"forage_luck": 0.06}, ""),
        ("second_wind", "Second Wind", 3, "honey_cake", 3, {"energy_regen": 0.15}, ""),
        ("treasure_nose", "Treasure Nose", 3, "chest", 3, {"chest_luck": 0.05}, ""),
        ("efficient", "Efficient", 3, "hearty_pancakes", 2, {"energy_cost": -0.05}, ""),
        ("scout", "Scout", 3, "_sign", 2, {"chest_luck": 0.04, "forage_luck": 0.04}, ""),
        ("trailblazer", "Trailblazer", 4, "picket_fence", 2, {"move_speed": 0.04}, ""),
        ("wild_harvest", "Wild Harvest", 4, "mushroom", 2, {"forage_luck": 0.08}, ""),
        ("deep_breath", "Deep Breath", 4, "glow_tea", 2, {"max_energy": 0.08}, ""),
        ("map_reader", "Map Reader", 5, "_sign", 1, {"move_speed": 0.02}, "map_travel"),
        ("lucky_find", "Lucky Find", 5, "gem_case", 2, {"chest_luck": 0.08}, ""),
        ("iron_will", "Iron Will", 5, "iron_bar", 2, {"energy_cost": -0.07}, ""),
        ("sprinter", "Sprinter", 5, "_energy", 1, {"move_speed": 0.04}, ""),
        ("night_walker", "Night Walker", 6, "moonbloom", 1, {"energy_regen": 0.3}, ""),
        ("gatherer", "Gatherer", 6, "berry_tart", 1, {"forage_luck": 0.12}, ""),
        ("endurance", "Endurance", 6, "max_potion", 1, {"max_energy": 0.12}, ""),
        ("wayfarer", "Wayfarer", 7, "hollow_pendant", 1, {"move_speed": 0.05, "energy_cost": -0.05}, ""),
    ]},
    "craft": {"name": "Craftsmanship", "icon": "pickaxe", "color": "#9a7ad0", "nodes": [
        ("steady_hands", "Steady Hands", 1, "flower_pot", 3, {"craft_extra": 0.03}, ""),
        ("prospector", "Prospector", 2, "copper_ore", 3, {"ore_luck": 0.05}, ""),
        ("strong_swing", "Strong Swing", 2, "pickaxe", 3, {"mine_speed": 0.08}, ""),
        ("patient_angler", "Patient Angler", 2, "lure_charm", 3, {"fish_bite": 0.08}, ""),
        ("tinkerer", "Tinkerer", 3, "furnace", 3, {"machine_speed": 0.06}, ""),
        ("calm_reel", "Calm Reel", 3, "aquamarine", 2, {"fish_zone": 0.1}, ""),
        ("gem_eye", "Gem Eye", 3, "emerald", 2, {"ore_luck": 0.07}, ""),
        ("bulk_crafter", "Bulk Crafter", 4, "preserves_jar", 1, {"craft_extra": 0.03}, "craft_x10"),
        ("lucky_line", "Lucky Line", 4, "gem_case", 2, {"fish_luck": 0.08}, ""),
        ("deep_miner", "Deep Miner", 4, "iron_ore", 2, {"mine_speed": 0.1}, ""),
        ("smelter", "Smelter", 4, "copper_bar", 2, {"machine_speed": 0.06}, ""),
        ("arcane_study", "Arcane Study", 5, "amethyst", 3, {"enchant_cost": -0.08}, ""),
        ("well_oiled", "Well Oiled", 5, "keg", 2, {"machine_speed": 0.08}, ""),
        ("master_angler", "Master Angler", 5, "pomegranate", 2, {"fish_zone": 0.1, "fish_bite": 0.08}, ""),
        ("motherlode", "Motherlode", 6, "gold_ore", 1, {"ore_luck": 0.12}, ""),
        ("artisan", "Artisan", 6, "_jam", 2, {"craft_extra": 0.05}, ""),
        ("spellwright", "Spellwright", 6, "mystic_bar", 1, {"enchant_cost": -0.12}, ""),
        ("master_artisan", "Master Artisan", 7, "diamond", 1, {"machine_speed": 0.15, "craft_extra": 0.08}, ""),
    ]},
    "trade": {"name": "Commerce", "icon": "_coin", "color": "#e0c040", "nodes": [
        ("haggler", "Haggler", 1, "_coin", 3, {"sell_price": 0.02}, ""),
        ("regular", "Regular", 2, "_backpack", 3, {"shop_discount": 0.03}, ""),
        ("charmer", "Charmer", 2, "bouquet", 3, {"friendship": 0.1}, ""),
        ("express_crate", "Express Crate", 2, "_shipping_bin", 3, {"ship_bonus": 0.03}, ""),
        ("absentee", "Absentee Owner", 3, "_mailbox", 3, {"offline_efficiency": 0.04}, ""),
        ("market_sense", "Market Sense", 3, "gold_bar", 2, {"sell_price": 0.03}, ""),
        ("lucky_chip", "Lucky Chip", 3, "_star", 2, {"casino_daily": 0.25}, ""),
        ("bargain_hunter", "Bargain Hunter", 3, "_coin", 2, {"shop_discount": 0.03}, ""),
        ("bulk_buyer", "Bulk Buyer", 4, "chest", 2, {"shop_discount": 0.04}, ""),
        ("export", "Export Deal", 4, "_shipping_bin", 2, {"ship_bonus": 0.05}, ""),
        ("socialite", "Socialite", 4, "flower_crown", 2, {"friendship": 0.15}, ""),
        ("passive_income", "Passive Income", 5, "_mailbox", 2, {"offline_efficiency": 0.06}, ""),
        ("merchant", "Merchant", 5, "gem_case", 2, {"sell_price": 0.04}, ""),
        ("high_roller", "High Roller", 5, "diamond", 1, {"casino_daily": 0.5}, ""),
        ("gift_wrap", "Gift Wrap", 5, "bouquet", 1, {"friendship": 0.2}, ""),
        ("wholesale", "Wholesale", 6, "hay_bale", 1, {"ship_bonus": 0.08}, ""),
        ("loyal_customer", "Loyal Customer", 6, "_heart", 1, {"shop_discount": 0.06}, ""),
        ("tycoon", "Tycoon", 7, "gold_bar", 1, {"sell_price": 0.05, "offline_efficiency": 0.1}, ""),
    ]},
}

ORDER = ["farming", "care", "battle", "explore", "craft", "trade"]
CAPSTONE_NEED = 18
RING = 70.0
FIRST = 60.0

DE = {
    "Farming": "Farmen", "Wildling Care": "Wildling-Pflege", "Battle": "Kampf", "Exploration": "Erkundung",
    "Craftsmanship": "Crafting", "Commerce": "Handel",
    "Green Thumb": "Grüner Daumen", "Deep Roots": "Tiefe Wurzeln", "Gentle Hands": "Sanfte Hände",
    "Light Hoe": "Leichte Hacke", "Wide Spray": "Weiter Strahl", "Soaked Soil": "Satter Boden",
    "Seed Saver": "Saatsparer", "Season Wise": "Saisonkundig", "Bountiful": "Reiche Ernte",
    "Fertile Ground": "Fruchtbarer Boden", "Prize Grower": "Preiszüchter", "Downpour": "Wolkenbruch",
    "Tireless Farmer": "Unermüdlich", "Evergreen": "Immergrün", "Harvest Moon": "Erntemond",
    "Quick Sprout": "Schnellkeimer", "Harvest Sweep": "Ernteschwung",
    "Kind Words": "Liebe Worte", "Work Song": "Arbeitslied", "Cozy Den": "Gemütlicher Hof",
    "Light Load": "Leichte Last", "Matchmaker": "Kuppler", "Warm Nest": "Warmes Nest",
    "Roomy Den": "Geräumiger Hof", "Fresh Produce": "Frische Erzeugnisse", "Foreman": "Vorarbeiter",
    "Spa Day": "Wellnesstag", "Big Family": "Großfamilie", "Best Friends": "Beste Freunde",
    "Night Shift": "Nachtschicht", "Golden Eggs": "Goldene Eier", "Open Range": "Freilauf",
    "Pack Leader": "Rudelführer",
    "Sharp Mind": "Scharfer Verstand", "Field Medic": "Feldsanitäter", "Soft Voice": "Sanfte Stimme",
    "Veteran": "Veteran", "Leaf Lore": "Blattkunde", "Tide Lore": "Flutkunde", "Ember Lore": "Glutkunde",
    "Stone Lore": "Steinkunde", "Gale Lore": "Sturmkunde", "Spark Lore": "Funkenkunde",
    "Frost Lore": "Frostkunde", "Shade Lore": "Schattenkunde", "Glow Lore": "Lichtkunde",
    "Wild Lore": "Wildkunde", "Thick Skin": "Dickes Fell", "Trusted": "Vertrauensperson",
    "Mentor": "Mentor", "Champion": "Champion",
    "Light Feet": "Leichtfüßig", "Stamina": "Ausdauer", "Forager": "Sammler", "Second Wind": "Zweiter Atem",
    "Treasure Nose": "Schatznase", "Efficient": "Effizient", "Trailblazer": "Pfadfinder",
    "Wild Harvest": "Wilde Ernte", "Deep Breath": "Tiefer Atem", "Map Reader": "Kartenleser",
    "Lucky Find": "Glücksfund", "Iron Will": "Eiserner Wille", "Night Walker": "Nachtwandler",
    "Gatherer": "Wildsammler", "Endurance": "Durchhaltevermögen", "Wayfarer": "Weltenbummler",
    "Steady Hands": "Ruhige Hände", "Prospector": "Prospektor", "Strong Swing": "Kräftiger Schlag",
    "Patient Angler": "Geduldiger Angler", "Tinkerer": "Tüftler", "Calm Reel": "Ruhige Rolle",
    "Gem Eye": "Edelsteinblick", "Bulk Crafter": "Massenfertigung", "Lucky Line": "Glücksschnur",
    "Deep Miner": "Tiefenbergmann", "Arcane Study": "Arkanes Studium", "Well Oiled": "Gut geölt",
    "Master Angler": "Meisterangler", "Motherlode": "Hauptader", "Artisan": "Kunsthandwerker",
    "Spellwright": "Zauberschmied", "Master Artisan": "Meisterhandwerker",
    "Haggler": "Feilscher", "Regular": "Stammkunde", "Charmer": "Charmeur", "Express Crate": "Expresskiste",
    "Absentee Owner": "Abwesender Besitzer", "Market Sense": "Marktgespür", "Lucky Chip": "Glückschip",
    "Bulk Buyer": "Großeinkäufer", "Export Deal": "Exportvertrag", "Socialite": "Gesellschaftslöwe",
    "Passive Income": "Passives Einkommen", "Merchant": "Kaufmann", "High Roller": "High Roller",
    "Bee Friend": "Bienenfreund", "Compost": "Kompost", "Treat Maker": "Leckerli-Bäcker",
    "Tough Workers": "Zähe Arbeiter", "Battle Hymn": "Kampfhymne", "Scout": "Späher", "Sprinter": "Sprinter",
    "Smelter": "Schmelzer", "Bargain Hunter": "Schnäppchenjäger", "Gift Wrap": "Geschenkpapier",
    "Wholesale": "Großhandel", "Loyal Customer": "Treuer Kunde", "Tycoon": "Tycoon",
}


def build():
    nodes = []
    branches = {}
    for bi, bid in enumerate(ORDER):
        b = BRANCHES[bid]
        branches[bid] = {"name": b["name"], "icon": b["icon"], "color": b["color"], "angle": bi * 60}
        ang = math.radians(bi * 60 - 90)
        axis = (math.cos(ang), math.sin(ang))
        side = (-axis[1], axis[0])
        by_tier = {}
        for n in b["nodes"]:
            by_tier.setdefault(n[2], []).append(n)
        prev = []
        for tier in sorted(by_tier):
            row = by_tier[tier]
            r = FIRST + (tier - 1) * RING
            spread = min(58.0, 30.0 + tier * 5.0)
            cur = []
            for i, (nid, name, _t, icon, ranks, mods, unlock) in enumerate(row):
                off = (i - (len(row) - 1) / 2.0) * spread
                pos = [round(axis[0] * r + side[0] * off), round(axis[1] * r + side[1] * off)]
                node = {"id": nid, "branch": bid, "tier": tier, "name": name, "icon": icon, "ranks": ranks,
                        "mods": mods, "pos": pos}
                if prev:
                    # Each node opens from the nearest one or two nodes of the tier below.
                    near = sorted(prev, key=lambda p: (p["pos"][0] - pos[0]) ** 2 + (p["pos"][1] - pos[1]) ** 2)
                    node["req"] = [p["id"] for p in near[:2 if tier == 7 else 1]]
                    if len(near) > 1 and tier < 7:
                        d0 = (near[0]["pos"][0] - pos[0]) ** 2 + (near[0]["pos"][1] - pos[1]) ** 2
                        d1 = (near[1]["pos"][0] - pos[0]) ** 2 + (near[1]["pos"][1] - pos[1]) ** 2
                        if d1 - d0 < 40:
                            node["req"].append(near[1]["id"])
                else:
                    node["req"] = []
                if tier == 7:
                    node["need"] = CAPSTONE_NEED
                if unlock:
                    node["unlock"] = unlock
                cur.append(node)
                nodes.append(node)
            prev = cur
    return {"branches": branches, "nodes": nodes}


def main():
    data = build()
    out = ROOT / "game/data/skills.json"
    with open(out, "w") as f:
        f.write("{\n  \"branches\": {\n")
        bl = list(data["branches"].items())
        for i, (k, v) in enumerate(bl):
            f.write("    %s: %s%s\n" % (json.dumps(k), json.dumps(v, ensure_ascii=False), "," if i < len(bl) - 1 else ""))
        f.write("  },\n  \"nodes\": [\n")
        for i, n in enumerate(data["nodes"]):
            f.write("    %s%s\n" % (json.dumps(n, ensure_ascii=False), "," if i < len(data["nodes"]) - 1 else ""))
        f.write("  ]\n}\n")
    total = sum(n["ranks"] for n in data["nodes"])
    print("wrote %s: %d nodes, %d ranks" % (out.relative_to(ROOT), len(data["nodes"]), total))
    if "--de" in sys.argv:
        dest = sys.argv[sys.argv.index("--de") + 1]
        with open(dest, "w") as f:
            json.dump(DE, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
