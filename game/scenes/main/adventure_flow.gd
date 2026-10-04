class_name AdventureFlow
extends Node
## Player-facing flows for shrines, Wardens, mines, treasure, wayshrine travel,
## festivals at the Show Ring and Elder Barley's story. Owned by the Controller.

var ctl: Controller

func _init(c: Controller) -> void:
	ctl = c

func _say(lines: Array, vid: String = "") -> void:
	if vid != "":
		await ctl.ui.say(lines, Data.villager_name(vid), Art.portrait(vid))
	else:
		await ctl.ui.say(lines)

func _ask(prompt: String, opts: Array, vid: String = "") -> int:
	if vid != "":
		return await ctl.ui.ask(prompt, opts, Data.villager_name(vid), Art.portrait(vid))
	return await ctl.ui.ask(prompt, opts)

## Starts a battle and waits for it. Returns {} if it couldn't start.
func _battle(setup: Dictionary) -> Dictionary:
	if not ctl._pdata().has_usable_party():
		EventBus.toast.emit("Your Wildlings are too tired to battle. Rest at home or the Wildling Center.", "")
		return {}
	EventBus.battle_requested.emit(setup)
	return await EventBus.battle_finished

static func loot_text(loot: Dictionary) -> String:
	var bits: Array = []
	for k in loot:
		if k == "money":
			bits.append(CoinLabel.text(int(loot[k])))
		else:
			bits.append(TranslationServer.translate("%d %s") % [int(loot[k]), Data.item_name(k)])
	return ", ".join(bits)

# --- Story ------------------------------------------------------------------------------

## Barley hands out the next chapter. Returns true if he did (instead of small talk).
func story_talk(vid: String) -> bool:
	if vid != Adventure.QUEST_GIVER:
		return false
	var ch := Adventure.chapter(GameState.world)
	if ch.is_empty() or GameState.world.flags.get("story_seen:" + str(ch.id), false):
		return false
	await _say(ch.get("lines", []), vid)
	GameState.world.flags["story_seen:" + str(ch.id)] = true
	Coop.act("story_seen_act", [str(ch.id)])
	EventBus.toast.emit(TranslationServer.translate("%s: %s") % [ch.title, ch.hint], "book")
	Audio.sfx("sparkle")
	return true

# --- Wardens + shrines ------------------------------------------------------------------

func warden_battle(vid: String) -> void:
	var region := Adventure.region_of_warden(vid)
	if region != "" and Adventure.shrine_state(GameState.world, region) == "restored":
		await rematch(vid)
		return
	if region == "" or Adventure.shrine_state(GameState.world, region) != "dark":
		return
	var p := ctl._pdata()
	var key := "battled:" + vid
	var name := Data.villager_name(vid)
	if int(p.stats.get(key, -1)) == GameState.day():
		await _say(["Rest your Wildlings. I'll be here tomorrow."], vid)
		return
	if not p.has_usable_party():
		return
	var c: int = await _ask("The shrine only answers someone their Wildlings trust. Show me.", ["Battle!", "Not yet"], vid)
	if c != 0:
		return
	p.stats[key] = GameState.day()
	var lead := p.lead()
	var info := Trainers.team_for(vid, GameState.world.shrines.size(), lead.level if lead else 5, GameState.rng)
	var res: Dictionary = await _battle({
		"kind": "warden", "vid": vid, "team": info.team, "foe_name": name, "reward": info.reward,
		"items": info.items, "ai": info.ai, "friendly": true,
		"lose_lines": [TranslationServer.translate("%s: Not yet. Train with your Wildlings and come back tomorrow.") % name],
	})
	if res.get("result", "") != "win":
		return
	await Coop.act_async("warden_won_act", [region])
	GameState.world.flags["warden:" + region] = true
	p.add_friendship(vid, 80)
	await _say(["...You're the real thing.", "Lay your hand on the shrine. It will answer you now."], vid)

