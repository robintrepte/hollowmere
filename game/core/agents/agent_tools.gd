class_name AgentTools
extends RefCounted
## What an AI agent may see and do. Every world change goes through Coop.act / GameState,
## so it is the same validation a human player gets. Scopes: observe, act, chat, economy.

const MAX_AGENTS := 3
const SCOPES := ["observe", "act", "chat", "economy"]
const SAFE_ACT := ["use_tool", "use_item", "harvest_at", "load_machine", "ship", "eat", "pick_up_object",
	"craft", "construct", "set_job_act", "move_creature_act", "set_pair_act", "clear_pair_act", "incubate",
	"fish_cast_act", "fish_result_act", "equip_tackle_act", "deep_enter_act", "enchant_act", "anvil_act",
	"grindstone_act", "casino_wheel_act", "roulette_act", "blackjack_act", "slots_act", "poker_act", "race_act",
	"wear_hat_act", "hotel_act", "jukebox_act", "claim_quest_act", "invest_skill_act", "story_seen_act"]
const ECONOMY_ACT := ["buy", "sell", "casino_exchange_act", "upgrade_tool", "buy_backpack", "equip_backpack",
	"respec_skills_act"]

static func has_scope(scopes: Array, need: String) -> bool:
	return need in scopes

## Runs one tool. `ctx` = {pid, scopes, main}. Returns {ok, result|error}.
static func run(tool: String, args: Dictionary, ctx: Dictionary) -> Dictionary:
	var scopes: Array = ctx.get("scopes", SCOPES)
	if tool in ["chat_say"] and not has_scope(scopes, "chat"):
		return err("chat scope required")
	if tool in ["buy", "sell", "go_shopping"] and not has_scope(scopes, "economy"):
		return err("economy scope required")
	if tool.begins_with("casino_") and tool != "casino_wheel_act" and not has_scope(scopes, "economy"):
		return err("economy scope required")
	if not tool.begins_with("get_") and tool not in ["look_around", "read_chat", "wait_for_events", "narrate"] and not has_scope(scopes, "act"):
		return err("act scope required")
	if tool.begins_with("get_") or tool in ["look_around", "read_chat"]:
		if not has_scope(scopes, "observe"):
			return err("observe scope required")
	return dispatch(tool, args, ctx)

static func err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}

static func ok(result: Variant = {}) -> Dictionary:
	return {"ok": true, "result": result}

static func dispatch(tool: String, args: Dictionary, ctx: Dictionary) -> Dictionary:
	var pid := str(ctx.get("pid", Net.local_id()))
	var p := GameState.player(pid)
	if p == null and tool != "get_status":
		return err("no player")
	match tool:
		"get_status":
			return ok(status(pid))
		"look_around":
			return ok(look_around(pid, int(args.get("radius", 6))))
		"get_inventory":
			return ok(inventory_view(p))
		"get_party":
			return ok(party_view(p))
		"get_farm_overview":
			return ok(farm_overview())
		"get_quests":
			return ok(quest_view(p))
		"get_map":
			return ok({"id": p.map_id, "name": str(GameState.map_info(p.map_id).get("name", p.map_id))})
		"get_shop":
			return ok(shop_view(str(args.get("id", ""))))
		"get_battle_state":
			return ok(battle_view(ctx))
		"get_dialogue":
			return ok(dialogue_view(ctx))
		"read_chat":
			return ok(Coop.chat_log.duplicate())
		"walk_to":
			return {"ok": true, "pending": "walk", "args": args}
		"interact":
			return {"ok": true, "pending": "interact", "args": args}
		"use_tool":
			return {"ok": true, "pending": "use_tool", "args": args}
		"plant":
			return {"ok": true, "pending": "plant", "args": args}
		"water_area":
			return {"ok": true, "pending": "water_area", "args": args}
		"harvest_area":
			return {"ok": true, "pending": "harvest_area", "args": args}
		"ship":
			return call_act("ship", [], ctx)
		"buy":
			return call_act("buy", [str(args.get("shop", "")), str(args.get("id", "")), int(args.get("n", 1))], ctx)
		"sell":
			return call_act("sell", [str(args.get("uid", "")), int(args.get("n", 1))], ctx)
		"craft":
			return call_act("craft", [str(args.get("id", "")), int(args.get("n", 1))], ctx)
		"cook":
			return call_act("craft", [str(args.get("id", "")), 1], ctx)
		"equip":
			return call_act("equip_backpack", [str(args.get("id", ""))], ctx)
		"set_job":
			return call_act("set_job_act", [str(args.get("uid", "")), str(args.get("job", ""))], ctx)
		"move_creature":
			return call_act("move_creature_act", [str(args.get("uid", "")), str(args.get("where", "den"))], ctx)
		"chat_say":
			Coop.send_chat(str(args.get("text", "")))
			return ok({"said": true})
		"emote":
			Coop.send_emote(str(args.get("id", "wave")))
			return ok({"emote": args.get("id", "wave")})
		"sleep":
			return {"ok": true, "pending": "sleep", "args": args}
		"narrate":
			EventBus.toast.emit(str(args.get("text", "")), "chat")
			return ok({"narrated": true})
		"farm_routine":
			return {"ok": true, "pending": "farm_routine", "args": args}
		"go_shopping":
			return shopping(args, ctx)
		"deposit_all":
			return {"ok": true, "pending": "deposit_all", "args": args}
		"dialogue_choose":
			return {"ok": true, "pending": "dialogue_choose", "args": args}
		"battle_move", "battle_switch", "battle_item", "battle_flee":
			return {"ok": true, "pending": tool, "args": args}
		"fish":
			return call_act("fish_cast_act", [str(args.get("spot", ""))], ctx)
		"mine_block":
			return {"ok": true, "pending": "mine_block", "args": args}
		"place_block":
			return {"ok": true, "pending": "place_block", "args": args}
		"enchant":
			return call_act("enchant_act", [str(args.get("tool", "")), int(args.get("offer", 0))], ctx)
		"casino_bet":
			return casino(args, ctx)
	if tool.ends_with("_act") and tool in Coop.ACTIONS:
		var a: Array = args.get("args", [])
		return call_act(tool, a, ctx)
	return err("unknown tool: " + tool)

