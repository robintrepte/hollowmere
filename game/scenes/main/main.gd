extends Node
## Root: title <-> game flow, map transitions, sleeping, camera, menus and remote players.

const WILD_FLEE_STUN := 4.0
const WILD_FLEE_PUSH := 36.0
const WILD_FLEE_GRACE := 2.2

const INTRO := [
	"Dear {name},\nGrandma Hazel's old farm in Hollowmere is yours now. It's overgrown, but the soil is good.",
	"The Wildlings of the valley have always helped this farm. Treat them kindly, and they'll stay.",
	"Mira at the General Store has seeds, and Elder Barley would love to meet you. The village is just east of the farm. Welcome home!",
]

var ui: UIRoot
var hud: Hud
var world: World
var player: Player
var camera: Camera2D
var controller: Controller
var title: TitleScreen
var title_layer: CanvasLayer
var fade: ColorRect
var remotes: Dictionary = {}     # pid -> Player
var battle: BattleScreen
var _transitioning := false
var _shake := 0.0

func _ready() -> void:
	title_layer = CanvasLayer.new()
	title_layer.layer = 15
	add_child(title_layer)
	ui = UIRoot.new()
	add_child(ui)
	var fl := CanvasLayer.new()
	fl.layer = 30
	add_child(fl)
	fade = ColorRect.new()
	fade.color = Color(0.06, 0.04, 0.08)
	fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade.modulate.a = 0.0
	fl.add_child(fade)
	add_child(TouchControls.new(self))
	EventBus.map_change_requested.connect(_on_map_change)
	EventBus.day_started.connect(_on_day_started)
	EventBus.shake.connect(func(s: float):
		if Settings.screen_shake:
			_shake = maxf(_shake, s * 2.0))
	add_to_group("main")
	Coop.remote_moved.connect(_on_remote_moved)
	Coop.remote_left.connect(_remove_remote)
	Coop.emote_played.connect(_on_emote)
	Coop.chat_said.connect(_on_chat_said)
	Coop.snapshot_loaded.connect(_on_snapshot)
	Coop.pvp_challenge.connect(_on_pvp_challenge)
	Coop.pvp_started.connect(_on_pvp_started)
	Coop.trade_invited.connect(_on_trade_invited)
	Coop.trade_updated.connect(_on_trade_state)
	Net.coop_ended.connect(_on_coop_ended)
	EventBus.battle_requested.connect(_on_battle_requested)
	EventBus.story_advanced.connect(_on_story_advanced)
	EventBus.jukebox_changed.connect(func(): if battle == null: Audio.music(map_music()))
	Settings.text_scale_changed.connect(_rebuild_hud)
	get_viewport().size_changed.connect(_on_view_resized)
	show_title()

func _on_view_resized() -> void:
	if camera != null and world != null:
		_setup_camera()

## A crash, a frozen window, or a phone killing a backgrounded app should not drop the last minute.
func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		if player != null and not _transitioning and Net.mode != "client":
			SaveManager.autosave()

func _rebuild_hud() -> void:
	if hud == null:
		return
	var vis := hud.visible
	hud.queue_free()
	hud = Hud.new()
	add_child(hud)
	hud.visible = vis

# --- Title ------------------------------------------------------------------------------

func show_title() -> void:
	GameClock.running = false
	GameClock.clear_pauses()
	SaveManager.live = false
	ui.close_all()
	_leave_game()
	title = TitleScreen.new(ui)
	title_layer.add_child(title)
	title.new_game_requested.connect(_start_new)
	title.load_requested.connect(_load_slot)
	title.coop_requested.connect(func(): ui.open(CoopPanel.new(ui, false)))

func _on_story_advanced(ch: Dictionary) -> void:
	Audio.sfx("levelup")
	var rw: Dictionary = ch.get("reward", {})
	EventBus.toast.emit(tr("Chapter complete: %s%s") % [ch.title, (tr(" (%s)") % AdventureFlow.loot_text(rw)) if not rw.is_empty() else ""], "star")
	if not Adventure.chapter(GameState.world).is_empty():
		EventBus.toast.emit("Elder Barley has something to tell you.", "book")

