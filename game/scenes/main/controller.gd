class_name Controller
extends Node
## Turns player input (use / interact on a tile) into world actions and UI.

var main: Node
var ui: UIRoot
var world: World
var player: Player
var busy := false
var adventure: AdventureFlow
var quests: QuestFlow

func setup(m: Node, u: UIRoot, w: World, p: Player) -> void:
	main = m
	ui = u
	world = w
	player = p
	adventure = AdventureFlow.new(self)
	add_child(adventure)
	quests = QuestFlow.new(self)
	add_child(quests)
	player.use_pressed.connect(_on_use)
	player.interact_pressed.connect(_on_interact)
	Coop.act_result.connect(_feedback)

func _pdata() -> PlayerData:
	return GameState.local_player()

func _feedback(r: Dictionary, t: Vector2i) -> void:
	if r.get("ok", false):
		if r.get("sfx", "") != "":
			Audio.sfx(r.sfx)
			Juice.burst(world, GameState.tile_center(t) + Vector2(0, -4), r.sfx)
	elif r.get("reason", "") != "":
		EventBus.toast.emit(r.reason, "")
		Audio.sfx("error")

func _act(action: String, args: Array) -> Dictionary:
	var r := Coop.act(action, args)
	if not r.get("pending", false):
		_feedback(r, args[1] if args.size() > 1 and args[1] is Vector2i else player.target)
	return r

# --- Use (left click / C) -----------------------------------------------------------------

func _on_use(t: Vector2i) -> void:
	if busy or ui.is_open():
		return
	var p := _pdata()
	var e := p.selected_entry()
	player.face_tile(t)
	if e.is_empty():
		_on_interact(t)
		return
	var it: Dictionary = Data.get_item(e.id)
	var cat: String = it.get("cat", "")
	if cat == "tool":
		if player.doll.is_swinging():
			return
		player.doll.swing()
		Audio.sfx("swing", 0.1)
		player.locked = true
		await get_tree().create_timer(0.16).timeout
		player.locked = false
		_act("use_tool", [world.map_id, t, e.id])
		return
	var g := world.grid
	var o: Dictionary = g.object_at(t) if g else {}
	if o.get("kind", "") == "machine" and not Machines.is_busy(o):
		_act("load_machine", [world.map_id, t, e.uid])
		return
	if cat in ["seed", "sapling"] or it.has("fert") or it.has("place"):
		_act("use_item", [world.map_id, t, e.uid])
		return
	var npc := world.npc_at(t)
	if npc:
		_gift(npc, e)
		return
	if Data.is_edible(e.id):
		_eat(e)
		return
	_on_interact(t)

func _eat(e: Dictionary) -> void:
	var it: Dictionary = Data.get_item(e.id)
	var c: int = await ui.ask(tr("Eat %s? (+%d energy)") % [Data.item_name(e.id, int(e.q)), int(it.get("energy", 0))], ["Eat", "No"])
	if c == 0:
		_act("eat", [e.uid])

# --- Interact (right click / X) --------------------------------------------------------------

func _on_interact(t: Vector2i) -> void:
	if busy or ui.is_open():
		return
	player.face_tile(t)
	var npc := world.npc_at(t)
	if npc:
		await _talk(npc)
		await _offer_battle(npc.vid)
		return
	var wc := world.creature_at(t)
	if wc and wc.pet and wc.creature:
		_pet(wc)
		return
	var g := world.grid
	if g:
		if g.crop_ready(t):
			_act("harvest_at", [world.map_id, t])
			return
		if not g.crop_at(t).is_empty():
			EventBus.toast.emit(crop_info(g, t), "")
			return
		var o := g.object_at(t)
		if not o.is_empty():
			if await _interact_object(t, o):
				return
	var io := world.interactable_at(t)
	if not io.is_empty():
		busy = true
		await _interact_static(io)
		busy = false

