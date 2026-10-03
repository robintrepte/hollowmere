extends Node
## Versioned JSON saves in user://saves, with migrations and cloud sync hooks.

const DIR := "user://saves"
const MAX_SLOTS := 6
## Farming edits can arrive in a burst; write them shortly after, not on every tile.
const SOON := 1.0
## Position updates every frame and has no signal of its own.
const HEARTBEAT := 10.0

var current_slot: int = -1
## True only while a farm is on screen. Tests and the title screen stay quiet.
var live := false
var _quiet := false
var _dirty := false
var _soon := 0.0
var _heartbeat := 0.0
var _writing := false

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	EventBus.inventory_changed.connect(checkpoint)
	EventBus.money_changed.connect(func(_m, _d): checkpoint())
	EventBus.party_changed.connect(checkpoint)
	EventBus.quest_updated.connect(checkpoint)
	EventBus.map_changed.connect(func(_id): checkpoint())
	EventBus.battle_finished.connect(func(_r): checkpoint())
	EventBus.story_advanced.connect(func(_c): checkpoint())
	EventBus.creature_befriended.connect(func(_c): checkpoint())
	EventBus.egg_hatched.connect(func(_c): checkpoint())
	EventBus.shrine_restored.connect(func(_r): checkpoint())
	EventBus.tile_changed.connect(func(_map, _t): touch())
	EventBus.objects_changed.connect(func(_map): touch())

func _process(delta: float) -> void:
	if not live or _quiet:
		return
	_heartbeat += delta
	if _dirty:
		_soon += delta
	if (_dirty and _soon >= SOON) or _heartbeat >= HEARTBEAT:
		checkpoint()

## Holds writes across an overnight resolution so a crash cannot store a half-finished day.
func set_quiet(on: bool) -> void:
	_quiet = on

## Marks a small edit (a watered tile, a placed object) to be written within a second.
func touch() -> void:
	if live and not _quiet:
		_dirty = true

## Writes the current slot now. Local only; the nightly save and the pause menu still upload.
func checkpoint() -> void:
	if _writing or not live or _quiet or current_slot < 0 or not GameState.started:
		return
	_dirty = false
	_soon = 0.0
	_heartbeat = 0.0
	_writing = true
	save_game(current_slot, false)
	_writing = false

func slot_path(slot: int) -> String:
	return "%s/slot_%d.json" % [DIR, slot]

func list_slots() -> Array:
	var out: Array = []
	for i in MAX_SLOTS:
		var meta := read_meta(i)
		out.append(meta)
	return out

func read_meta(slot: int) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var d = _read_json(path)
	if not d is Dictionary:
		return {"corrupt": true, "slot": slot}
	return d.get("meta", {}).merged({"slot": slot})

func first_free_slot() -> int:
	for i in MAX_SLOTS:
		if not FileAccess.file_exists(slot_path(i)):
			return i
	return -1

func make_payload() -> Dictionary:
	var p := GameState.local_player()
	return {
		"version": GameState.SAVE_VERSION,
		"meta": {
			"farm": GameState.world.farm_name, "player": p.name if p else "", "day": GameState.day(),
			"date": Calendar.date_string(GameState.day()), "year": Calendar.year(GameState.day()),
			"money": GameState.money(), "dex": Progression.owned_count(GameState.world.dex),
			"saved_at": Time.get_unix_time_from_system(), "farm_level": int(GameState.world.farm.level),
		},
		"state": GameState.to_dict(),
	}

func save_game(slot: int = -1, upload: bool = true) -> bool:
	if slot < 0:
		slot = current_slot
	if slot < 0 or not GameState.started:
		return false
	if not Net.is_authority():
		return false
	var payload := make_payload()
	var path := slot_path(slot)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Save failed: %s" % FileAccess.get_open_error())
		return false
	f.store_string(JSON.stringify(payload))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.copy_absolute(path, path + ".bak")
	DirAccess.rename_absolute(tmp, path)
	current_slot = slot
	if upload and Settings.cloud_saves and Net.has_session():
		Net.cloud_save(slot, payload)
	return true

func read_payload(slot: int) -> Dictionary:
	var d = _read_json(slot_path(slot))
	return d if d is Dictionary and d.has("state") else {}

## Cloud entries ({slot, meta, payload}) that are missing locally or saved later than the local copy.
func newer_in_cloud(cloud: Array) -> Array:
	var out: Array = []
	for c: Dictionary in cloud:
		var local := read_meta(int(c.slot))
		var cloud_t := float(c.meta.get("saved_at", 0))
		if local.is_empty() or local.get("corrupt", false) or cloud_t > float(local.get("saved_at", 0)) + 1.0:
			out.append(c)
	return out

## Writes a downloaded cloud payload to its local slot (keeping a .bak of what was there).
func install_payload(slot: int, payload: Dictionary) -> bool:
	if not payload.has("state"):
		return false
	var path := slot_path(slot)
	if FileAccess.file_exists(path):
		DirAccess.copy_absolute(path, path + ".bak")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(payload))
	f.close()
	return true

## Uploads every local farm; returns how many made it.
func upload_all() -> int:
	var n := 0
	for i in MAX_SLOTS:
		var p := read_payload(i)
		if not p.is_empty() and await Net.cloud_save(i, p):
			n += 1
	return n

func autosave() -> void:
	if current_slot >= 0:
		save_game(current_slot)

func load_game(slot: int) -> bool:
	var d = _read_json(slot_path(slot))
	if not d is Dictionary or not d.has("state"):
		d = _read_json(slot_path(slot) + ".bak")
		if not d is Dictionary or not d.has("state"):
			return false
	return load_payload(d, slot)

func load_payload(d: Dictionary, slot: int) -> bool:
	d = migrate(d)
	GameState.from_dict(d.state)
	current_slot = slot
	return true

func delete_slot(slot: int) -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(slot_path(slot) + suffix):
			DirAccess.remove_absolute(slot_path(slot) + suffix)
	if Net.has_session():
		Net.cloud_delete(slot)

## Upgrades older save formats in place.
func migrate(d: Dictionary) -> Dictionary:
	var v: int = int(d.get("version", 0))
	if v < 1:
		var w: Dictionary = d.state.world
		if not w.has("farm"):
			w["farm"] = {"level": 1, "xp": 0}
		if not w.has("pairs"):
			w["pairs"] = []
		v = 1
	d.version = v
	return d

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var txt := FileAccess.get_file_as_string(path)
	var j := JSON.new()
	if j.parse(txt) != OK:
		return null
	return j.data
