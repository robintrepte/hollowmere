extends Node
## User settings and the input map (registered at runtime so it can be rebound).

signal text_scale_changed
signal ui_scale_changed
signal input_device_changed(pad: bool)
signal locale_changed

const PATH := "user://settings.cfg"
const TEXT_SCALES := [1.0, 1.2, 1.4]
const FONTS := ["pixel", "readable"]
const UI_SCALE_MIN := 0.75
const UI_SCALE_MAX := 1.5
const UI_SCALE_STEP := 0.05

const DEFAULT_KEYS := {
	"move_up": [KEY_W, KEY_UP],
	"move_down": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"use_tool": [KEY_SPACE],
	"interact": [KEY_E],
	"inventory": [KEY_TAB, KEY_I],
	"party": [KEY_P],
	"craft": [KEY_C],
	"journal": [KEY_J],
	"quests": [KEY_L],
	"skills": [KEY_K],
	"map": [KEY_M],
	"menu": [KEY_ESCAPE],
	"rotate_item": [KEY_R],
	"run": [KEY_SHIFT],
	"hotbar_next": [KEY_PERIOD],
	"hotbar_prev": [KEY_COMMA],
	"chat": [KEY_ENTER],
	"emote": [KEY_G],
	"coop": [KEY_O],
}
const DEFAULT_MOUSE := {
	"use_tool": [MOUSE_BUTTON_LEFT],
	"interact": [MOUSE_BUTTON_RIGHT],
	"hotbar_next": [MOUSE_BUTTON_WHEEL_DOWN],
	"hotbar_prev": [MOUSE_BUTTON_WHEEL_UP],
}
const DEFAULT_JOY := {
	"use_tool": [JOY_BUTTON_X],
	"interact": [JOY_BUTTON_A],
	"inventory": [JOY_BUTTON_Y],
	"menu": [JOY_BUTTON_START],
	"party": [JOY_BUTTON_BACK],
	"hotbar_next": [JOY_BUTTON_RIGHT_SHOULDER],
	"hotbar_prev": [JOY_BUTTON_LEFT_SHOULDER],
	"rotate_item": [JOY_BUTTON_B],
	"emote": [JOY_BUTTON_RIGHT_STICK],
	"move_up": [JOY_BUTTON_DPAD_UP],
	"move_down": [JOY_BUTTON_DPAD_DOWN],
	"move_left": [JOY_BUTTON_DPAD_LEFT],
	"move_right": [JOY_BUTTON_DPAD_RIGHT],
}

var clock_speed: float = 1.0          ## 1.0 = 10 real seconds per 10 game minutes; 1.5 = relaxed
var master_volume: float = 0.8
var music_volume: float = 0.6
var sfx_volume: float = 0.8
var text_scale: float = 1.0
var ui_scale: float = 1.0              ## menus, dialogue, the title screen and the HUD
var hud_scale: float = 1.0             ## extra multiplier on top of ui_scale, HUD only
var ui_font: String = "pixel"          ## pixel (Tiny5) | readable (Nunito)
var colorblind: bool = false
## Auto-reels fish (slightly lower quality) for players who find the minigame hard.
var easy_fishing: bool = false
var screen_shake: bool = true
var fullscreen: bool = false
var twelve_hour: bool = true
var auto_pause_menus: bool = true
var server_host: String = default_server("host", "127.0.0.1")
var server_port: int = default_server("port", 7350)
var server_key: String = default_server("key", "hollowmere_dev")
var server_ssl: bool = default_server("ssl", false)
var cloud_saves: bool = true
var custom_keys: Dictionary = {}       ## action -> [keycodes]
var using_pad := false                 ## last input came from a gamepad (not saved)
var locale: String = ""                ## "" follows the system language
var error_reports: bool = true          ## send crash and error reports (no personal data)
var analytics: bool = false            ## opt-in: session length and progress
var analytics_asked: bool = false
var touch_controls: String = "auto"     ## auto (touchscreens) | on | off
var hemisphere: String = "auto"         ## auto (from the locale) | north | south
var casino_daily_limit: int = 0        ## chips a day the player may stake; 0 = no limit
var chat_filter: bool = true           ## masks rude words in chat and bubbles
var hide_casino: bool = false          ## keeps the Grand Casino closed and its quests hidden
var profile: Dictionary = {}           ## free-form per-account data: tutorials seen, window spots
var stamps: Dictionary = {}            ## key -> unix time of the last change, for merging with the account copy

