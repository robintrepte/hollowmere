extends Node
## Desync test: this process hosts, three headless clients join over ENet, and all four farm the
## same patch at once (overlapping tiles on purpose). After everyone sleeps, each side hashes its
## view of the farm, money and day; every client must match the host.
##   godot --headless --path game res://tests/net/desync_test.tscn [-- --clients=3]

const TIMEOUT := 120.0
const PATCH := Rect2i(18, 18, 10, 6)

var port := 0
var clients := 3
var fails := 0
var _pids: Array = []
var _outs: Array = []
var _done := {}

static func state_snapshot() -> String:
	var g := GameState.grid("farm")
	var snap := {"soil": g.soil, "objects": g.objects, "money": GameState.money(), "day": GameState.day(),
		"shipping": GameState.world.shipping}
	return JSON.stringify(_canon(snap), "", true)

## Network transfer turns some ints into floats (1 vs 1.0); compare values, not encodings.
static func _canon(v: Variant) -> Variant:
	if v is Dictionary:
		var d := {}
		for k in v:
			d[str(k)] = _canon(v[k])
		return d
	if v is Array:
		return v.map(_canon)
	if v is float and is_equal_approx(v, roundf(v)):
		return int(roundf(v))
	if v is float:
		return snappedf(v, 0.0001)
	return v

static func state_hash() -> String:
	return state_snapshot().md5_text()

static func act_randomly(rng: RandomNumberGenerator) -> void:
	var t := Vector2i(PATCH.position.x + rng.randi_range(0, PATCH.size.x - 1), PATCH.position.y + rng.randi_range(0, PATCH.size.y - 1))
	var me := GameState.local_player()
	match rng.randi_range(0, 3):
		0, 1:
			Coop.act("use_tool", ["farm", t, "hoe"])
		2:
			Coop.act("use_tool", ["farm", t, "watering_can"])
		3:
			var seeds: Dictionary = me.inventory.first_of("parsnip_seeds")
			if not seeds.is_empty():
				Coop.act("use_item", ["farm", t, seeds.uid])

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--clients="):
			clients = int(a.substr(10))
	port = 27000 + randi() % 2000
	GameState.new_game({"player_name": "Hosty", "farm_name": "Desync", "starter": "sproutle", "seed": 99})
	_check(Net.host_lan(port), "host opens LAN port %d" % port)
	Net.chat_received.connect(func(_f: String, t: String):
		if t.begins_with("done:"):
			_done[t.trim_prefix("done:")] = true)
	for i in clients:
		var out := OS.get_cache_dir().path_join("hollowmere_desync_%d_%d.txt" % [port, i])
		DirAccess.remove_absolute(out)
		_outs.append(out)
		var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "res://tests/net/desync_client.tscn", "--",
			"--port=%d" % port, "--id=bot%d" % i, "--seed=%d" % (i + 1), "--out=%s" % out]
		_pids.append(OS.create_process(OS.get_executable_path(), args))
	_check(await _until(func(): return Coop.online_players().size() == clients, 20.0), "%d clients joined" % clients)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000
	for i in 25:
		act_randomly(rng)
		await get_tree().create_timer(rng.randf_range(0.03, 0.12)).timeout
	_check(await _until(func(): return _done.size() == clients, 30.0), "every client finished farming")
	var day0 := GameState.day()
	Coop.request_sleep()
	_check(await _until(func(): return GameState.day() == day0 + 1, 15.0), "everyone slept into the next day")
	await get_tree().create_timer(1.0).timeout
	var host_hash := state_hash()
	var hf := FileAccess.open(OS.get_cache_dir().path_join("hollowmere_desync_host.json"), FileAccess.WRITE)
	hf.store_string(state_snapshot())
	hf.close()
	var g := GameState.grid("farm")
	var tilled := 0
	for k in g.soil:
		tilled += 1
	_check(tilled > 5, "the patch got farmed (%d soil tiles)" % tilled)
	var t := 0.0
	while t < TIMEOUT and _pids.any(func(p): return OS.is_process_running(p)):
		await get_tree().create_timer(0.2).timeout
		t += 0.2
	for i in clients:
		if OS.is_process_running(_pids[i]):
			OS.kill(_pids[i])
		var txt := FileAccess.get_file_as_string(_outs[i])
		var their := ""
		for line in txt.split("\n", false):
			if line.begins_with("HASH "):
				their = line.substr(5)
			elif line.begins_with("FAIL"):
				print("  bot%d: %s" % [i, line])
				fails += 1
		_check(their == host_hash, "bot%d matches the host (%s vs %s)" % [i, their, host_hash])
	Net.leave()
	print("DESYNC TEST DONE, %d failures" % fails)
	get_tree().quit(1 if fails > 0 else 0)

func _until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	return cond.call()

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1