func _start_new(opts: Dictionary) -> void:
	var slot := SaveManager.first_free_slot()
	if slot < 0:
		await ui.say(["All save slots are full. Delete a farm from the Load menu first."])
		return
	await _fade_to(1.0)
	GameState.new_game(opts)
	SaveManager.current_slot = slot
	SaveManager.save_game(slot)
	_enter_game()
	await _fade_to(0.0)
	var p := GameState.local_player()
	var lines: Array = []
	for l in INTRO:
		lines.append(l.replace("{name}", p.name))
	player.locked = true
	await ui.say(lines, "A letter")
	await _offer_tutorial(p)
	if not Settings.analytics_asked and Telemetry.enabled:
		var c: int = await ui.ask("Help make Hollowmere better? Share anonymous play stats: how long you play and how far your farm gets. Nothing personal, and you can change it in Settings.", ["Sure", "No thanks"])
		Settings.analytics = c == 0
		Settings.analytics_asked = true
		Settings.save_settings()
	player.locked = false

## First farm: ask. Players who have seen the tutorial (on any farm, any device) skip it
## and get its rewards; they can start it from the quest log.
func _offer_tutorial(p: PlayerData) -> void:
	var now := TimeService.now()
	if Settings.profile_get("tutorial_seen", false):
		Quests.skip_tutorial(p, now)
	else:
		var c: int = await ui.ask("Play the tutorial? It shows the basics step by step. You can skip it any time in the quest log.", ["Yes, show me", "No, I know the basics"])
		if c == 0:
			Quests.start_tutorial(p, now)
		else:
			Quests.skip_tutorial(p, now)
		Settings.profile_set("tutorial_seen", true)
	EventBus.quest_updated.emit()

func _load_slot(slot: int) -> void:
	await _fade_to(1.0)
	if not SaveManager.load_game(slot):
		await _fade_to(0.0)
		await ui.say(["That save couldn't be loaded."])
		return
	var away := GameState.catch_up()
	_enter_game()
	await _fade_to(0.0)
	if float(away.get("away", 0.0)) >= 600.0:
		player.locked = true
		var dr := DayReport.new(away)
		ui.open(dr)
		await dr.tree_exited
		if player:
			player.locked = false

var _visiting := false
var _redraw_after_battle := false

func _on_snapshot() -> void:
	_visiting = Net.mode == "client"
	if world == null:
		ui.close_all()
		_enter_game()

func _on_coop_ended(reason: String) -> void:
	if not _visiting:
		return
	_visiting = false
	if battle:
		await EventBus.battle_finished
	await _fade_to(1.0)
	GameState.started = false
	show_title()
	await _fade_to(0.0)
	if reason != "left":
		await ui.say([reason if reason != "" else "The connection to the farm was lost."])

# --- Game -------------------------------------------------------------------------------

func _enter_game() -> void:
	if title:
		title.queue_free()
		title = null
	_leave_game()
	world = World.new()
	add_child(world)
	move_child(world, 0)
	var pd := GameState.local_player()
	player = Player.new()
	player.pid = pd.id
	player.world = world
	world.ysort.add_child(player)
	camera = Camera2D.new()
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 9.0
	camera.offset = Vector2(0, -12)
	player.add_child(camera)
	hud = Hud.new()
	add_child(hud)
	controller = Controller.new()
	add_child(controller)
	controller.setup(self, ui, world, player)
	SaveManager.live = true
	player.warp_entered.connect(_on_warp)
	_go_to(pd.map_id, pd.pos)
	camera.reset_smoothing()
	GameClock.running = true

func _leave_game() -> void:
	for n in [controller, hud, world]:
		if is_instance_valid(n):
			n.queue_free()
	controller = null
	hud = null
	world = null
	player = null
	camera = null
	remotes.clear()

func _go_to(map_id: String, pos: Vector2) -> void:
	var pd := GameState.local_player()
	if GameState.map_info(map_id).is_empty():
		push_warning(tr("Unknown map %s") % map_id)
		map_id = "farm"
		var sp: Array = Data.get_map("farm").spawn
		pos = GameState.tile_center(Vector2i(int(sp[0]), int(sp[1])))
	pd.map_id = map_id
	world.load_map(map_id)
	player.position = pos
	pd.pos = pos
	_setup_camera()
	for pid in remotes.keys():
		var rp: PlayerData = GameState.player(pid)
		remotes[pid].visible = rp != null and rp.map_id == map_id
	Audio.music(map_music())
	EventBus.map_changed.emit(map_id)

## The map's own music, or on the farm the record playing on the jukebox.
func map_music() -> String:
	if bool(world.info.get("farm", false)):
		var track := str(GameState.world.get("flags", {}).get("jukebox", ""))
		if track != "":
			return track
	return str(world.info.get("music", "farm"))