const SAVED := ["clock_speed", "master_volume", "music_volume", "sfx_volume", "text_scale", "ui_scale", "hud_scale", "ui_font", "colorblind", "easy_fishing", "screen_shake",
	"fullscreen", "twelve_hour", "auto_pause_menus", "server_host", "server_port", "server_key", "server_ssl", "cloud_saves",
	"custom_keys", "locale", "error_reports", "analytics", "analytics_asked", "touch_controls", "hemisphere", "casino_daily_limit", "hide_casino", "chat_filter", "profile", "stamps"]
## Follows the account to every device. The rest belongs to this device (screen, server, input hardware).
const SYNCED := ["clock_speed", "master_volume", "music_volume", "sfx_volume", "text_scale", "ui_scale", "hud_scale", "ui_font", "colorblind", "easy_fishing",
	"screen_shake", "twelve_hour", "auto_pause_menus", "custom_keys", "locale", "error_reports", "analytics",
	"analytics_asked", "hemisphere", "casino_daily_limit", "hide_casino", "chat_filter", "profile"]
const PROFILE_UPLOAD_DELAY := 3.0

var _saved_snapshot: Dictionary = {}
var _upload_timer: SceneTreeTimer

const I18N_DIR := "res://i18n"

## Server address baked into the build (project setting hollowmere/server/*, with .release overrides).
static func default_server(key: String, fallback: Variant) -> Variant:
	var v: Variant = ProjectSettings.get_setting("hollowmere/server/" + key, fallback)
	if v is String and (v == "" or v.begins_with("%")):
		return fallback
	return v

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()
	register_inputs()
	load_translations()
	apply()

## Registers every gettext catalog (<locale>.po) shipped in res://i18n.
func load_translations() -> void:
	var dir := DirAccess.open(I18N_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.ends_with(".po"):
			var t: Translation = load(I18N_DIR.path_join(f))
			if t:
				TranslationServer.add_translation(t)
		f = dir.get_next()

## Locales the player can pick: English plus every shipped catalog.
func available_locales() -> Array:
	var out: Array = ["en"]
	for l in TranslationServer.get_loaded_locales():
		if not l in out:
			out.append(l)
	return out

func register_inputs() -> void:
	for action in DEFAULT_KEYS:
		if InputMap.has_action(action):
			InputMap.action_erase_events(action)
		else:
			InputMap.add_action(action, 0.25)
		var keys: Array = custom_keys.get(action, DEFAULT_KEYS[action])
		for k in keys:
			var ev := InputEventKey.new()
			ev.physical_keycode = int(k)
			InputMap.action_add_event(action, ev)
		for b in DEFAULT_MOUSE.get(action, []):
			var mb := InputEventMouseButton.new()
			mb.button_index = b
			InputMap.action_add_event(action, mb)
		for j in DEFAULT_JOY.get(action, []):
			var jb := InputEventJoypadButton.new()
			jb.button_index = j
			InputMap.action_add_event(action, jb)
	var axes := {"move_left": [JOY_AXIS_LEFT_X, -1.0], "move_right": [JOY_AXIS_LEFT_X, 1.0], "move_up": [JOY_AXIS_LEFT_Y, -1.0], "move_down": [JOY_AXIS_LEFT_Y, 1.0]}
	for action in axes:
		var jm := InputEventJoypadMotion.new()
		jm.axis = axes[action][0]
		jm.axis_value = axes[action][1]
		InputMap.action_add_event(action, jm)
	for i in 10:
		var a := "hotbar_%d" % i
		if not InputMap.has_action(a):
			InputMap.add_action(a)
			var ev2 := InputEventKey.new()
			ev2.physical_keycode = KEY_1 + i if i < 9 else KEY_0
			InputMap.action_add_event(a, ev2)

func _input(event: InputEvent) -> void:
	var pad: bool = event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5)
	var kbm: bool = event is InputEventKey or event is InputEventMouseButton or (event is InputEventMouseMotion and event.relative.length() > 2.0)
	if pad and not using_pad:
		using_pad = true
		input_device_changed.emit(true)
	elif kbm and using_pad:
		using_pad = false
		input_device_changed.emit(false)

