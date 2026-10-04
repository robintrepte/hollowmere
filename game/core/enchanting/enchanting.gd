class_name Enchanting
extends RefCounted
## Tool enchantments: three seeded offers per tool at the enchanting table (bookshelves nearby
## raise the level), books applied and combined at the anvil, and the grindstone to start over.
## Enchantments live on the player (PlayerData.tool_enchants) because tools are per-player levels.

const MAX_PER_TOOL := 3
const SHELF_RADIUS := 3
const SHELVES_PER_LEVEL := 3
const ROMAN := ["", "I", "II", "III", "IV", "V"]
const MATERIALS := ["arcane_essence", "glimmer_dust"]

static func data() -> Dictionary:
	return Data.enchants

static func spec(id: String) -> Dictionary:
	return data().get("enchants", {}).get(id, {})

static func tools() -> Array:
	return data().get("tools", [])

## Enchantments that can go on this tool, in data order.
static func for_tool(tool: String) -> Array:
	var out: Array = []
	var all: Dictionary = data().get("enchants", {})
	for id in all:
		if tool in all[id].get("tools", []):
			out.append(id)
	return out

static func on_tool(p: PlayerData, tool: String) -> Dictionary:
	return p.tool_enchants.get(tool, {}) if p else {}

static func level(p: PlayerData, tool: String, id: String) -> int:
	return int(on_tool(p, tool).get(id, 0))

static func has_any(p: PlayerData, tool: String) -> bool:
	return not on_tool(p, tool).is_empty()

## Modifier provider: every enchantment's bonus keys, scaled by level.
static func mods(p: PlayerData) -> Dictionary:
	var out := {}
	for tool in p.tool_enchants:
		var ench: Dictionary = p.tool_enchants[tool]
		for id in ench:
			var m: Dictionary = spec(id).get("mods", {}).get(tool, {})
			for k in m:
				out[k] = float(out.get(k, 0.0)) + float(m[k]) * int(ench[id])
	return out

## Energy factor while using a tool (Thrift, and Deep Dig on the shovel).
static func energy_scale(p: PlayerData, tool: String) -> float:
	var s := 1.0 - 0.1 * level(p, tool, "thrift")
	if tool == "shovel":
		s *= 1.0 - 0.2 * level(p, tool, "deep_dig")
	return maxf(0.3, s)

static func title(id: String, lvl: int) -> String:
	var nm := TranslationServer.translate(str(spec(id).get("name", id)))
	if int(spec(id).get("max", 1)) <= 1:
		return nm
	return "%s %s" % [nm, ROMAN[clampi(lvl, 0, ROMAN.size() - 1)]]

static func describe(ench: Dictionary) -> String:
	var parts: PackedStringArray = []
	for id in ench:
		parts.append(title(id, int(ench[id])))
	return ", ".join(parts)

# --- Table offers -------------------------------------------------------------------

## Bookshelves within SHELF_RADIUS tiles of the table.
static func shelves_near(g: FarmGrid, t: Vector2i) -> int:
	var n := 0
	for y in range(t.y - SHELF_RADIUS, t.y + SHELF_RADIUS + 1):
		for x in range(t.x - SHELF_RADIUS, t.x + SHELF_RADIUS + 1):
			if g.object_at(Vector2i(x, y)).get("id", "") == "bookshelf":
				n += 1
	return n

## Highest enchantment level the table can roll: 1 bare, 2 with 3 shelves, 3 with 6.
static func power(shelves: int) -> int:
	return clampi(1 + shelves / SHELVES_PER_LEVEL, 1, 3)

static func _pick(ids: Array, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for id in ids:
		total += float(spec(id).get("weight", 1))
	var r := rng.randf() * total
	for id in ids:
		r -= float(spec(id).get("weight", 1))
		if r <= 0.0:
			return id
	return ids[-1]

## Three offers for a tool: [{slot, enchants: {id: lvl}, shown: [id, lvl], essence, dust}].
## The same player, tool, shelf count and seed always give the same offers.
static func offers(p: PlayerData, tool: String, shelves: int, cost_mult: float = 1.0) -> Array:
	var pool := for_tool(tool)
	if pool.is_empty():
		return []
	var cfg: Dictionary = data().get("offers", {})
	var pw := power(shelves)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([p.id, tool, int(p.flags.get("enchant_seed", 0)), pw])
	var out: Array = []
	for s in 3:
		var target := clampi(int(ceil(pw * (s + 1) / 3.0)), 1, pw)
		var first := _pick(pool, rng)
		var ench := {first: mini(target, int(spec(first).get("max", 1)))}
		if rng.randf() < float(cfg.get("extra", [0, 0, 0])[s]):
			var rest := pool.filter(func(e): return not ench.has(e))
			if not rest.is_empty():
				var second := _pick(rest, rng)
				ench[second] = mini(maxi(1, target - 1), int(spec(second).get("max", 1)))
		out.append({
			"slot": s, "enchants": ench, "shown": [first, int(ench[first])],
			"essence": maxi(1, int(ceil((int(cfg.get("essence", [1, 2, 3])[s]) + target - 1) * cost_mult))),
			"dust": maxi(1, int(ceil(int(cfg.get("dust", [2, 4, 6])[s]) * cost_mult))),
		})
	return out

# --- Books, anvil and grindstone ----------------------------------------------------------

static func book_id(id: String, lvl: int) -> String:
	return "book:%s:%d" % [id, lvl]

## [enchant_id, level] for a book item, or [] for anything else.
static func parse_book(item_id: String) -> Array:
	var parts := item_id.split(":")
	if parts.size() != 3 or parts[0] != "book" or spec(parts[1]).is_empty():
		return []
	return [parts[1], clampi(int(parts[2]), 1, int(spec(parts[1]).get("max", 1)))]

static func random_book(rng: RandomNumberGenerator, max_level: int = 2) -> String:
	var ids: Array = data().get("enchants", {}).keys()
	var id := _pick(ids, rng)
	return book_id(id, rng.randi_range(1, mini(max_level, int(spec(id).get("max", 1)))))

## What a book does to a tool's enchantments: {ok, enchants, reason}.
static func apply_book(current: Dictionary, tool: String, id: String, lvl: int) -> Dictionary:
	if not tool in spec(id).get("tools", []):
		return {"ok": false, "reason": TranslationServer.translate("That book doesn't work on this tool.")}
	var next := current.duplicate()
	var have := int(current.get(id, 0))
	var mx := int(spec(id).get("max", 1))
	if have > 0:
		if lvl == have and have < mx:
			next[id] = have + 1
		elif lvl > have:
			next[id] = lvl
		else:
			return {"ok": false, "reason": TranslationServer.translate("The tool already has that enchantment at this strength.")}
	elif current.size() >= MAX_PER_TOOL:
		return {"ok": false, "reason": TranslationServer.translate("A tool can hold at most three enchantments.")}
	else:
		next[id] = lvl
	return {"ok": true, "enchants": next}

## Two equal books make one a level higher, or "" if they can't be combined.
static func combine_books(item_id: String) -> String:
	var b := parse_book(item_id)
	if b.is_empty() or int(b[1]) >= int(spec(b[0]).get("max", 1)):
		return ""
	return book_id(b[0], int(b[1]) + 1)

static func anvil_cost(lvl: int) -> int:
	return maxi(1, lvl * int(data().get("anvil", {}).get("essence_per_level", 1)))

## Essence the grindstone gives back for a tool's enchantments.
static func refund(current: Dictionary) -> int:
	var total := 0
	for id in current:
		total += int(current[id])
	return int(floor(total * float(data().get("grindstone", {}).get("refund", 0.5))))