## Post-game: once all eight shrines are awake, each Warden takes one rematch a week.
func rematch(vid: String) -> void:
	var p := ctl._pdata()
	var name := Data.villager_name(vid)
	if not Endless.rematch_open(GameState.world) or not GameState.rematch_ready(p.id, vid):
		return
	if int(p.stats.get("battled:" + vid, -1)) == GameState.day() or not p.has_usable_party():
		return
	var tier := Endless.rematch_tier(GameState.world)
	var c: int = await _ask(TranslationServer.translate("The valley is whole again, but I've kept training. Rematch? My team is around level %d now.") % Endless.rematch_level(tier), ["Rematch!", "Not this week"], vid)
	if c != 0:
		return
	p.stats["battled:" + vid] = GameState.day()
	var info := Trainers.rematch_team(vid, tier, GameState.rng)
	var res: Dictionary = await _battle({
		"kind": "warden", "vid": vid, "team": info.team, "foe_name": name, "reward": 0,
		"items": info.items, "ai": 2, "friendly": true,
		"lose_lines": [TranslationServer.translate("%s: Good fight. Come back tomorrow if you want another go.") % name],
	})
	if res.get("result", "") != "win":
		return
	var r: Dictionary = await Coop.act_async("rematch_won_act", [vid])
	if not r.get("ok", false):
		return
	p.add_friendship(vid, 40)
	var lines: Array = ["Still the best in the valley. Same time next week?", TranslationServer.translate("Prize: %s.") % loot_text(r.get("reward", {}))]
	if r.get("tier_up", false):
		lines.append(TranslationServer.translate("Word spreads. Every Warden is training harder: their teams now reach level %d.") % int(r.level))
	Audio.sfx("levelup")
	await _say(lines, vid)

func shrine(o: Dictionary) -> void:
	var region: String = o.get("region", "")
	var guardian := Adventure.guardian_of(region)
	var gname := str(Data.species.get(guardian, {}).get("name", ""))
	if gname == "":
		gname = TranslationServer.translate("the guardian")
	var warden := Adventure.warden_of(region)
	match Adventure.shrine_state(GameState.world, region):
		"dark":
			await _say(["The shrine is cold and dark. Its orb is cracked through.", TranslationServer.translate("%s keeps watch here. Perhaps a battle would prove your bond with your Wildlings.") % Data.villager_name(warden)])
		"ready":
			var c: int = await _ask("The stones hum under your hand. Wake the shrine?", ["Wake it", "Not yet"])
			if c != 0:
				return
			await _say([TranslationServer.translate("Light pours into the cracks... %s, guardian of the shrine, awakens!") % gname])
			var res: Dictionary = await _battle({"kind": "wild", "species": guardian, "level": Adventure.guardian_level(region), "ai": 2, "boss": true, "friendly": true})
			match res.get("result", ""):
				"win":
					await shrine_woken(await Coop.act_async("guardian_result_act", [region, false]))
				"befriend":
					pass
				"":
					pass
				_:
					await _say([TranslationServer.translate("%s sinks back into the stones. Rest up and try again.") % gname])
		"restored":
			var lines: Array = [TranslationServer.translate("The %s Shrine glows warmly.") % Data.region_name(region)]
			if Adventure.guardian_free(GameState.world, region):
				lines.append(TranslationServer.translate("%s lingers nearby. Perhaps it would join you, if you asked kindly with a charm.") % gname)
			if Adventure.legend_here(GameState.world, region, GameState.season()) != "":
				lines.append(TranslationServer.translate("Something ancient is near. The air smells of %s.") % GameState.season())
			await _say(lines)

## Shows the shrine reward text and redraws the shrine. r is guardian_result_act's result.
func shrine_woken(r: Dictionary) -> void:
	if not r.get("ok", false) or not r.has("text"):
		return
	Audio.sfx("levelup")
	EventBus.shake.emit(4.0)
	ctl.world.refresh_all()
	for o in ctl.world.info.get("objects", []):
		if o.type == "shrine":
			Juice.burst(ctl.world, GameState.tile_center(Vector2i(int(o.x), int(o.y))) + Vector2(16, 0), "levelup")
	await _say([str(r.text)])

# --- Mines -----------------------------------------------------------------------------

