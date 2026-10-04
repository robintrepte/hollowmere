class_name PlayerData
extends RefCounted
## Per-player state. In co-op the host stores all farmhands' PlayerData in its save.

const HOTBAR_SIZE := 10
const PARTY_MAX := 6
const TOOLS := ["hoe", "watering_can", "pickaxe", "axe", "scythe"]

var id: String = "local"
var name: String = "Farmer"
var look: Dictionary = {"skin": "#f0c8a0", "hair": "#5a3a2a", "shirt": "#4a8ac0", "pants": "#3a3a5a", "style": 0}
var hat: String = ""
var inventory: Inventory
var hotbar: Array = []          # [{uid, id}] or {} per slot
var selected: int = 0
var party: Array = []           # Array[Creature]; party[0] is the lead
var tool_levels: Dictionary = {"hoe": 0, "watering_can": 0, "pickaxe": 0, "axe": 0, "scythe": 0}
var water_left: int = 40
var bucket_full: bool = false
var energy: float = 270.0
var max_energy: float = 270.0
var backpack_level: int = 0
var relationships: Dictionary = {}
var recipes: Array = []
var cosmetics: Array = []
var map_id: String = "farm"
var pos: Vector2 = Vector2(7 * 32 + 16, 6 * 32)
var skills: Dictionary = {"farming": 0, "foraging": 0, "mining": 0, "taming": 0}
var stats: Dictionary = {}

func _init() -> void:
	var bp: Dictionary = Economy.backpack_spec(0)
	inventory = Inventory.new(int(bp.get("w", 7)), int(bp.get("h", 4)))
	hotbar.resize(HOTBAR_SIZE)
	for i in HOTBAR_SIZE:
		hotbar[i] = {}

func give_starter_kit() -> void:
	for t in TOOLS:
		inventory.add(t, 1)
	inventory.add("shovel", 1)
	inventory.add("bucket", 1)
	inventory.add("parsnip_seeds", 15)
	inventory.add("basic_treat", 5)
	inventory.add("lure_charm", 5)
	inventory.add("potion", 3)
	inventory.add("seed_pouch", 1)
	var i := 0
	for t in TOOLS:
		bind_hotbar(i, inventory.first_of(t))
		i += 1
	bind_hotbar(5, inventory.first_of("parsnip_seeds"))
	bind_hotbar(6, inventory.first_of("basic_treat"))
	bind_hotbar(7, inventory.first_of("lure_charm"))

func bind_hotbar(slot: int, entry: Dictionary) -> void:
	if slot < 0 or slot >= HOTBAR_SIZE:
		return
	if entry.is_empty():
		hotbar[slot] = {}
		return
	for i in HOTBAR_SIZE:
		if not hotbar[i].is_empty() and hotbar[i].uid == entry.uid:
			hotbar[i] = {}
	hotbar[slot] = {"uid": entry.uid, "id": entry.id}

## Resolves a hotbar slot to a live inventory entry (re-binding by id if the stack was used up).
func hotbar_entry(slot: int) -> Dictionary:
	var b: Dictionary = hotbar[slot]
	if b.is_empty():
		return {}
	var f := inventory.find(b.uid)
	if not f.is_empty():
		return f.entry
	var e := inventory.first_of(b.id)
	if not e.is_empty():
		hotbar[slot] = {"uid": e.uid, "id": e.id}
		return e
	return {}

func selected_entry() -> Dictionary:
	return hotbar_entry(selected)

func selected_id() -> String:
	var e := selected_entry()
	return e.id if not e.is_empty() else ""

func tool_level(tool: String) -> int:
	return int(tool_levels.get(tool, 0))

func water_capacity() -> int:
	return 40 + 15 * tool_level("watering_can")

func lead() -> Creature:
	for c in party:
		if not c.is_fainted():
			return c
	return party[0] if party.size() > 0 else null

func has_usable_party() -> bool:
	for c in party:
		if not c.is_fainted():
			return true
	return false

func heal_party() -> void:
	for c in party:
		c.heal_full()

func set_backpack(level: int) -> bool:
	var bp := Economy.backpack_spec(level)
	if bp.is_empty():
		return false
	var bigger := Inventory.new(int(bp.w), int(bp.h))
	for e in inventory.entries.duplicate():
		var placed := bigger.move_from(inventory, e.uid, int(e.x), int(e.y), bool(e.r))
		if not placed:
			var spot := bigger.find_space(e.id)
			if spot.is_empty() or not bigger.move_from(inventory, e.uid, int(spot.x), int(spot.y), bool(spot.r)):
				return false
	inventory = bigger
	backpack_level = level
	return true

func relationship(vid: String) -> Dictionary:
	if not relationships.has(vid):
		relationships[vid] = Relationships.new_state()
	return relationships[vid]

func hearts_dict() -> Dictionary:
	var out := {}
	for v in relationships:
		out[v] = Relationships.hearts(relationships[v])
	return out

func stat_add(key: String, n: int = 1) -> void:
	stats[key] = int(stats.get(key, 0)) + n

func to_dict() -> Dictionary:
	var p: Array = []
	for c in party:
		p.append(c.to_dict())
	return {
		"id": id, "name": name, "look": look, "hat": hat, "inventory": inventory.to_dict(), "hotbar": hotbar,
		"selected": selected, "party": p, "tool_levels": tool_levels, "water_left": water_left, "bucket_full": bucket_full,
		"energy": energy, "max_energy": max_energy, "backpack_level": backpack_level,
		"relationships": relationships, "recipes": recipes, "cosmetics": cosmetics, "map_id": map_id,
		"pos": [pos.x, pos.y], "skills": skills, "stats": stats,
	}

static func from_dict(d: Dictionary) -> PlayerData:
	var p := PlayerData.new()
	p.id = d.get("id", "local")
	p.name = d.get("name", "Farmer")
	p.look = d.get("look", p.look)
	p.hat = d.get("hat", "")
	p.inventory = Inventory.new(7, 4)
	p.inventory.from_dict(d.get("inventory", {}))
	var hb: Array = d.get("hotbar", [])
	for i in HOTBAR_SIZE:
		p.hotbar[i] = hb[i] if i < hb.size() and hb[i] is Dictionary else {}
	p.selected = int(d.get("selected", 0))
	p.party = []
	for c in d.get("party", []):
		p.party.append(Creature.from_dict(c))
	for k in d.get("tool_levels", {}):
		p.tool_levels[k] = int(d.tool_levels[k])
	p.water_left = int(d.get("water_left", 40))
	p.bucket_full = bool(d.get("bucket_full", false))
	p.energy = float(d.get("energy", 270))
	p.max_energy = float(d.get("max_energy", 270))
	p.backpack_level = int(d.get("backpack_level", 0))
	p.relationships = d.get("relationships", {})
	p.recipes = d.get("recipes", [])
	p.cosmetics = d.get("cosmetics", [])
	p.map_id = d.get("map_id", "farm")
	var pp: Array = d.get("pos", [p.pos.x, p.pos.y])
	p.pos = Vector2(float(pp[0]), float(pp[1]))
	p.skills = d.get("skills", p.skills)
	p.stats = d.get("stats", {})
	return p
