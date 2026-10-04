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
var chips: int = 0
## Side, daily and tutorial quest state (see Quests).
var quests: Dictionary = {}
## Bonus skill points from quest rewards (levels, chapters and shrines are counted by Skills).
var skill_points: int = 0
## Player level and XP toward the next one (separate from the farm level).
var level: int = 1
var xp: int = 0
## Skill tree: node id -> invested ranks.
var tree: Dictionary = {}
var respecs: int = 0
var mods_cache: Dictionary = {}
var mods_dirty: bool = true
var emotes: Array = []
## Fishdex {dex: {fish: {n, best}}} plus the bait and tackle on the rod.
var fishing: Dictionary = {}
## One-off per-player markers (gifts received, first visits).
var flags: Dictionary = {}
var energy: float = 270.0
var max_energy: float = 270.0
## The equipped pack and every pack the player owns (switchable any time the contents fit).
var backpack: String = "pack_rucksack"
var packs: Array = ["pack_rucksack"]
var relationships: Dictionary = {}
var recipes: Array = []
var cosmetics: Array = []
var map_id: String = "farm"
var pos: Vector2 = Vector2(7 * 32 + 16, 6 * 32)
var stats: Dictionary = {}

func _init() -> void:
	var bp: Dictionary = Economy.backpack_spec("pack_rucksack")
	inventory = Inventory.new(int(bp.get("w", 9)), int(bp.get("h", 5)))
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

## Switches to an owned pack. Fails (and changes nothing) if the current contents don't fit.
func set_backpack(id: String) -> bool:
	var bp := Economy.backpack_spec(id)
	if bp.is_empty():
		return false
	var next := Inventory.new(int(bp.w), int(bp.h))
	var probe := Inventory.new(inventory.w, inventory.h)
	probe.from_dict(inventory.to_dict())
	for e in probe.entries.duplicate():
		var placed := next.move_from(probe, e.uid, int(e.x), int(e.y), bool(e.r))
		if not placed:
			var spot := next.find_space(e.id)
			if spot.is_empty() or not next.move_from(probe, e.uid, int(spot.x), int(spot.y), bool(spot.r)):
				return false
	inventory = next
	backpack = id
	if not id in packs:
		packs.append(id)
	return true

func pack_mods() -> Dictionary:
	return Economy.backpack_spec(backpack).get("mods", {})

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
	gain_xp(Skills.xp_for_stat(key, n))

func gain_xp(n: int) -> void:
	if Skills.add_xp(self, n) > 0:
		EventBus.player_leveled.emit(id, level)

## Max energy with skill and item bonuses.
func energy_cap() -> float:
	return max_energy * Modifiers.mult(self, "max_energy")

## Villager friendship, with the friendship bonus.
func add_friendship(vid: String, n: int) -> void:
	Relationships.add_points(vid, relationship(vid), int(round(n * Modifiers.mult(self, "friendship"))) if n > 0 else n)

func to_dict() -> Dictionary:
	var p: Array = []
	for c in party:
		p.append(c.to_dict())
	return {
		"id": id, "name": name, "look": look, "hat": hat, "inventory": inventory.to_dict(), "hotbar": hotbar,
		"selected": selected, "party": p, "tool_levels": tool_levels, "water_left": water_left, "bucket_full": bucket_full, "chips": chips, "quests": quests, "skill_points": skill_points, "emotes": emotes, "level": level, "xp": xp, "tree": tree, "respecs": respecs,
		"fishing": fishing, "flags": flags,
		"energy": energy, "max_energy": max_energy, "backpack": backpack, "packs": packs,
		"relationships": relationships, "recipes": recipes, "cosmetics": cosmetics, "map_id": map_id,
		"pos": [pos.x, pos.y], "stats": stats,
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
	p.chips = int(d.get("chips", 0))
	p.quests = d.get("quests", {})
	p.skill_points = int(d.get("skill_points", 0))
	p.level = clampi(int(d.get("level", 1)), 1, Skills.MAX_LEVEL)
	p.xp = int(d.get("xp", 0))
	p.tree = d.get("tree", {})
	p.respecs = int(d.get("respecs", 0))
	p.emotes = d.get("emotes", [])
	p.fishing = d.get("fishing", {})
	p.flags = d.get("flags", {})
	p.energy = float(d.get("energy", 270))
	p.max_energy = float(d.get("max_energy", 270))
	if d.has("backpack"):
		p.backpack = str(d.backpack)
		p.packs = d.get("packs", [p.backpack])
	else:
		var lvl := int(d.get("backpack_level", 0))
		p.backpack = Economy.backpack_for_level(lvl)
		p.packs = []
		for i in lvl + 1:
			p.packs.append(Economy.backpack_for_level(i))
	var spec := Economy.backpack_spec(p.backpack)
	if not spec.is_empty() and (p.inventory.w < int(spec.w) or p.inventory.h < int(spec.h)):
		p.set_backpack(p.backpack)
	p.relationships = d.get("relationships", {})
	p.recipes = d.get("recipes", [])
	p.cosmetics = d.get("cosmetics", [])
	p.map_id = d.get("map_id", "farm")
	var pp: Array = d.get("pos", [p.pos.x, p.pos.y])
	p.pos = Vector2(float(pp[0]), float(pp[1]))
	p.stats = d.get("stats", {})
	return p