func cave(o: Dictionary) -> void:
	var region: String = o.get("region", "")
	var mine: Dictionary = Data.regions[region].get("mine", {})
	var floors := Adventure.elevator_floors(GameState.world, region)
	var deep := Adventure.deepest(GameState.world, region)
	var total := Adventure.mine_floors(region)
	var depth_txt := (TranslationServer.translate("Deepest: B%d of %d.") % [deep, total]) if total > 0 else (TranslationServer.translate("Deepest: B%d. It has no bottom.") % deep)
	var opts: Array = []
	for f in floors:
		opts.append(TranslationServer.translate("B%d") % int(f))
	opts.append("Leave")
	var cave_name := str(mine.get("name", ""))
	if cave_name == "":
		cave_name = TranslationServer.translate("A cave")
	var c: int = await _ask(TranslationServer.translate("%s. %s") % [cave_name, depth_txt if deep > 0 else TranslationServer.translate("Nobody has explored it in years.")], opts)
	if c < 0 or c >= floors.size():
		return
	await enter_floor(region, int(floors[c]))

func enter_floor(region: String, n: int) -> void:
	var r: Dictionary = await Coop.act_async("mine_floor_act", [region, n])
	if not r.get("ok", false):
		EventBus.toast.emit(str(r.get("reason", TranslationServer.translate("The way is blocked."))), "")
		return
	if int(GameState.world.mine_depth.get(region, 0)) < n:
		GameState.world.mine_depth[region] = n
	var mid := "mine:%s:%d" % [region, n]
	var sp: Array = GameState.map_info(mid).spawn
	EventBus.map_change_requested.emit(mid, Vector2i(int(sp[0]), int(sp[1])))
	if r.get("new_elevator", false):
		EventBus.toast.emit(TranslationServer.translate("The cave mouth can now take you straight to B%d.") % n, "star")

func ladder_down() -> void:
	var info: Dictionary = ctl.world.info
	await enter_floor(str(info.region), int(info.floor) + 1)

func ladder_up() -> void:
	var info: Dictionary = ctl.world.info
	var region := str(info.region)
	var c: int = await _ask("Climb back out of the cave?", ["Climb out", "Stay"])
	if c != 0:
		return
	var to := Vector2i(1, 17)
	for o in GameState.map_info(region).get("objects", []):
		if o.type == "cave":
			to = Vector2i(int(o.x), int(o.y) + 1)
	EventBus.map_change_requested.emit(region, to)

# --- Deep Mine --------------------------------------------------------------------------

func deep_interact(t: Vector2i) -> void:
	var layer := int(ctl.world.info.get("deep", 0))
	var g: FarmGrid = ctl.world.grid
	match g.get_deco(t):
		Tiles.DECO.ladder:
			await _deep_go(layer + 1, t, "ladder")
		Tiles.DECO.ladder_up:
			if t == Mining.LADDER_UP:
				if layer == 1:
					var c: int = await _ask("Climb back up to Eisenkamm?", ["Climb up", "Stay"])
					if c == 0:
						_to_eisenkamm()
				else:
					await _deep_go(layer - 1, Vector2i(-1, -1), "elevator")
			else:
				await _deep_go(layer - 1, t, "up")
		Tiles.DECO.elevator:
			await deep_lift()
		Tiles.DECO.minecart:
			Audio.sfx("door")
			EventBus.map_change_requested.emit(ctl.world.map_id, Vector2i(Mining.LANDING.x, Mining.LANDING.y + 1))

func _deep_go(layer: int, t: Vector2i, via: String) -> void:
	var r: Dictionary = await Coop.act_async("deep_enter_act", [layer, t.x, t.y, via])
	if not r.get("ok", false):
		if str(r.get("reason", "")) != "":
			EventBus.toast.emit(str(r.reason), "")
		return
	var to: Array = r.get("to", [Mining.LANDING.x, Mining.LANDING.y + 1])
	EventBus.map_change_requested.emit("deep:%d" % layer, Vector2i(int(to[0]), int(to[1])))
	if r.get("new_layer", false):
		EventBus.toast.emit(TranslationServer.translate("New layer: %s. The lift can take you here now.") % TranslationServer.translate(str(Mining.layer_spec(layer).name)), "star")