## "Parsnip: ripe in 12 min · 2 harvests left · watered"
static func crop_info(g: FarmGrid, t: Vector2i) -> String:
	var c := g.crop_at(t)
	var season := GameState.season()
	var mult := Modifiers.mult(GameState.local_player(), "crop_growth")
	var bits: Array = []
	bits.append(TranslationServer.translate("ripe in %s") % TimeService.duration_text(g.crop_eta(t, season, mult)))
	var left := int(c.get("harvests", -1))
	bits.append(TranslationServer.translate("harvests forever") if left < 0 else TranslationServer.translate("%d harvests left") % left)
	bits.append(TranslationServer.translate("watered") if g.is_watered(t) else TranslationServer.translate("dry: grows slower"))
	if not g.greenhouse and CropGrowth.season_distance(c.id, season) > 0:
		bits.append(TranslationServer.translate("off season"))
	return "%s: %s" % [Data.item_name(c.id), " · ".join(bits)]

func _interact_object(t: Vector2i, o: Dictionary) -> bool:
	match o.get("kind", ""):
		"forage":
			_act("harvest_at", [world.map_id, t])
			return true
		"tree":
			if int(o.get("fruit", 0)) > 0:
				_act("harvest_at", [world.map_id, t])
			else:
				var grown := FarmGrid.tree_growth(o, TimeService.now())
				var left_s := (1.0 - grown) * float(Data.trees.get(o.tree, {}).get("days", 10)) * CropGrowth.TREE_DAY_SECONDS
				EventBus.toast.emit(tr("This %s matures in %s.") % [Data.item_name(o.id), TimeService.duration_text(left_s)] if grown < 1.0 else "No fruit yet. Fruit trees bear fruit in their season.", "")
			return true
		"machine":
			if Machines.is_ready(o, TimeService.now()):
				_act("harvest_at", [world.map_id, t])
			elif Machines.is_busy(o):
				var left := Machines.remaining(o, TimeService.now())
				EventBus.toast.emit(tr("%s: %s ready in %s.") % [Data.item_name(o.id), Data.item_name(o.output.get("id", "")), TimeService.duration_text(left)], "")
			else:
				var e := _pdata().selected_entry()
				if not e.is_empty():
					_act("load_machine", [world.map_id, t, e.uid])
				else:
					EventBus.toast.emit(tr("Hold an item and use it on the %s to load it.") % Data.item_name(o.id), "")
			return true
		"chest":
			_open_chest(t, o)
			return true
	return false

func _open_chest(t: Vector2i, o: Dictionary) -> void:
	var spec := Data.container_spec(o.id)
	var inv := Inventory.new(int(spec.get("w", 8)), int(spec.get("h", 6)))
	inv.from_dict(o.get("inv", {}))
	var panel := InventoryPanel.new(_pdata(), inv, Data.item_name(o.id), "chest")
	var mid := world.map_id
	panel.on_close = func():
		o.inv = inv.to_dict()
		EventBus.tile_changed.emit(mid, t)
	Audio.sfx("chest")
	ui.open(panel)

func _interact_static(io: Dictionary) -> void:
	var p := _pdata()
	match io.get("type", ""):
		"shrine":
			await adventure.shrine(io)
		"cave":
			await adventure.cave(io)
		"ladder":
			await adventure.ladder_down()
		"ladder_up":
			await adventure.ladder_up()
		"treasure":
			await adventure.treasure(Vector2i(int(io.x), int(io.y)), io)
		"shipping_bin":
			ui.open(InventoryPanel.new(p, GameState.shipping_bin, "Shipping Bin", "chest"))
		"farm_chest":
			Audio.sfx("chest")
			ui.open(InventoryPanel.new(p, GameState.farm_chest, "Farm Chest", "chest"))
		"sign":
			await ui.say([io.get("text", "...")])
		"board":
			await _board()
		"wayshrine":
			await adventure.wayshrine()
		"fountain":
			if int(p.stats.get("wish_day", -1)) != GameState.day() and GameState.money() >= 10:
				var c: int = await ui.ask("Toss a coin into the fountain? (10g)", ["Make a wish", "Not today"])
				if c == 0 and GameState.spend(10):
					p.stats["wish_day"] = GameState.day()
					GameState.world.luck = float(GameState.world.get("luck", 0.0)) + 0.01
					Audio.sfx("coin")
					await ui.say(["The coin sparkles as it sinks. You feel a little luckier today."])
			else:
				await ui.say(["The fountain burbles happily."])
		"show_ring":
			await adventure.show_ring()
		"stairs":
			if GameState.is_open_requirement(io.get("requires", "")):
				EventBus.map_change_requested.emit(io.to, Vector2i(int(io.tx), int(io.ty)))
			else:
				await ui.say([tr("It's blocked. (%s)") % Economy.req_text(io.get("requires", ""))])
		"lot":
			await ui.say([tr("An empty lot for the %s. Robin at the Carpenter's can build it.") % io.get("label", io.id).to_lower()])
		"building":
			await _building(io)

