extends Node
## User settings and the input map (registered at runtime so it can be rebound).

const PATH := "user://settings.cfg"

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
	"map": [KEY_M],
	"menu": [KEY_ESCAPE],
	"rotate_item": [KEY_R],
	"run": [KEY_SHIFT],
	"hotbar_next": [KEY_PERIOD],
	"hotbar_prev": [KEY_COMMA],
	"chat": [KEY_ENTER],
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
var colorblind: bool = false
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
	apply()

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
	_set_bus("Master", master_volume)
	_set_bus("Music", music_volume)
	_set_bus("SFX", sfx_volume)
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

func seconds_per_ten_minutes() -> float:
	return 10.0 * clock_speed

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for k in ["clock_speed", "master_volume", "music_volume", "sfx_volume", "text_scale", "colorblind", "screen_shake",
			"fullscreen", "twelve_hour", "auto_pause_menus", "server_host", "server_port", "server_key", "server_ssl", "cloud_saves", "custom_keys"]:
		if cfg.has_section_key("settings", k):
			set(k, cfg.get_value("settings", k))

func save_settings() -> void:
	var cfg := ConfigFile.new()
	for k in ["clock_speed", "master_volume", "music_volume", "sfx_volume", "text_scale", "colorblind", "screen_shake",
			"fullscreen", "twelve_hour", "auto_pause_menus", "server_host", "server_port", "server_key", "server_ssl", "cloud_saves", "custom_keys"]:
		## Only a server the player changed is pinned, so builds can move to a new address.
		if k.begins_with("server_") and get(k) == default_server(k.trim_prefix("server_"), get(k)):
			continue
		cfg.set_value("settings", k, get(k))
	cfg.save(PATH)