func _to_eisenkamm() -> void:
	var to := Vector2i(20, 8)
	for o in Data.get_map("eisenkamm").get("objects", []):
		if o.get("type", "") == "building" and o.get("action", "") == "deep_lift":
			to = Vector2i(int(o.x) + int(o.get("w", 2)) / 2, int(o.y) + int(o.get("h", 2)))
	EventBus.map_change_requested.emit("eisenkamm", to)

## The mine lift: Eisenkamm and every layer you've already reached.
func deep_lift() -> void:
	var here := int(ctl.world.info.get("deep", 0))
	var reached := maxi(1, GameState.deep_max())
	var opts: Array = []
	var dest: Array = []
	if here > 0:
		opts.append("Eisenkamm")
		dest.append(0)
	for n in range(1, reached + 1):
		if n != here:
			opts.append(TranslationServer.translate("Layer %d: %s") % [n, TranslationServer.translate(str(Mining.layer_spec(n).name))])
			dest.append(n)
	opts.append("Stay")
	var c: int = await _ask("The lift creaks. Where to?", opts)
	if c < 0 or c >= dest.size():
		return
	Audio.sfx("door")
	if int(dest[c]) == 0:
		_to_eisenkamm()
	else:
		await _deep_go(int(dest[c]), Vector2i(-1, -1), "elevator")

func guild() -> void:
	var p := GameState.local_player()
	var reached := GameState.deep_max()
	var lines: Array = [TranslationServer.translate("The Miners' Guild ledger: %d blocks broken, deepest layer %d of %d.") % [int(p.stats.get("mined", 0)), reached, Mining.layer_count()]]
	if reached < Mining.layer_count():
		var nxt := Mining.layer_spec(reached + 1)
		lines.append(TranslationServer.translate("Next down: %s. You'll want a %s pickaxe for that rock.") % [TranslationServer.translate(str(nxt.name)), TranslationServer.translate(Mining.tier_name(int(nxt.get("min_pick", 0))))])
	elif not GameState.world.flags.get("deep_boss", false):
		lines.append("Something huge stirs in the Magma Depths. The guild would be grateful if it stopped.")
	else:
		lines.append("The mountain sleeps easy, thanks to you. The guild owes you a drink.")
	await _say(lines, "brannoc")

func geologist(_io: Dictionary) -> void:
	var p := GameState.local_player()
	var n := p.inventory.count("geode")
	var opts: Array = []
	if n > 0:
		opts.append(TranslationServer.translate("Crack one (%s)") % CoinLabel.text(25))
		if n > 1:
			opts.append(TranslationServer.translate("Crack all %d (%s)") % [n, CoinLabel.text(25 * n)])
	opts.append("Browse finds")
	opts.append("Leave")
	var c: int = await _ask(TranslationServer.translate("Got geodes? I'll split them for %s apiece. You keep whatever's inside.") % CoinLabel.text(25) if n > 0 else TranslationServer.translate("Bring me geodes from the mine and I'll split them for you."), opts)
	if c < 0 or c >= opts.size():
		return
	if opts[c] == "Browse finds":
		Audio.sfx("door")
		ctl.ui.open(ShopPanel.new("geologist"))
		return
	if opts[c] == "Leave":
		return
	var r: Dictionary = await Coop.act_async("crack_geode_act", [1 if c == 0 else n])
	if not r.get("ok", false):
		EventBus.toast.emit(str(r.get("reason", "")), "")
		return
	Audio.sfx("chest")
	await _say([TranslationServer.translate("Crack! Inside: %s.") % loot_text(r.get("loot", {}))])

func museum() -> void:
	var m: Dictionary = GameState.world.get("mining", {})
	var have: int = m.get("museum", []).size()
	var c: int = await _ask(TranslationServer.translate("Wildlings recorded: %d / %d. Minerals and fossils on display: %d / %d.") % [Progression.owned_count(GameState.world.dex), Data.species.size(), have, Mining.MUSEUM.size()], ["Donate finds", "Leave"])
	if c != 0:
		return
	var r: Dictionary = await Coop.act_async("donate_museum_act", [])
	if not r.get("ok", false):
		await _say([str(r.get("reason", ""))])
		return
	var names: Array = []
	for id in r.get("given", []):
		names.append(Data.item_name(id))
	var lines: Array = [TranslationServer.translate("The curator beams. New on display: %s.") % ", ".join(names)]
	if r.has("milestone"):
		lines.append(TranslationServer.translate("%d pieces in the collection! The curator hands you a thank-you gift.") % int(r.milestone))
	Audio.sfx("levelup")
	await _say(lines)