static func call_act(action: String, args: Array, ctx: Dictionary) -> Dictionary:
	if action == "":
		return err("missing action")
	if action not in Coop.ACTIONS:
		return err("unknown action")
	if action in ECONOMY_ACT and not has_scope(ctx.get("scopes", []), "economy"):
		return err("economy scope required")
	if action == "sell" and valuable_sale(args) and not has_scope(ctx.get("scopes", []), "economy"):
		return err("selling valuable items needs the economy scope")
	var pid := str(ctx.get("pid", Net.local_id()))
	if pid == Net.local_id() or pid == "local":
		return Coop.act(action, args)
	if not Net.is_authority():
		return err("only the host can steer a partner")
	return GameState.callv(action, [pid] + args)

static func valuable_sale(args: Array) -> bool:
	if args.is_empty():
		return false
	var p := GameState.local_player()
	if p == null:
		return false
	var e: Dictionary = p.inventory.entry(str(args[0])) if p.inventory.has_method("entry") else {}
	var id := str(e.get("id", args[0]))
	return int(Data.get_item(id).get("sell", 0)) >= 200

static func status(pid: String) -> Dictionary:
	var p := GameState.player(pid)
	if p == null:
		return {"started": GameState.started}
	return {
		"name": p.name, "map": p.map_id, "tile": {"x": GameState.to_tile(p.pos).x, "y": GameState.to_tile(p.pos).y},
		"energy": int(p.energy), "max_energy": int(p.max_energy), "money": GameState.money(),
		"chips": int(p.chips), "season": GameState.season(), "weather": str(GameState.world.get("weather", "")),
		"minute": int(GameState.world.get("minute", 0)), "level": p.level, "day": GameState.day(),
	}

static func look_around(pid: String, radius: int) -> Dictionary:
	var p := GameState.player(pid)
	var info := GameState.map_info(p.map_id)
	var t := GameState.to_tile(p.pos)
	var tiles: Array = []
	var objs: Array = []
	var npcs: Array = []
	var wilds: Array = []
	var folk: Array = []
	var g := GameState.grids.get(p.map_id) as FarmGrid
	if g:
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var q := t + Vector2i(dx, dy)
				if not g.in_bounds(q):
					continue
				var ground := g.get_ground(q)
				var deco := g.get_deco(q)
				tiles.append({"x": q.x, "y": q.y, "ground": ground, "deco": deco, "blocked": Tiles.blocks(ground, deco)})
				var o := g.object_at(q)
				if not o.is_empty():
					var row := {"x": q.x, "y": q.y, "kind": o.get("kind", "")}
					if o.has("id"):
						row["id"] = o.id
					objs.append(row)
				if g.crop_at(q):
					var crop: Dictionary = g.crop_at(q)
					if not crop.is_empty():
						var row := {"x": q.x, "y": q.y, "kind": "crop", "id": crop.get("id", ""), "progress": crop.get("progress", 0.0)}
						if bool(crop.get("ruined", false)):
							row["ruined"] = true
						objs.append(row)
	for v in info.get("villagers", []):
		npcs.append({"id": v, "name": str(Data.villagers.get(v, {}).get("name", v))})
	for other in GameState.players.values():
		if other.id != pid and other.map_id == p.map_id:
			folk.append({"pid": other.id, "name": other.name, "tile": {"x": GameState.to_tile(other.pos).x, "y": GameState.to_tile(other.pos).y}})
	return {"map": p.map_id, "you": {"x": t.x, "y": t.y}, "tiles": tiles, "objects": objs, "npcs": npcs, "players": folk, "wildlings": wilds, "ascii": ascii_map(g, t, radius)}