func set_text_scale(v: float) -> void:
	if is_equal_approx(v, text_scale):
		return
	text_scale = v
	text_scale_changed.emit()

func set_ui_scale(v: float) -> void:
	v = _clamp_scale(v)
	if is_equal_approx(v, ui_scale):
		return
	ui_scale = v
	ui_scale_changed.emit()

func set_hud_scale(v: float) -> void:
	v = _clamp_scale(v)
	if is_equal_approx(v, hud_scale):
		return
	hud_scale = v
	ui_scale_changed.emit()

## Menus, dialogue and the title screen.
func current_ui_scale() -> float:
	return ui_scale

## HUD bars, hotbar, clock and tracker. UI size applies here too; this slider adds on top.
func current_hud_scale() -> float:
	return ui_scale * hud_scale

func _clamp_scale(v: float) -> float:
	return clampf(snappedf(v, UI_SCALE_STEP), UI_SCALE_MIN, UI_SCALE_MAX)

func set_ui_font(id: String) -> void:
	if id not in FONTS:
		id = "pixel"
	if id == ui_font:
		return
	ui_font = id
	text_scale_changed.emit()

func rebind(action: String, keycode: int) -> void:
	custom_keys[action] = [keycode]
	register_inputs()
	save_settings()

func reset_bindings() -> void:
	custom_keys.clear()
	register_inputs()
	save_settings()

func key_name(action: String) -> String:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			return OS.get_keycode_string(ev.physical_keycode)
	return "?"

func apply() -> void:
	var next := locale if locale != "" else OS.get_locale_language()
	var prev := TranslationServer.get_locale()
	TranslationServer.set_locale(next)
	if prev != TranslationServer.get_locale():
		locale_changed.emit()
	_set_bus("Master", master_volume)
	_set_bus("Music", music_volume)
	_set_bus("SFX", sfx_volume)
	# Fill the window at any aspect (phone portrait, ultrawide, a browser tab). Extra
	# space shows more of the map instead of black bars.
	var win := get_tree().root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	if OS.get_name() != "Web":
		var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
		if DisplayServer.window_get_mode() != mode and DisplayServer.get_name() != "headless":
			DisplayServer.window_set_mode(mode)

func _set_bus(bus_name: String, v: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.0001)))
	AudioServer.set_bus_mute(idx, v <= 0.001)
	if bus_name == "Music":
		var audio := get_node_or_null("/root/Audio")
		if audio:
			audio.apply_music_mute()

func seconds_per_ten_minutes() -> float:
	return 10.0 * clock_speed

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for k in SAVED:
			if cfg.has_section_key("settings", k):
				set(k, cfg.get_value("settings", k))
	if ui_font not in FONTS:
		ui_font = "pixel"
	ui_scale = _clamp_scale(ui_scale)
	hud_scale = _clamp_scale(hud_scale)
	_saved_snapshot = synced_values()

func synced_values() -> Dictionary:
	var out := {}
	for k in SYNCED:
		var v: Variant = get(k)
		out[k] = v.duplicate(true) if v is Dictionary or v is Array else v
	return out

## Every setting that changed since the last save gets a fresh stamp, then the account copy follows.
func save_settings() -> void:
	var now := Time.get_unix_time_from_system()
	for k in SYNCED:
		if not _saved_snapshot.has(k) or var_to_str(_saved_snapshot[k]) != var_to_str(get(k)):
			stamps[k] = now
	_saved_snapshot = synced_values()
	_write_cfg()
	_queue_profile_upload()