func treasure(t: Vector2i, o: Dictionary) -> void:
	if GameState.treasure_opened(ctl.world.map_id, t):
		EventBus.toast.emit(TranslationServer.translate("It's empty."), "")
		return
	var r: Dictionary = await Coop.act_async("open_treasure_act", [ctl.world.map_id, t.x, t.y])
	if not r.get("ok", false):
		EventBus.toast.emit(str(r.get("reason", TranslationServer.translate("It won't open."))), "")
		return
	ctl.world.mark_treasure_opened(t)
	if r.get("mimic", false):
		Audio.sfx("encounter")
		await _say(["The chest snaps open... and bites! It's a Mimicrate!"])
		var lv: Array = ctl.world.info.get("levels", [10, 14])
		await _battle({"kind": "wild", "species": "mimicrate", "level": int(lv[1]) + 2, "ai": 1})
		return
	Audio.sfx("chest")
	var grand: bool = o.get("grand", false)
	var found := TranslationServer.translate("You found %s.") % loot_text(r.get("loot", {}))
	if grand:
		found = TranslationServer.translate("At the very bottom of the cave, a great chest! %s") % found
	await _say([found])

# --- Wayshrines -------------------------------------------------------------------------

func wayshrine() -> void:
	var here: String = ctl.world.map_id
	var dests: Array = []
	if here != "town":
		dests.append("town")
	for rid in Data.region_order:
		if rid != here and GameState.region_unlocked(rid):
			dests.append(rid)
	for pid in GameState.PLACE_REQUIRES:
		if pid != here and GameState.place_open(pid):
			dests.append(pid)
	var opts: Array = []
	for d in dests:
		opts.append("Hollowmere Village" if d == "town" else Data.region_name(d))
	opts.append("Stay")
	var c: int = await _ask("The wayshrine hums. Its stones remember every road you've opened.", opts)
	if c < 0 or c >= dests.size():
		return
	Audio.sfx("sparkle")
	EventBus.map_change_requested.emit(dests[c], wayshrine_arrival(dests[c]))

static func wayshrine_arrival(map_id: String) -> Vector2i:
	for o in GameState.map_info(map_id).get("objects", []):
		if o.type == "wayshrine":
			return Vector2i(int(o.x), int(o.y) + 2)
	var sp: Array = GameState.map_info(map_id).get("spawn", [2, 2])
	return Vector2i(int(sp[0]), int(sp[1]))

# --- Festivals --------------------------------------------------------------------------

static func next_festival(day_index: int) -> Array:
	for i in range(1, Calendar.DAYS_PER_SEASON * 4 + 1):
		var id := Calendar.festival_on(day_index + i)
		if id != "":
			return [id, day_index + i]
	return []

