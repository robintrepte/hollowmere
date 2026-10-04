class_name Economy
extends RefCounted
## Unlock gates, shop stock, crafting and building costs. Pure logic.
## `ctx` = {shrines:int, farm_level:int, hearts:{villager:int}, recipes:Array, buildings:Array}

static func meets(req: String, ctx: Dictionary) -> bool:
	if req == "" or req == "start":
		return true
	var parts := req.split(":")
	match parts[0]:
		"shrine":
			return int(ctx.get("shrines", 0)) >= int(parts[1])
		"level":
			return int(ctx.get("farm_level", 1)) >= int(parts[1])
		"hearts":
			return int(ctx.get("hearts", {}).get(parts[1], 0)) >= int(parts[2])
		"fish":
			return int(ctx.get("fish", 0)) >= int(parts[1])
		"depth":
			return int(ctx.get("depth", 0)) >= int(parts[1])
		"story":
			return int(ctx.get("quest", 0)) >= Adventure.chapter_index(parts[1])
		"vip":
			return bool(ctx.get("vip", false))
	return req in ctx.get("buildings", [])

static func req_text(req: String) -> String:
	var parts := req.split(":")
	match parts[0]:
		"shrine":
			return str(TranslationServer.translate("Restore %d shrines")) % int(parts[1])
		"level":
			return str(TranslationServer.translate("Farm Level %d")) % int(parts[1])
		"hearts":
			return str(TranslationServer.translate("%d hearts with %s")) % [int(parts[2]), Data.villager_name(parts[1])]
		"fish":
			return str(TranslationServer.translate("Catch %d kinds of fish")) % int(parts[1])
		"depth":
			return str(TranslationServer.translate("Reach the %s")) % TranslationServer.translate(str(Mining.layer_spec(int(parts[1])).get("name", "Deep Mine")))
		"story":
			var ci := Adventure.chapter_index(parts[1])
			var chs := Adventure.chapters()
			return str(TranslationServer.translate("Story: reach \"%s\"")) % (TranslationServer.translate(str(chs[ci].title)) if ci < chs.size() else parts[1])
		"vip":
			return str(TranslationServer.translate("Casino VIP: stake %s chips in total")) % Num.group(int(Casino.cfg().get("vip_turnover", 25000)))
	if Data.buildings.has(req):
		return str(TranslationServer.translate("Requires %s")) % str(TranslationServer.translate(Data.buildings[req].name))
	return req

## Shops that take casino chips instead of gold.
static func chip_shop(shop_id: String) -> bool:
	return str(Data.shops.get(shop_id, {}).get("currency", "gold")) == "chips"

## Returns [{id, price, locked:bool, req}]
static func shop_stock(shop_id: String, season: String, ctx: Dictionary, day_index: int = 0, world_seed: int = 0) -> Array:
	var shop: Dictionary = Data.shops.get(shop_id, {})
	var out: Array = []
	if shop.has("pool"):
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([world_seed, day_index, "traveler"])
		var pool: Array = shop.pool.duplicate()
		for i in range(pool.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var tmp = pool[i]
			pool[i] = pool[j]
			pool[j] = tmp
		for i in mini(int(shop.random), pool.size()):
			out.append({"id": pool[i].id, "price": int(pool[i].price), "locked": false, "req": ""})
		return out
	for s in shop.get("stock", []):
		var req: String = s.get("requires", "")
		if s.id == "@season_seeds":
			for sid in Data.seeds_for_season(season):
				out.append({"id": sid, "price": Data.buy_price(sid), "locked": false, "req": ""})
			continue
		if s.id == "@saplings":
			for tid in Data.trees:
				var t: Dictionary = Data.trees[tid]
				var treq: String = t.get("requires", "")
				out.append({"id": tid + "_sapling", "price": int(t.sapling), "locked": not meets(treq, ctx), "req": treq})
			continue
		var price: int = int(s.get("price", Data.buy_price(s.id)))
		out.append({"id": s.id, "price": price, "locked": not meets(req, ctx), "req": req})
	return out

static func traveler_here(day_index: int) -> bool:
	var days: Array = Data.shops.traveler.days
	return Calendar.weekday(day_index) in days

static func recipe(kind: String, id: String) -> Dictionary:
	return Data.recipes.get(kind, {}).get(id, {})

static func known_recipes(kind: String, ctx: Dictionary) -> Array:
	var out: Array = []
	for id in Data.recipes.get(kind, {}):
		var r: Dictionary = Data.recipes[kind][id]
		if meets(r.unlock, ctx) or id in ctx.get("recipes", []):
			out.append(id)
	return out

## Counts across several inventories (backpack + nearby chests).
static func count_in(invs: Array, id: String) -> int:
	var n := 0
	for inv in invs:
		n += inv.count(id)
	return n

static func can_make(kind: String, id: String, invs: Array) -> bool:
	var r := recipe(kind, id)
	if r.is_empty():
		return false
	for k in r.in:
		if count_in(invs, k) < int(r.in[k]):
			return false
	return true

static func consume(invs: Array, needs: Dictionary) -> void:
	for k in needs:
		var left: int = int(needs[k])
		for inv in invs:
			if left <= 0:
				break
			var have: int = inv.count(k)
			var take := mini(have, left)
			if take > 0:
				inv.remove(k, take)
				left -= take

## Crafts into invs[0]. Returns true on success.
static func make(kind: String, id: String, invs: Array) -> bool:
	if not can_make(kind, id, invs):
		return false
	var first: Inventory = invs[0]
	if not first.can_add(id, 1):
		return false
	consume(invs, recipe(kind, id).in)
	first.add(id, int(recipe(kind, id).get("n", 1)))
	return true

static func building_ok(id: String, ctx: Dictionary, money: int, invs: Array) -> Dictionary:
	var b: Dictionary = Data.buildings.get(id, {})
	if b.is_empty():
		return {"ok": false, "reason": TranslationServer.translate("Unknown.")}
	if id in ctx.get("buildings", []):
		return {"ok": false, "reason": TranslationServer.translate("Already built.")}
	if not meets(b.requires, ctx):
		return {"ok": false, "reason": req_text(b.requires)}
	if money < int(b.price):
		return {"ok": false, "reason": TranslationServer.translate("Not enough money.")}
	for k in b.materials:
		if count_in(invs, k) < int(b.materials[k]):
			return {"ok": false, "reason": TranslationServer.translate("Need %d %s.") % [int(b.materials[k]), Data.item_name(k)]}
	return {"ok": true, "reason": ""}

static func upgrade_spec(next_level: int) -> Dictionary:
	for u in Data.progression.tool_upgrades:
		if int(u.level) == next_level:
			return u
	return {}

static func backpack_spec(id: String) -> Dictionary:
	for b in Data.progression.backpacks:
		if b.id == id:
			return b
	return {}

## Old saves stored a pack level; packs are items now.
static func backpack_for_level(level: int) -> String:
	return ["pack_rucksack", "pack_farmer", "pack_explorer", "pack_warden"][clampi(level, 0, 3)]

static func farm_rank(score: int) -> String:
	var name := "Sprout"
	for r in Data.progression.farm_ranks:
		if score >= int(r.score):
			name = r.name
	return name