func _setup_camera() -> void:
	var sz := world.map_size_px()
	var view := get_viewport().get_visible_rect().size
	camera.limit_left = 0 if sz.x >= view.x else -int((view.x - sz.x) / 2)
	camera.limit_right = int(sz.x) if sz.x >= view.x else int(sz.x + (view.x - sz.x) / 2)
	camera.limit_top = 0 if sz.y >= view.y else -int((view.y - sz.y) / 2)
	camera.limit_bottom = int(sz.y) if sz.y >= view.y else int(sz.y + (view.y - sz.y) / 2)
	camera.reset_smoothing()

func _fade_to(a: float, t: float = 0.25) -> void:
	var tw := create_tween()
	tw.tween_property(fade, "modulate:a", a, t)
	await tw.finished

func _on_map_change(map_id: String, tile: Vector2i) -> void:
	if world == null or _transitioning:
		return
	_transitioning = true
	player.locked = true
	Audio.sfx("door")
	await _fade_to(1.0, 0.2)
	_go_to(map_id, GameState.tile_center(tile))
	await _fade_to(0.0, 0.25)
	player.locked = false
	_transitioning = false

func _on_warp(w: Dictionary) -> void:
	if not GameState.is_open_requirement(w.get("requires", "")):
		EventBus.toast.emit(tr("The way is blocked. (%s)") % Economy.req_text(w.requires), "")
		player.position -= player.facing * 10.0
		return
	_on_map_change(w.to, Vector2i(int(w.tx), int(w.ty)))

func sleep() -> void:
	Audio.sfx("sleep")
	Coop.request_sleep()

func _on_day_started(_day: int, report: Dictionary) -> void:
	if world == null:
		return
	if not report.get("slept", true):
		if int(report.get("ship_total", 0)) > 0:
			EventBus.toast.emit(tr("A new day: the shipping bin paid %s.") % CoinLabel.text(int(report.ship_total)), "coin")
			Audio.sfx("coin")
		return
	_transitioning = true
	var pd := GameState.local_player()
	var wake_map := pd.map_id
	var wake_pos := pd.pos
	player.locked = true
	player.set_physics_process(false)
	ui.close_all()
	await _fade_to(1.0, 0.6)
	await get_tree().create_timer(0.5).timeout
	if world == null:
		return
	player.set_physics_process(true)
	_go_to(wake_map, wake_pos)
	player.facing = Vector2.DOWN
	await _fade_to(0.0, 0.5)
	var dr := DayReport.new(report)
	ui.open(dr)
	await dr.tree_exited
	if player:
		player.locked = false
	_transitioning = false

# --- Menus ------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if world == null or _transitioning or ui.is_open():
		return
	if event.is_action_pressed("menu"):
		var pm := PauseMenu.new(ui)
		pm.quit_to_title.connect(func():
			_visiting = false
			await _fade_to(1.0)
			Net.leave()
			GameState.started = false
			show_title()
			await _fade_to(0.0))
		ui.open(pm)
		get_viewport().set_input_as_handled()
		return
	for action in MenuShell.HOTKEYS:
		if InputMap.has_action(action) and event.is_action_pressed(action):
			Audio.sfx("open")
			open_menu(action)
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("coop"):
		Audio.sfx("open")
		ui.open(CoopPanel.new(ui, true))
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("emote"):
		_toggle_emote_wheel()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("chat") and (Net.is_online() or AgentBridge.has_agents()):
		_open_chat()
		get_viewport().set_input_as_handled()

## Opens the menu shell on the tab for a hotkey action (or a tab id).
func open_menu(tab: String) -> void:
	ui.open(MenuShell.new(ui, tab))

var _wheel: EmoteWheel

func _toggle_emote_wheel() -> void:
	if is_instance_valid(_wheel):
		_wheel.queue_free()
		_wheel = null
		return
	_wheel = EmoteWheel.new()
	_wheel.closed.connect(func():
		if is_instance_valid(_wheel):
			_wheel.queue_free()
		_wheel = null)
	ui.root.add_child(_wheel)

func _on_emote(pid: String, id: String) -> void:
	var n := _player_node(pid)
	if n:
		n.play_emote(id)

func _on_chat_said(pid: String, text: String) -> void:
	var n := _player_node(pid)
	if n and n.bubble:
		n.bubble.say(text)

func _player_node(pid: String) -> Player:
	if player and (pid == Net.local_id() or pid == player.pid or pid == "local"):
		return player
	return remotes.get(pid)