func profile_get(key: String, default: Variant = null) -> Variant:
	return profile.get(key, default)

func profile_set(key: String, value: Variant) -> void:
	profile[key] = value
	save_settings()

## Newer stamp wins per key. Keys only one side knows keep that side's value.
static func merge(local_vals: Dictionary, local_stamps: Dictionary, remote_vals: Dictionary, remote_stamps: Dictionary) -> Dictionary:
	var vals := local_vals.duplicate(true)
	var st := local_stamps.duplicate()
	var local_changed := false
	var remote_stale := false
	for k in SYNCED:
		var lt := float(local_stamps.get(k, 0.0))
		var rt := float(remote_stamps.get(k, 0.0))
		if remote_vals.has(k) and rt > lt:
			if var_to_str(vals.get(k)) != var_to_str(remote_vals[k]):
				local_changed = true
			vals[k] = remote_vals[k]
			st[k] = rt
		elif lt > rt or not remote_vals.has(k):
			remote_stale = true
	return {"values": vals, "stamps": st, "local_changed": local_changed, "remote_stale": remote_stale}

## Called after sign-in: pull the account copy, keep whichever side changed each setting last.
func sync_profile() -> void:
	var net := get_node_or_null("/root/Net")
	if net == null or not net.has_session():
		return
	var remote: Dictionary = await net.profile_load()
	if remote.has("error"):
		return
	var m := merge(synced_values(), stamps, remote.get("values", {}), remote.get("stamps", {}))
	if m.local_changed:
		var prev_scale := text_scale
		var prev_font := ui_font
		var prev_ui := ui_scale
		var prev_hud := hud_scale
		for k in m.values:
			if k in SYNCED:
				set(k, _typed(k, m.values[k]))
		ui_scale = _clamp_scale(ui_scale)
		hud_scale = _clamp_scale(hud_scale)
		stamps = m.stamps
		_saved_snapshot = synced_values()
		_write_cfg()
		register_inputs()
		apply()
		if prev_scale != text_scale or prev_font != ui_font:
			text_scale_changed.emit()
		if not is_equal_approx(prev_ui, ui_scale) or not is_equal_approx(prev_hud, hud_scale):
			ui_scale_changed.emit()
	if m.remote_stale:
		await upload_profile()

## JSON turns ints into floats and loses dictionary key types.
func _typed(k: String, v: Variant) -> Variant:
	var cur: Variant = get(k)
	match typeof(cur):
		TYPE_BOOL:
			return bool(v)
		TYPE_INT:
			return int(v)
		TYPE_FLOAT:
			return float(v)
		TYPE_STRING:
			return str(v)
		TYPE_DICTIONARY:
			if k == "custom_keys" and v is Dictionary:
				var keys := {}
				for a in v:
					var codes: Array = []
					for c in v[a]:
						codes.append(int(c))
					keys[str(a)] = codes
				return keys
			return v if v is Dictionary else {}
	return v

func upload_profile() -> void:
	var net := get_node_or_null("/root/Net")
	if net == null or not net.has_session():
		return
	await net.profile_save({"values": synced_values(), "stamps": stamps})

func _queue_profile_upload() -> void:
	var net := get_node_or_null("/root/Net")
	if net == null or not net.has_session() or not is_inside_tree():
		return
	if _upload_timer and _upload_timer.time_left > 0.0:
		return
	_upload_timer = get_tree().create_timer(PROFILE_UPLOAD_DELAY, true, false, true)
	_upload_timer.timeout.connect(upload_profile)

func _write_cfg() -> void:
	var cfg := ConfigFile.new()
	for k in SAVED:
		## Only a server the player changed is pinned, so builds can move to a new address.
		if k.begins_with("server_") and get(k) == default_server(k.trim_prefix("server_"), get(k)):
			continue
		cfg.set_value("settings", k, get(k))
	cfg.save(PATH)
