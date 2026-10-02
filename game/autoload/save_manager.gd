extends Node
## Versioned JSON saves in user://saves, with migrations and cloud sync hooks.

const DIR := "user://saves"
const MAX_SLOTS := 6

var current_slot: int = -1
var cloud_enabled: bool = false

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)

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

func save_game(slot: int = -1) -> bool:
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
	if cloud_enabled and Net.has_session():
		Net.cloud_save(slot, payload)
	return true

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