func _open_chat() -> void:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", UITheme.box(Color(0.1, 0.08, 0.1, 0.85), UITheme.COIN, 1, 3, 4, false))
	bar.anchor_top = 1
	bar.anchor_bottom = 1
	bar.offset_left = 8
	bar.offset_right = 300
	bar.offset_top = -66
	bar.offset_bottom = -44
	var e := LineEdit.new()
	e.placeholder_text = "Say something (Enter to send, Esc to cancel)"
	e.max_length = 200
	e.add_theme_font_size_override("font_size", UITheme.fs(10))
	bar.add_child(e)
	e.text_submitted.connect(func(t: String):
		Coop.send_chat(t)
		ui.close(bar))
	ui.open(bar, false)
	e.call_deferred("grab_focus")

# --- Friendly battles + trades ------------------------------------------------------------------

func _busy() -> bool:
	return world == null or battle != null or _transitioning

func _on_pvp_challenge(from_pid: String, from_name: String) -> void:
	if _busy() or not GameState.local_player().has_usable_party():
		Coop.decline_challenge(from_pid)
		return
	Audio.sfx("encounter")
	var c: int = await ui.ask(tr("%s challenges you to a friendly battle! (Nothing is lost, win or lose.)") % from_name, ["Battle!", "Not now"])
	if c == 0 and not _busy():
		Coop.accept_challenge(from_pid)
	else:
		Coop.decline_challenge(from_pid)

func _on_pvp_started(s: Dictionary) -> void:
	ui.close_all()
	var setup := s.duplicate()
	setup["kind"] = "pvp"
	setup["foe_name"] = s.name
	_on_battle_requested(setup)

func _on_trade_invited(tid: int, from_name: String) -> void:
	if _busy():
		Coop.trade_op("cancel", {"tid": tid})
		return
	var c: int = await ui.ask(tr("%s wants to trade with you.") % from_name, ["Let's trade", "No thanks"])
	Coop.trade_op("join" if c == 0 else "cancel", {"tid": tid})

func _on_trade_state(s: Dictionary) -> void:
	if _busy() or not str(s.status) in ["invite", "open"]:
		return
	for p in ui.stack:
		if p is TradePanel and (p as TradePanel).tid == int(s.tid):
			return
	var me := Net.local_id()
	if (str(s.status) == "invite" and str(s.a) == me) or (str(s.status) == "open" and str(s.b) == me):
		ui.close_all()
		ui.open(TradePanel.new(s))

# --- Battles ----------------------------------------------------------------------------

func _backdrop_for(info: Dictionary) -> String:
	if str(info.get("id", "")).begins_with("mine:"):
		return "cave"
	var b: String = info.get("biome", "grass")
	return b if Art.backdrop(b) != null else "grass"

