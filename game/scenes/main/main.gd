extends Node
## Root: title <-> game flow, map transitions, sleeping, camera, menus and remote players.

const INTRO := [
	"Dear {name},\nGrandma Juniper's old farm in Hollowmere is yours now. It's overgrown, but the soil is good.",
	"The Wildlings of the valley have always helped this farm. Treat them kindly, and they'll stay.",
	"Mira at the General Store has seeds. The village is just east of the farm. Welcome home!",
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
	EventBus.map_change_requested.connect(_on_map_change)
	EventBus.day_started.connect(_on_day_started)
	EventBus.shake.connect(func(s: float):
		if Settings.screen_shake:
			_shake = maxf(_shake, s * 2.0))
	Coop.remote_moved.connect(_on_remote_moved)
	Coop.remote_left.connect(_remove_remote)
	Coop.snapshot_loaded.connect(_on_snapshot)
	show_title()

# --- Title ------------------------------------------------------------------------------

func show_title() -> void:
	GameClock.running = false
	GameClock.clear_pauses()
	ui.close_all()
	_leave_game()
	title = TitleScreen.new(ui)
	title_layer.add_child(title)
	title.new_game_requested.connect(_start_new)
	title.load_requested.connect(_load_slot)
	title.coop_requested.connect(func(): EventBus.toast.emit("Online co-op arrives with the server update.", ""))

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
	player.locked = false

func _load_slot(slot: int) -> void:
	await _fade_to(1.0)
	if not SaveManager.load_game(slot):
		await _fade_to(0.0)
		await ui.say(["That save couldn't be loaded."])
		return
	_enter_game()
	await _fade_to(0.0)

func _on_snapshot() -> void:
	if world == null:
		_enter_game()

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
		push_warning("Unknown map %s" % map_id)
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
	Audio.music(world.info.get("music", "farm"))
	EventBus.map_changed.emit(map_id)

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
		EventBus.toast.emit("The way is blocked. (%s)" % Economy.req_text(w.requires), "")
		player.position -= player.facing * 10.0
		return
	_on_map_change(w.to, Vector2i(int(w.tx), int(w.ty)))

func sleep() -> void:
	Audio.sfx("sleep")
	Coop.request_sleep()

func _on_day_started(_day: int, report: Dictionary) -> void:
	if world == null:
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
	await dr.closed
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
			await _fade_to(1.0)
			Net.leave()
			GameState.started = false
			show_title()
			await _fade_to(0.0))
		ui.open(pm)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("inventory"):
		Audio.sfx("open")
		ui.open(InventoryPanel.new(GameState.local_player()))
		get_viewport().set_input_as_handled()

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
