extends Node
## Content registry. Loads all JSON content from res://data and derives
## learnsets, egg moves, seed/crop items and artisan goods.

const SEASONS := ["spring", "summer", "fall", "winter"]
const STATS := ["hp", "power", "guard", "focus", "speed"]
const QUALITY_MULT := [1.0, 1.25, 1.5, 2.0]
const QUALITY_NAMES := ["", "Silver", "Gold", "Star"]
## Seed quality is its tier: how many harvests the plant gives (see CropGrowth.TIER_HARVESTS).
const SEED_TIER_NAMES := ["Common", "Refined", "Noble", "Everlasting"]
const EGG_GROUP_TYPE := {
	"flora": "leaf", "aqua": "tide", "mineral": "stone", "sky": "gale", "fairy": "glow",
	"spirit": "shade", "bug": "spark", "field": "wild", "amorphous": "shade", "beast": "ember",
}

var types: Dictionary = {}
var type_order: Array = []
var chart: Dictionary = {}
var natures: Dictionary = {}
var traits: Dictionary = {}
var moves: Dictionary = {}
var species: Dictionary = {}
var species_order: Array = []
var crops: Dictionary = {}
var crop_order: Array = []
var trees: Dictionary = {}
var items: Dictionary = {}
var recipes: Dictionary = {}
var machines: Dictionary = {}
var buildings: Dictionary = {}
var shops: Dictionary = {}
var villagers: Dictionary = {}
var regions: Dictionary = {}
var region_order: Array = []
var legends: Dictionary = {}
var progression: Dictionary = {}
## Side, tutorial, seasonal and event quests by id (data/quests.json), in file order.
var quests: Dictionary = {}
var quest_order: Array = []
var quest_daily: Array = []
var _maps: Dictionary = {}
var _prev_evo: Dictionary = {}

func _ready() -> void:
	load_all()

func load_all() -> void:
	var t: Dictionary = _load_json("res://data/types.json")
	type_order = t.order
	types = t.info
	chart = t.chart
	natures = _load_json("res://data/natures.json")
	traits = _load_json("res://data/traits.json")
	moves = _load_json("res://data/moves.json")
	_load_species()
	_load_crops()
	progression = _load_json("res://data/progression.json")
	var qd: Dictionary = _load_json("res://data/quests.json")
	for q in qd.get("quests", []):
		quests[q.id] = q
		quest_order.append(q.id)
	quest_daily = qd.get("daily", [])
	items = _load_json("res://data/items.json")
	trees = _load_json("res://data/trees.json")
	_derive_items()
	var r: Dictionary = _load_json("res://data/recipes.json")
	recipes = {"cooking": r.cooking, "crafting": r.crafting}
	machines = r.machines
	buildings = _load_json("res://data/buildings.json")
	shops = _load_json("res://data/shops.json")
	villagers = _load_json("res://data/villagers.json")
	var reg: Dictionary = _load_json("res://data/regions.json")
	legends = reg.get("legends", {})
	reg.erase("legends")
	regions = reg
	region_order = regions.keys()
	region_order.sort_custom(func(a, b): return int(regions[a].order) < int(regions[b].order))

func _load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Data: cannot open %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed == null:
		push_error("Data: invalid JSON in %s" % path)
		return {}
	return parsed

static func table_to_dicts(table: Dictionary) -> Array:
	var cols: Array = table.columns
	var out: Array = []
	for row in table.rows:
		var d := {}
		for i in cols.size():
			d[cols[i]] = row[i]
		out.append(d)
	return out

# --- Species -----------------------------------------------------------------

func _load_species() -> void:
	species.clear()
	species_order.clear()
	_prev_evo.clear()
	for d in table_to_dicts(_load_json("res://data/creatures.json")):
		var b: Array = d.base
		d["base_stats"] = {"hp": b[0], "power": b[1], "guard": b[2], "focus": b[3], "speed": b[4]}
		d["dex"] = species_order.size() + 1
		species[d.id] = d
		species_order.append(d.id)
	for id in species_order:
		var evo = species[id].evo
		if evo != null:
			_prev_evo[evo[0]] = id
	for id in species_order:
		var sp: Dictionary = species[id]
		sp["learnset"] = _build_learnset(sp)
		sp["egg_moves"] = _build_egg_moves(sp)
		sp["traits"] = [_pinch_trait(sp.types[0]), sp.trait2] if sp.trait2 != "ancient" else ["ancient"]
		sp["stage"] = _stage_of(id)
		sp["legendary"] = sp.egg.has("none")

func _pinch_trait(t: String) -> String:
	for k in traits:
		if traits[k].get("pinch", "") == t:
			return k
	return "hardworker"