func show_ring() -> void:
	var fest := Adventure.festival_today(GameState.day())
	var p := ctl._pdata()
	if fest.is_empty():
		if Endless.show_open(GameState.day()):
			await weekly_show()
			return
		var nx := next_festival(GameState.day())
		var lines: Array = ["The Creature Show ring. Every Saturday the judges hold a show, and the village gathers here for its festivals."]
		if not nx.is_empty():
			var f: Dictionary = Data.progression.festivals[nx[0]]
			lines.append(TranslationServer.translate("Next festival: %s on %s %d.") % [TranslationServer.translate(str(f.name)), Data.season_name(str(f.season)), int(f.day)])
		await _say(lines)
		return
	if Adventure.festival_done(GameState.world, GameState.day(), fest.id, p.id):
		await _say([TranslationServer.translate("Thanks for joining the %s! See you next year.") % TranslationServer.translate(str(fest.name))])
		return
	match str(fest.kind):
		"social", "spawns":
			var c: int = await _ask(TranslationServer.translate("%s! %s Join in?") % [TranslationServer.translate(str(fest.name)), TranslationServer.translate(str(fest.desc))], ["Join", "Later"])
			if c == 0:
				await _festival_result(await Coop.act_async("festival_act", ["social"]), fest)
		"egg_hunt":
			var n := p.inventory.count("festival_egg")
			if n == 0:
				await _say([TranslationServer.translate("%s! %s") % [TranslationServer.translate(str(fest.name)), TranslationServer.translate(str(fest.desc))], TranslationServer.translate("Twelve painted eggs are hidden around the village. Bring back at least %d for the grand prize.") % Adventure.EGG_HUNT_GOAL])
				return
			var c2: int = await _ask(TranslationServer.translate("You found %d eggs. Hand them in?") % n, ["Hand in", "Keep looking"])
			if c2 == 0:
				await _festival_result(await Coop.act_async("festival_act", ["eggs"]), fest)
		"show":
			var lead := p.lead()
			if lead == null:
				return
			var c3: int = await _ask(TranslationServer.translate("%s! Enter %s? The judges score grooming, happiness, genes, level and a little flair.") % [TranslationServer.translate(str(fest.name)), lead.display_name()], ["Enter", "Not yet"])
			if c3 == 0:
				await _festival_result(await Coop.act_async("festival_act", ["show"]), fest)
		"fair":
			var c4: int = await _ask(TranslationServer.translate("%s! Your most valuable goods go on display (you keep them). Variety helps!") % TranslationServer.translate(str(fest.name)), ["Set up", "Not yet"])
			if c4 == 0:
				await _festival_result(await Coop.act_async("festival_act", ["fair"]), fest)
		"tournament":
			await _battle_cup(fest)

const PLACES := ["", "1st", "2nd", "3rd", "4th"]

## The weekly show ladder: each Wildling climbs Novice -> Master by winning at its own rank.
func weekly_show() -> void:
	var p := ctl._pdata()
	if int(GameState.world.flags.get("show:" + p.id, -1)) == GameState.day():
		await _say(["The judges are packing up. Come back next Saturday!"])
		return
	await _say(["It's the weekly Creature Show! The judges score grooming, happiness, genes, level and a little flair.",
		"Win at your Wildling's rank to earn a ribbon and move up: Novice, Bronze, Silver, Gold, then Master."])
	var opts: Array = []
	for c in p.party:
		opts.append(TranslationServer.translate("%s  ·  %s%s") % [c.display_name(), Endless.rank_name(c.show_rank), TranslationServer.translate("  ·  %d ribbons") % c.ribbons if c.ribbons > 0 else ""])
	opts.append("Not today")
	var i: int = await _ask("Who will you show?", opts)
	if i < 0 or i >= p.party.size():
		return
	var r: Dictionary = await Coop.act_async("show_act", [p.party[i].uid])
	if not r.get("ok", false):
		await _say([str(r.get("reason", "Maybe next week."))])
		return
	var parts: Dictionary = r.parts
	var lines: Array = [
		TranslationServer.translate("%s scores %d: grooming %d, happiness %d, genes %d, level %d, flair %d.") % [r.name, int(r.score),
			int(parts.grooming), int(parts.happiness), int(parts.genes), int(parts.level), int(parts.flair)],
		TranslationServer.translate("The other %s entrants scored %s.") % [Endless.rank_name(int(r.rank)), ", ".join(r.rivals.map(func(s): return str(int(s))))],
	]
	if int(r.place) == 1:
		lines.append(TranslationServer.translate("%s wins the %s class and earns a ribbon! (%d total)") % [r.name, Endless.rank_name(int(r.rank)), int(r.ribbons)])
		if r.rank_up:
			lines.append(TranslationServer.translate("%s moves up to the %s class!") % [r.name, Endless.rank_name(int(r.new_rank))])
	else:
		lines.append(TranslationServer.translate("You placed %s. Grooming and a happy Wildling go a long way. Try again next Saturday!") % TranslationServer.translate(PLACES[clampi(int(r.place), 1, 4)]))
	if int(r.prize) > 0:
		lines.append(TranslationServer.translate("Prize: %s.") % CoinLabel.text(int(r.prize)))
	Audio.sfx("levelup" if int(r.place) == 1 else "coin")
	await _say(lines)

