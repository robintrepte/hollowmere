extends Node
## Versioned JSON saves in user://saves, with migrations and cloud sync hooks.

const DIR := "user://saves"
const MAX_SLOTS := 6
## Farming edits can arrive in a burst; write them shortly after, not on every tile.
const SOON := 1.0
## Position updates every frame and has no signal of its own.
const HEARTBEAT := 10.0

## Tests point this elsewhere so they never touch the player's farms.
var dir := DIR
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
	return "%s/slot_%d.json" % [dir, slot]

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
	var v := int(d.get("version", 0))
	if v < GameState.SAVE_VERSION and FileAccess.file_exists(slot_path(slot)):
		DirAccess.copy_absolute(slot_path(slot), "%s.v%d.bak" % [slot_path(slot), v])
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

## Upgrades older save formats in place, one version step at a time.
func migrate(d: Dictionary) -> Dictionary:
	var v: int = int(d.get("version", 0))
	var steps := [_migrate_0_to_1, _migrate_1_to_2, _migrate_2_to_3, _migrate_3_to_4]
	while v < GameState.SAVE_VERSION and v < steps.size():
		steps[v].call(d.state)
		v += 1
	d.version = v
	return d

func _migrate_0_to_1(state: Dictionary) -> void:
	var w: Dictionary = state.world
	if not w.has("farm"):
		w["farm"] = {"level": 1, "xp": 0}
	if not w.has("pairs"):
		w["pairs"] = []

## Version 2 runs the economy on the real clock. The real-time systems pick up from "now".
func _migrate_1_to_2(state: Dictionary) -> void:
	var w: Dictionary = state.world
	if not w.has("time"):
		w["time"] = {"last": TimeService.now()}
	for k in ["quests", "skills", "fishing", "mining", "casino", "tutorial"]:
		if not w.has(k):
			w[k] = {}

## v3: the farm runs in real time. Day counts become progress and unix timestamps, crops become
## tier I plants with their full harvests, and everyone gets a shovel and a bucket.
func _migrate_2_to_3(state: Dictionary) -> void:
	var w: Dictionary = state.world
	var now := TimeService.now()
	var abs_min := int(w.get("day", 0)) * 1440 + int(w.get("minute", Calendar.DAY_START))
	for m in state.get("grids", {}):
		var g: Dictionary = state.grids[m]
		for k in g.get("soil", {}):
			var s: Dictionary = g.soil[k]
			s["watered_until"] = now + CropGrowth.WATER_SECONDS if s.get("watered", false) else 0.0
			s["tilled_at"] = now
			if s.has("crop"):
				var c: Dictionary = s.crop
				var days := float(Data.crops.get(c.get("id", ""), {}).get("days", 1))
				c["progress"] = clampf(float(c.get("age", 0.0)) / maxf(1.0, days), 0.0, 1.0)
				c.erase("age")
				c["tier"] = 1
				c["harvests"] = CropGrowth.harvests_for_tier(1)
		for k in g.get("objects", {}):
			var o: Dictionary = g.objects[k]
			match o.get("kind", ""):
				"tree":
					o["planted_at"] = now - float(o.get("age", 0)) * CropGrowth.TREE_DAY_SECONDS
					o["fruit_at"] = 0.0
					o.erase("age")
				"machine":
					if not o.get("output", {}).is_empty():
						o["ready_at"] = now + maxf(0.0, float(o.get("ready_at", 0)) - abs_min) * CropGrowth.MACHINE_SECONDS_PER_MINUTE
	for slot in w.get("hatchery", []):
		if not slot.has("hatch_at"):
			var secs := maxf(1.0, float(slot.get("days", 1))) * CropGrowth.EGG_DAY_SECONDS
			slot["hatch_at"] = now + secs
			slot["secs"] = secs
			slot.erase("days")
	if not w.has("time"):
		w["time"] = {"last": now}
	w.time["last"] = now
	for pid in state.get("players", {}):
		var inv: Dictionary = state.players[pid].get("inventory", {})
		var have := []
		for e in inv.get("entries", []):
			have.append(str(e.get("id", "")))
		var gifts: Array = state.world.get("pending_gifts", [])
		for t in ["shovel", "bucket"]:
			if not t in have:
				gifts.append({"pid": pid, "id": t})
		state.world["pending_gifts"] = gifts

## v4 inserted the Gull Bay chapter at index 4; later chapters move up one, so Gull Bay counts as passed.
func _migrate_3_to_4(state: Dictionary) -> void:
	var w: Dictionary = state.world
	if int(w.get("quest", 0)) >= 4:
		w["quest"] = int(w.quest) + 1

## Cloud copies carry the state gzipped and base64-encoded under "z" to stay far below the server limit.
static func pack_cloud(payload: Dictionary) -> Dictionary:
	if not payload.has("state"):
		return payload
	var raw := JSON.stringify(payload.state).to_utf8_buffer()
	var out := payload.duplicate()
	out.erase("state")
	out["z"] = Marshalls.raw_to_base64(raw.compress(FileAccess.COMPRESSION_GZIP))
	out["zlen"] = raw.size()
	return out

static func unpack_cloud(payload: Dictionary) -> Dictionary:
	if not payload.has("z"):
		return payload
	var raw := Marshalls.base64_to_raw(str(payload.z)).decompress(int(payload.get("zlen", 0)), FileAccess.COMPRESSION_GZIP)
	var state = JSON.parse_string(raw.get_string_from_utf8())
	var out := payload.duplicate()
	out.erase("z")
	out.erase("zlen")
	if state is Dictionary:
		out["state"] = state
	return out

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var txt := FileAccess.get_file_as_string(path)
	var j := JSON.new()
	if j.parse(txt) != OK:
		return null
	return j.data