func _stage_of(id: String) -> int:
	var s := 1
	var cur := id
	while _prev_evo.has(cur):
		cur = _prev_evo[cur]
		s += 1
	return s

func base_form(id: String) -> String:
	var cur := id
	while _prev_evo.has(cur):
		cur = _prev_evo[cur]
	return cur

func prev_form(id: String) -> String:
	return _prev_evo.get(id, "")

## Returns the form a species line would be at a given level, starting from `id`.
func form_at_level(id: String, level: int) -> String:
	var cur := id
	var guard := 0
	while guard < 4:
		guard += 1
		var evo = species[cur].evo
		if evo == null or level < int(evo[1]):
			break
		cur = evo[0]
	return cur

func _move_sort_power(m: Dictionary) -> float:
	if m.cat == "status":
		return 52.0
	return float(m.power) * (float(m.acc) / 100.0 if m.acc > 0 else 1.05)

func _build_learnset(sp: Dictionary) -> Array:
	var types_list: Array = sp.types
	var prefers_phys: bool = sp.base_stats.power >= sp.base_stats.focus
	var pool: Array = []
	for mid in moves:
		var m: Dictionary = moves[mid]
		if m.type in types_list:
			if m.cat != "status" and ((m.cat == "phys") != prefers_phys) and m.power < 60:
				continue
			pool.append(mid)
	if not "wild" in types_list:
		pool.append("tackle")
		pool.append("growl")
	pool.sort_custom(func(a, b): return _move_sort_power(moves[a]) < _move_sort_power(moves[b]))
	var out: Array = []
	var levels := [1, 1, 4, 7, 11, 15, 19, 23, 28, 33, 38, 43, 48, 53, 58, 63, 68]
	for i in pool.size():
		out.append([levels[min(i, levels.size() - 1)], pool[i]])
	return out

func _build_egg_moves(sp: Dictionary) -> Array:
	var learned := {}
	for e in sp.learnset:
		learned[e[1]] = true
	var out: Array = []
	for g in sp.egg:
		var t: String = EGG_GROUP_TYPE.get(g, "")
		if t == "":
			continue
		var cands: Array = []
		for mid in moves:
			if moves[mid].type == t and not learned.has(mid) and moves[mid].cat != "status":
				cands.append(mid)
		cands.sort_custom(func(a, b): return moves[a].power < moves[b].power)
		if cands.size() > 0:
			var pick: String = cands[cands.size() / 2]
			if not out.has(pick):
				out.append(pick)
	return out

func get_species(id: String) -> Dictionary:
	return species.get(id, {})

func get_move(id: String) -> Dictionary:
	return moves.get(id, moves.get("struggle"))

func type_mult(atk_type: String, def_types: Array) -> float:
	var m := 1.0
	var row: Dictionary = chart.get(atk_type, {})
	for d in def_types:
		m *= float(row.get(d, 1.0))
	return m

func type_color(t: String) -> Color:
	return Color(types[t].color) if types.has(t) else Color.GRAY

## Type info ({job, job_name, job_desc, ...}) for the type that performs `job_id`.
func job_info(job_id: String) -> Dictionary:
	for t in types:
		if types[t].get("job", "") == job_id:
			return types[t]
	return {}

func type_name(t: String) -> String:
	return tr(types[t].name) if types.has(t) else t.capitalize()

# --- Crops & items -----------------------------------------------------------

func _load_crops() -> void:
	crops.clear()
	crop_order.clear()
	for d in table_to_dicts(_load_json("res://data/crops.json")):
		crops[d.id] = d
		crop_order.append(d.id)

func _derive_items() -> void:
	for b in progression.get("backpacks", []):
		items[b.id] = {"name": b.name, "cat": "backpack", "sell": 0, "base": "_backpack", "icon": b.id, "desc": b.get("desc", "")}
	for cid in crop_order:
		var c: Dictionary = crops[cid]
		var flower: bool = cid in ["tulip", "blue_jazz", "sunflower", "fairy_rose", "ice_lily", "moonbloom"]
		items[cid] = {
			"name": c.name, "cat": "crop", "sell": c.sell, "color": c.color, "icon": "crop",
			"energy": 0 if flower else int(max(8, c.sell / 3)), "treat": 1.2, "crop": cid,
			"desc": "A fresh %s. Grows in %s." % [c.name.to_lower(), ", ".join(c.seasons)],
		}
		items[cid + "_seeds"] = {
			"name": c.name + " Seeds", "cat": "seed", "sell": int(c.seed / 2), "buy": c.seed, "color": c.color,
			"icon": "seed", "crop": cid,
			"desc": "Plant in %s. Takes %d days to grow%s." % [", ".join(c.seasons), c.days, (", then regrows every %d days" % c.regrow) if c.regrow > 0 else ""],
		}
	for tid in trees:
		var t: Dictionary = trees[tid]
		items[tid] = {"name": t.name, "cat": "fruit", "sell": t.sell, "energy": int(t.sell / 3), "treat": 1.4, "color": t.color, "icon": "berry", "desc": "Fresh from the orchard."}
		items[tid + "_sapling"] = {"name": t.name + " Sapling", "cat": "sapling", "sell": int(t.sapling / 2), "buy": t.sapling, "color": t.color, "icon": "sapling", "tree": tid, "size": [1, 2],
			"desc": "Plant on open farmland. Grows into a tree in %d days, then gives fruit every day in %s." % [t.days, ", ".join(t.seasons)]}