static func ascii_map(g: FarmGrid, center: Vector2i, radius: int) -> String:
	if g == null:
		return ""
	var lines: Array = []
	for dy in range(-radius, radius + 1):
		var row := ""
		for dx in range(-radius, radius + 1):
			var q := center + Vector2i(dx, dy)
			if q == center:
				row += "@"
			elif not g.in_bounds(q) or Tiles.blocks(g.get_ground(q), g.get_deco(q)):
				row += "#"
			elif g.crop_ruined(q):
				row += "x"
			elif g.crop_at(q) and not g.crop_at(q).is_empty():
				row += "*" if g.crop_ready(q) else ","
			elif g.get_ground(q) in Tiles.WATER_TILES:
				row += "~"
			else:
				row += "."
		lines.append(row)
	return "\n".join(lines)

static func inventory_view(p: PlayerData) -> Dictionary:
	var items: Array = []
	for e in p.inventory.entries:
		items.append({"uid": e.get("uid", ""), "id": e.get("id", ""), "n": e.get("n", 1), "q": e.get("q", 0)})
	return {"w": p.inventory.w, "h": p.inventory.h, "items": items, "backpack": p.backpack}

static func party_view(p: PlayerData) -> Array:
	var out: Array = []
	for c in p.party:
		out.append({"uid": c.uid, "name": c.display_name(), "species": c.species_id, "level": c.level, "hp": c.hp, "energy": c.energy, "job": c.job})
	return out

static func farm_overview() -> Dictionary:
	var jobs: Array = []
	for c in GameState.ranch:
		jobs.append({"uid": c.uid, "name": c.display_name(), "job": c.job, "energy": int(c.energy)})
	var ripe := 0
	var planted := 0
	for map_id in GameState.grids:
		var g := GameState.grids[map_id] as FarmGrid
		for t in g.planted_tiles():
			planted += 1
			if g.crop_ready(t):
				ripe += 1
	return {"workers": jobs, "planted": planted, "ripe": ripe, "chest": GameState.farm_chest.entries.size() if GameState.farm_chest else 0}

static func quest_view(p: PlayerData) -> Array:
	var out: Array = []
	var st := Quests.state(p)
	for qid in st.active:
		out.append({"id": qid, "title": Quests.title(p, qid), "step": Quests.step_text(p, qid)})
	return out

static func shop_view(id: String) -> Dictionary:
	if id == "" or not Data.shops.has(id):
		return {"error": "unknown shop", "shops": Data.shops.keys()}
	return {"id": id, "stock": Data.shops[id].get("stock", [])}

static func battle_view(ctx: Dictionary) -> Dictionary:
	var main: Node = ctx.get("main")
	if main == null or main.get("battle") == null:
		return {"in_battle": false}
	var b: BattleScreen = main.battle
	if b.engine == null:
		return {"in_battle": true}
	var me := b.engine.active(0)
	var foe := b.engine.active(1)
	return {"in_battle": true, "me": me.display_name() if me else "", "foe": foe.display_name() if foe else "", "moves": me.moves if me else []}

static func dialogue_view(ctx: Dictionary) -> Dictionary:
	var main: Node = ctx.get("main")
	if main == null or main.ui == null or not main.ui.dialogue.visible:
		return {"open": false}
	return {"open": true, "text": str(main.ui.dialogue.get("text") if main.ui.dialogue.get("text") else "")}

static func shopping(args: Dictionary, ctx: Dictionary) -> Dictionary:
	var shop := str(args.get("shop", "general_store"))
	var got: Array = []
	for item in args.get("list", []):
		var r := call_act("buy", [shop, str(item.get("id", item)), int(item.get("n", 1))], ctx)
		got.append(r)
	return ok(got)

static func casino(args: Dictionary, ctx: Dictionary) -> Dictionary:
	var game := str(args.get("game", "roulette"))
	var table := {"roulette": "roulette_act", "blackjack": "blackjack_act", "slots": "slots_act", "poker": "poker_act", "race": "race_act"}
	var action := str(table.get(game, ""))
	if action == "":
		return err("unknown game")
	return call_act(action, [args.get("bet", {})], ctx)

static func handbook() -> String:
	var bits: Array = [
		"# Hollowmere handbook for agents",
		"You play a cozy farm life sim. Crops grow in real time. Wildlings work farm jobs and rest on their own. There is no rest job.",
		"Gold is the currency. Casino chips only work in Lumière and have no real value.",
		"Never delete a save. Ask before selling items worth 200g or more.",
		"Types: " + ", ".join(Data.types.keys()),
		"Keep the browser tab visible: background tabs pause the simulation.",
	]
	return "\n".join(bits)