## setup: {kind: "wild", species, level, starry, node} or {kind: "trainer"|"rival"|"warden", vid, team, foe_name, reward}
func _on_battle_requested(s: Dictionary) -> void:
	if world == null or battle != null or _transitioning or ui.is_open():
		return
	var pd := GameState.local_player()
	var node: WildCreature = s.get("node")
	if not pd.has_usable_party():
		EventBus.toast.emit("Your Wildlings are too tired to battle. Rest at home or the Wildling Center.", "")
		_break_wild_contact()
		player.encounter_grace = WILD_FLEE_GRACE
		return
	if s.kind == "wild":
		var c := Creature.create(s.species, int(s.level), GameState.rng, {"starry": s.get("starry", false)})
		s["team"] = [c]
	s["backdrop"] = _backdrop_for(world.info)
	var indoor: bool = world.info.get("indoor", false) or str(world.info.get("id", "")).begins_with("mine:")
	s["weather"] = "" if indoor else str(GameState.world.get("weather", ""))
	player.locked = true
	GameClock.pause("battle")
	hud.visible = false
	battle = BattleScreen.new(s)
	add_child(battle)
	var res: Dictionary = await battle.run()
	await _fade_to(1.0, 0.25)
	battle.queue_free()
	battle = null
	hud.visible = true
	var after: Array = []
	match res.result:
		"befriend":
			var c2: Creature = res.befriended
			c2.met = tr("Befriended in %s at Lv%d") % [world.info.get("name", world.map_id), c2.level]
			c2.heal_full()
			var where := "party" if pd.party.size() < PlayerData.PARTY_MAX else "den"
			if Net.is_authority():
				where = GameState.add_creature(pd, c2)
				GameState.bump_stat("befriend")
			else:
				Coop.act("befriend_act", [JSON.stringify(c2.to_dict())])
			after.append(tr("%s joined %s!") % [c2.display_name(), {"party": tr("your party"), "den": tr("the farm Den"), "sanctuary": tr("the Shelter")}[where]])
			if node:
				world.remove_creature(node)
			for rid in Data.regions:
				if Adventure.guardian_of(rid) == c2.species_id:
					var gr: Dictionary = await Coop.act_async("guardian_result_act", [rid, true])
					GameState.world.flags["guardian_home:" + rid] = true
					if gr.has("text"):
						after.append(str(gr.text))
						Audio.sfx("levelup")
					_redraw_after_battle = true
			if Data.legends.has(c2.species_id):
				await Coop.act_async("legend_result_act", [c2.species_id])
				after.append("A legend of the seasons walks with you now.")
		"win":
			if node:
				world.remove_creature(node)
			if s.kind != "wild":
				pd.stat_add("trainer_wins")
		"run":
			_break_wild_contact()
		"lose":
			pd.heal_party()
			if not s.get("friendly", false):
				var sp: Array = Data.get_map("farm").spawn
				_go_to("farm", GameState.tile_center(Vector2i(int(sp[0]), int(sp[1]))))
				GameState.advance_minutes(120)
	if s.get("boss", false) and res.result in ["befriend", "win"] and str(world.info.get("boss", {}).get("species", "")) == str(s.get("species", "")):
		var br: Dictionary = await Coop.act_async("deep_boss_act", [])
		if br.has("text"):
			after.append(str(br.text))
	if res.result in ["befriend", "win"] and not s.get("friendly", false):
		var sp: Dictionary = await Coop.act_async("battle_spoils_act", [str(s.kind), int(s.get("level", 10))])
		if int(sp.get("essence", 0)) > 0:
			EventBus.toast.emit(tr("Found %d Arcane Essence.") % int(sp.essence), "")
	if s.kind == "wild" and res.result in ["befriend", "win"] and not s.get("boss", false):
		var cr: Dictionary = await Coop.act_async("chain_act", [s.species])
		var n := int(cr.get("chain", {}).get("n", 0))
		if n in [Endless.CHAIN_LURE, 10, 20, 30, Endless.CHAIN_CAP]:
			EventBus.toast.emit(tr("%s chain x%d! Starry odds x%.1f%s") % [Data.species[s.species].name, n,
				Endless.chain_mult(cr.chain, s.species), " and more of them are about." if n == Endless.CHAIN_LURE else ""], "star")
	if _redraw_after_battle:
		_redraw_after_battle = false
		world.refresh_all()
	Audio.music(map_music())
	EventBus.party_changed.emit()
	await _fade_to(0.0, 0.3)
	if res.result == "befriend":
		Juice.burst(world, player.position + Vector2(0, -18), "befriend")
	if not after.is_empty():
		Audio.sfx("befriend")
		await ui.say(after)
	if res.result == "run":
		player.encounter_grace = WILD_FLEE_GRACE
	player.locked = false
	GameClock.resume("battle")
	EventBus.battle_finished.emit(res)

## Fleeing one Wildling must not drop you into the next one standing on the same spot.
func _break_wild_contact() -> void:
	if world == null or player == null:
		return
	var i := 0
	for raw in world.creatures:
		var w := raw as WildCreature
		if w == null or not is_instance_valid(w) or w.pet:
			continue
		if w.position.distance_to(player.position) > WildCreature.NOTICE_DIST + 16.0:
			continue
		w.stun(WILD_FLEE_STUN)
		w._notice_cd = 8.0
		var away: Vector2 = w.position - player.position
		if away.length() < 8.0:
			away = Vector2.RIGHT.rotated(float(i) * 1.25)
		var dest: Vector2 = player.position + away.normalized() * WILD_FLEE_PUSH
		if world.grid != null and not world.is_solid_at(dest, Vector2(6, 3)):
			w.position = dest
			w._target = dest
		i += 1

# --- Co-op remote players ---------------------------------------------------------------

func _on_remote_moved(pid: String, map_id: String, pos: Vector2, facing: Vector2, moving: bool) -> void:
	if world == null or pid == Net.local_id():
		return
	var rp: Player = remotes.get(pid)
	if rp == null:
		if GameState.player(pid) == null:
			return
		rp = Player.new()
		rp.pid = pid
		rp.local = false
		rp.world = world
		rp.position = pos
		world.ysort.add_child(rp)
		remotes[pid] = rp
	rp.visible = map_id == world.map_id
	rp.set_remote_state(pos, facing, moving)

func _remove_remote(pid: String) -> void:
	if remotes.has(pid):
		remotes[pid].queue_free()
		remotes.erase(pid)

func _process(delta: float) -> void:
	if camera and _shake > 0.0:
		_shake = maxf(0.0, _shake - delta * 12.0)
		camera.offset = Vector2(0, -12) + Vector2(randf_range(-_shake, _shake), randf_range(-_shake, _shake))
	elif camera:
		camera.offset = Vector2(0, -12)