const BIG_ITEMS := {
	"melon": [2, 2], "pumpkin": [2, 2], "winter_squash": [2, 2], "glacier_melon": [2, 2], "corn": [1, 2], "sunflower": [1, 2],
	"hoe": [1, 2], "axe": [1, 2], "pickaxe": [1, 2], "scythe": [1, 2], "watering_can": [2, 2],
	"chest": [2, 2], "furnace": [2, 2], "keg": [1, 2], "seed_maker": [2, 2], "scarecrow": [1, 2], "wooden_bench": [2, 1],
	"stone_lantern": [1, 2], "hay_bale": [2, 1], "wood": [2, 1], "hardwood": [2, 1], "milk": [1, 2],
	"copper_bar": [2, 1], "iron_bar": [2, 1], "gold_bar": [2, 1], "mystic_bar": [2, 1],
}
const STACKS := {
	"seed": 99, "crop": 24, "forage": 24, "fruit": 24, "material": 99, "ore": 50, "bar": 20, "gem": 10, "produce": 20,
	"food": 10, "treat": 20, "charm": 20, "medicine": 10, "artisan": 10, "fertilizer": 50, "placeable": 10,
	"key": 1, "gift": 5, "cosmetic": 1, "tool": 1, "egg": 1, "container": 1, "sapling": 5,
}

func item_size(id: String) -> Vector2i:
	var it := get_item(id)
	if it.has("size"):
		return Vector2i(int(it.size[0]), int(it.size[1]))
	var key: String = it.get("base", id)
	if BIG_ITEMS.has(key) and not it.has("base"):
		return Vector2i(BIG_ITEMS[key][0], BIG_ITEMS[key][1])
	if it.get("cat", "") == "artisan":
		return Vector2i(1, 1)
	return Vector2i(1, 1)

func stack_max(id: String) -> int:
	return int(STACKS.get(get_item(id).get("cat", ""), 20))

func container_spec(id: String) -> Dictionary:
	return get_item(id).get("container", {})

func has_item(id: String) -> bool:
	return not get_item(id).is_empty()

func get_item(id: String) -> Dictionary:
	if items.has(id):
		return items[id]
	if ":" in id:
		var parts := id.split(":")
		var prefix := parts[0]
		var base_id := parts[1]
		if not items.has(base_id):
			return {}
		var base: Dictionary = items[base_id]
		var d := {}
		match prefix:
			"juice":
				d = {"name": base.name + " Juice", "cat": "artisan", "sell": int(base.sell * 2.25), "energy": int(base.get("energy", 20) * 1.5), "treat": 1.5, "icon": "bottle", "color": base.get("color", "#ffffff"), "desc": "Fresh-pressed juice."}
			"jam":
				d = {"name": base.name + " Jam", "cat": "artisan", "sell": int(base.sell * 2 + 50), "energy": int(base.get("energy", 20) * 1.5), "treat": 1.6, "icon": "jar", "color": base.get("color", "#ffffff"), "desc": "Sweet preserves."}
			"preserved":
				d = {"name": "Frozen " + base.name, "cat": "artisan", "sell": int(base.sell * 1.6 + 20), "energy": int(base.get("energy", 20)), "treat": 1.3, "icon": "crop", "color": base.get("color", "#ffffff"), "desc": "Preserved by a Frost Wildling."}
			_:
				return {}
		d["base"] = base_id
		items[id] = d
		return d
	return {}

func item_name(id: String, quality: int = 0) -> String:
	var it := get_item(id)
	if it.is_empty():
		return id
	var nm := _display_item_name(id, it)
	if quality > 0 and it.get("cat", "") == "seed":
		return tr("%s (%s)") % [nm, tr(SEED_TIER_NAMES[clampi(quality, 0, 3)])]
	if quality > 0:
		return "%s %s" % [tr(QUALITY_NAMES[quality]), nm]
	return nm