func _festival_result(r: Dictionary, fest: Dictionary) -> void:
	if not r.get("ok", false):
		await _say([str(r.get("reason", TranslationServer.translate("Maybe later.")))])
		return
	var lines: Array = []
	match str(fest.kind):
		"social":
			lines.append(TranslationServer.translate("You spend the day laughing with the village. Everyone feels a little closer."))
		"spawns":
			lines.append(TranslationServer.translate("Lanterns are lit, and the night fills with Wildlings. Go and meet them!"))
		"egg_hunt":
			var n := int(r.get("eggs", 0))
			var hunt := TranslationServer.translate("You handed in %d eggs!") % n
			if n >= Adventure.EGG_HUNT_GOAL:
				hunt += TranslationServer.translate(" A perfect hunt!")
			lines.append(hunt)
		"show":
			var rivals: Array = r.get("rivals", [])
			lines.append(TranslationServer.translate("The judges give your Wildling %d points. The others scored %s.") % [int(r.score), ", ".join(rivals.map(func(s): return str(int(s))))])
			lines.append(TranslationServer.translate("You placed %s!") % TranslationServer.translate(PLACES[clampi(int(r.place), 1, 4)]))
		"fair":
			var picks: Array = r.get("picks", [])
			lines.append(TranslationServer.translate("Your display: %s.") % ", ".join(picks.map(func(pk): return Data.item_name(pk.id, int(pk.q)))))
			var rv: Array = r.get("rivals", [])
			lines.append(TranslationServer.translate("Judges' score: %d. %s") % [int(r.score), "  ".join(rv.map(func(x): return TranslationServer.translate("%s %d") % [Data.villager_name(x[0]), int(x[1])]))])
			lines.append(TranslationServer.translate("You placed %s!") % TranslationServer.translate(PLACES[clampi(int(r.place), 1, 4)]))
	var reward: Dictionary = r.get("reward", {})
	if not reward.is_empty():
		lines.append(TranslationServer.translate("Prize: %s.") % loot_text(reward))
	Audio.sfx("levelup")
	await _say(lines)

func _battle_cup(fest: Dictionary) -> void:
	var opp: Array = fest.get("opponents", [])
	var names: Array = opp.map(func(v): return Data.villager_name(v))
	var c: int = await _ask(TranslationServer.translate("%s! Battle %s back to back. Your Wildlings are healed between rounds.") % [TranslationServer.translate(str(fest.name)), ", ".join(names)], ["Enter", "Not yet"])
	if c != 0:
		return
	var p := ctl._pdata()
	var sh: int = GameState.world.shrines.size()
	for i in opp.size():
		p.heal_party()
		var vid: String = opp[i]
		var info := Trainers.team_for(vid, mini(5, sh + 1), Adventure.cup_level(sh, i), GameState.rng)
		if info.is_empty():
			continue
		await _say([TranslationServer.translate("Round %d: %s steps into the ring!") % [i + 1, Data.villager_name(vid)]])
		var res: Dictionary = await _battle({
			"kind": "trainer", "vid": vid, "team": info.team, "foe_name": Data.villager_name(vid), "reward": 0,
			"items": info.items, "ai": 2, "friendly": true,
		})
		if res.get("result", "") != "win":
			p.heal_party()
			EventBus.party_changed.emit()
			await _say([TranslationServer.translate("Knocked out in round %d. The crowd cheers anyway! You can try again today.") % (i + 1)])
			return
	p.heal_party()
	EventBus.party_changed.emit()
	var r: Dictionary = await Coop.act_async("festival_act", ["cup"])
	if r.get("ok", false):
		Audio.sfx("levelup")
		await _say([TranslationServer.translate("You won the %s! The whole village chants your name.") % TranslationServer.translate(str(fest.name)), TranslationServer.translate("Prize: %s.") % loot_text(r.get("reward", {}))])