func _building(io: Dictionary) -> void:
	var action: String = io.get("action", "")
	if action.begins_with("shop:"):
		var sid := action.substr(5)
		var shop: Dictionary = Data.shops.get(sid, {})
		var hours: Array = shop.get("open", [0, 2400])
		var m := GameState.minute()
		var open_m := Calendar.hhmm(int(hours[0]))
		var close_m := Calendar.hhmm(int(hours[1]))
		if m < open_m or m >= close_m:
			await ui.say([tr("%s is closed. Open %s - %s.") % [shop.get("name", sid), Calendar.time_string(open_m, Settings.twelve_hour), Calendar.time_string(close_m, Settings.twelve_hour)]])
			return
		Audio.sfx("door")
		ui.open(ShopPanel.new(sid))
		return
	match action:
		"house":
			var opts: Array = ["Sleep", "Cook", "Not yet"] if GameState.has_building("kitchen") else ["Sleep", "Not yet"]
			var c: int = await ui.ask("Welcome home. What would you like to do?", opts)
			if opts[c] == "Sleep":
				main.sleep()
			elif opts[c] == "Cook":
				Audio.sfx("open")
				ui.open(CraftPanel.new(_pdata(), "cooking"))
		"center":
			_pdata().heal_party()
			EventBus.party_changed.emit()
			Audio.sfx("heal")
			await ui.say(["Your Wildlings are rested and fully healed!"], "Wildling Center")
		"museum":
			await ui.say([tr("Wildlings recorded: %d / %d.") % [Progression.owned_count(GameState.world.dex), Data.species.size()], "The more you befriend, the more the valley reveals."], "Museum")
		"greenhouse":
			if GameState.map_info("greenhouse").is_empty():
				await ui.say(["The greenhouse door is stuck."])
			else:
				var sp: Array = Data.get_map("greenhouse").get("spawn", [7, 10])
				EventBus.map_change_requested.emit("greenhouse", Vector2i(int(sp[0]), int(sp[1])))
		"den":
			Audio.sfx("door")
			ui.open(PartyPanel.new(_pdata(), "farm"))
		"hatchery":
			Audio.sfx("door")
			ui.open(HatcheryPanel.new(_pdata()))
		"spa":
			await ui.say(["The Wildling Spa. Tired workers rest twice as fast here."])
		"ruined":
			await ui.say([tr("The %s is in ruins. Maybe the village could help restore it...") % io.get("label", "building").to_lower()])
		_:
			await ui.say(["It's locked."])

func _board() -> void:
	Audio.sfx("open")
	ui.open(JournalPanel.new(_pdata(), "board"))

# --- Wildlings ------------------------------------------------------------------------

func _pet(wc: WildCreature) -> void:
	var c := wc.creature
	var key := "pet:" + c.uid
	var flags: Dictionary = GameState.world.flags
	if int(flags.get(key, -1)) == GameState.day():
		wc.emote("♥")
		EventBus.toast.emit(tr("%s is enjoying the farm.") % c.display_name(), "")
		return
	flags[key] = GameState.day()
	c.change_happiness(6)
	c.grooming = mini(100, c.grooming + 4)
	wc.emote("♥", 1.5)
	Audio.sfx("heart")
	var job := tr("resting") if c.job == "" else tr("working as a %s") % tr(str(Data.job_info(c.job).get("job_name", "worker"))).to_lower()
	EventBus.toast.emit(tr("You pet %s. It's %s.") % [c.display_name(), job], "")