func _display_item_name(id: String, it: Dictionary) -> String:
	if it.get("cat") == "seed" and it.has("crop") and crops.has(it.crop):
		return tr("%s Seeds") % tr(str(crops[it.crop].name))
	if it.get("cat") == "sapling" and it.has("tree") and trees.has(it.tree):
		return tr("%s Sapling") % tr(str(trees[it.tree].name))
	if ":" in id:
		var parts := id.split(":")
		var base: Dictionary = get_item(parts[1]) if parts.size() > 1 else {}
		var base_name := tr(str(base.get("name", parts[1]))) if not base.is_empty() else parts[1]
		match parts[0]:
			"juice":
				return tr("%s Juice") % base_name
			"jam":
				return tr("%s Jam") % base_name
			"preserved":
				return tr("Frozen %s") % base_name
	return tr(str(it.name))

func season_name(season: String) -> String:
	match season:
		"spring":
			return tr("Spring")
		"summer":
			return tr("Summer")
		"fall":
			return tr("Fall")
		"winter":
			return tr("Winter")
	return season

func season_list(seasons: Array) -> String:
	var names: PackedStringArray = []
	for s in seasons:
		names.append(season_name(str(s)))
	return ", ".join(names)

func item_desc(id: String) -> String:
	var it := get_item(id)
	if it.is_empty():
		return ""
	if it.get("cat") == "crop" and it.has("crop") and crops.has(it.crop):
		var c: Dictionary = crops[it.crop]
		return tr("A fresh %s. Grows in %s.") % [tr(str(c.name)).to_lower(), season_list(c.seasons)]
	if it.get("cat") == "seed" and it.has("crop") and crops.has(it.crop):
		var c: Dictionary = crops[it.crop]
		var full := CropGrowth.grow_minutes(it.crop) * 60.0
		var extra := tr(", then again every %s") % TimeService.duration_text(full * (1.0 - CropGrowth.regrow_progress(it.crop))) if int(c.regrow) > 0 else ""
		return tr("Grows fastest in %s: ripe in %s when watered%s. Grows slower in other seasons, and always well in the greenhouse.") % [season_list(c.seasons), TimeService.duration_text(full), extra]
	if it.get("cat") == "sapling" and it.has("tree") and trees.has(it.tree):
		var t: Dictionary = trees[it.tree]
		return tr("Plant on open farmland. Grows into a tree in %s, then gives fruit every %s in %s.") % [TimeService.duration_text(float(t.days) * CropGrowth.TREE_DAY_SECONDS), TimeService.duration_text(CropGrowth.FRUIT_SECONDS), season_list(t.seasons)]
	if it.get("cat") == "fruit":
		return tr("Fresh from the orchard.")
	if ":" in id:
		match id.split(":")[0]:
			"juice":
				return tr("Fresh-pressed juice.")
			"jam":
				return tr("Sweet preserves.")
			"preserved":
				return tr("Preserved by a Frost Wildling.")
	return tr(str(it.get("desc", "")))

func sell_price(id: String, quality: int = 0) -> int:
	var it := get_item(id)
	return int(round(float(it.get("sell", 0)) * QUALITY_MULT[clampi(quality, 0, 3)]))

func buy_price(id: String) -> int:
	var it := get_item(id)
	return int(it.get("buy", max(1, it.get("sell", 1) * 3)))

func seeds_for_season(season: String) -> Array:
	var out: Array = []
	for cid in crop_order:
		if season in crops[cid].seasons:
			out.append(cid + "_seeds")
	return out

func is_edible(id: String) -> bool:
	return int(get_item(id).get("energy", 0)) > 0

func treat_power(item_id: String, species_id: String) -> float:
	var it := get_item(item_id)
	if not it.has("treat"):
		return 0.0
	var p := float(it.treat)
	var sp := get_species(species_id)
	if not sp.is_empty():
		var base_id: String = it.get("base", item_id)
		if sp.fav == item_id or sp.fav == base_id:
			p *= 2.0
	return p

# --- Maps ---------------------------------------------------------------------

func get_map(id: String) -> Dictionary:
	if _maps.has(id):
		return _maps[id]
	var path := "res://data/maps/%s.json" % id
	if not FileAccess.file_exists(path):
		return {}
	var m: Dictionary = _load_json(path)
	_maps[id] = m
	return m

func region_name(id: String) -> String:
	if regions.has(id):
		return tr(regions[id].name)
	var m := get_map(id)
	return tr(m.get("name", id.capitalize()))

func region_by_order(order: int) -> String:
	for id in region_order:
		if int(regions[id].order) == order:
			return id
	return ""

func villager_name(id: String) -> String:
	return villagers[id].name if villagers.has(id) else id.capitalize()