func _offer_battle(vid: String) -> void:
	var trd: Dictionary = Data.villagers.get(vid, {}).get("trainer", {})
	if trd.has("warden"):
		busy = true
		await adventure.warden_battle(vid)
		busy = false
		return
	if trd.is_empty():
		return
	var p := _pdata()
	var key := "battled:" + vid
	if int(p.stats.get(key, -1)) == GameState.day() or not p.has_usable_party():
		return
	var name := Data.villager_name(vid)
	busy = true
	var c: int = await ui.ask("Up for a Wildling battle?", ["Let's battle!", "Not now"], name, _portrait(vid))
	busy = false
	if c != 0:
		return
	p.stats[key] = GameState.day()
	var lead := p.lead()
	var info := Trainers.team_for(vid, GameState.world.shrines.size(), lead.level if lead else 5, GameState.rng)
	EventBus.battle_requested.emit({
		"kind": info.kind, "vid": vid, "team": info.team, "foe_name": name, "reward": info.reward,
		"items": info.items, "ai": info.ai,
		"lose_lines": [tr("%s: Wow, you're good! Rematch tomorrow?") % name],
	})
	var res: Dictionary = await EventBus.battle_finished
	if res.get("result", "") == "win":
		Relationships.add_points(vid, p.relationship(vid), 30)

# --- Villagers ------------------------------------------------------------------------

func _portrait(vid: String) -> Texture2D:
	return Art.portrait(vid)

func _talk(npc: Npc) -> void:
	busy = true
	player.locked = true
	var vid := npc.vid
	npc.face(player.position - npc.position)
	var p := _pdata()
	var st := p.relationship(vid)
	var ev := Relationships.pending_event(vid, st)
	var name := Data.villager_name(vid)
	if await adventure.story_talk(vid):
		pass
	elif await quests.talk(vid):
		pass
	elif ev != "":
		var lines: Array = Data.villagers[vid].events[ev].get("lines", [])
		await ui.say(lines, name, _portrait(vid))
		st.events.append(ev)
		var rw: Dictionary = Data.villagers[vid].get("event_rewards", {}).get(ev, {})
		if not rw.is_empty():
			GameState.grant(rw, p)
		Relationships.add_points(vid, st, 60)
		Audio.sfx("heart")
	else:
		var before := Relationships.hearts(st)
		var line := Relationships.talk(vid, st, GameState.season(), GameState.rng)
		await ui.say([tr(line).replace("{name}", p.name).replace("{farm}", GameState.world.farm_name)], name, _portrait(vid))
		if Relationships.hearts(st) > before:
			npc.show_heart_hint("+♥")
			Audio.sfx("heart")
	EventBus.inventory_changed.emit()
	player.locked = false
	busy = false

func _gift(npc: Npc, e: Dictionary) -> void:
	var it: Dictionary = Data.get_item(e.id)
	if it.get("cat", "") in ["tool", "key"]:
		await _talk(npc)
		return
	var vid := npc.vid
	busy = true
	var c: int = await ui.ask(tr("Give %s to %s?") % [Data.item_name(e.id, int(e.q)), Data.villager_name(vid)], ["Give", "Talk instead", "Cancel"])
	busy = false
	if c == 1:
		await _talk(npc)
		return
	if c != 0:
		return
	var p := _pdata()
	var st := p.relationship(vid)
	var cal_day := Calendar.day_of_season(GameState.day())
	var r := Relationships.give_gift(vid, st, e.id, int(e.q), Relationships.is_birthday(vid, GameState.season(), cal_day))
	if r.ok:
		p.inventory.take(e.uid, 1)
		EventBus.inventory_changed.emit()
		p.stat_add("gifts")
		npc.show_heart_hint({"love": "♥♥", "like": "♥", "neutral": "", "dislike": "..."}[r.taste])
		Audio.sfx("gift" if r.taste != "dislike" else "error")
	busy = true
	await ui.say([r.line], Data.villager_name(vid), _portrait(vid))
	busy = false
