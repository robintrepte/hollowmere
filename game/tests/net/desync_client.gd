extends Node
## Client half of desync_test: joins, farms the shared patch at random, sleeps, reports its state hash.

const DesyncTest := preload("res://tests/net/desync_test.gd")

var lines: PackedStringArray = []
var out_path := ""

func _ready() -> void:
	var port := Net.ENET_PORT
	var id := "bot"
	var seed_v := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.substr(7))
		elif a.begins_with("--id="):
			id = a.substr(5)
		elif a.begins_with("--seed="):
			seed_v = int(a.substr(7))
		elif a.begins_with("--out="):
			out_path = a.substr(6)
	Net.account_id = id
	Net.display_name = id
	_check(Net.join_lan("127.0.0.1", port), "join_lan")
	_check(await _until(func(): return GameState.started and GameState.local_player() != null, 20.0), "received the farm")
	if not GameState.started:
		_finish()
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	for i in 25:
		DesyncTest.act_randomly(rng)
		await get_tree().create_timer(rng.randf_range(0.03, 0.12)).timeout
	var day0 := GameState.day()
	Coop.send_chat("done:" + id)
	Coop.request_sleep()
	_check(await _until(func(): return GameState.day() == day0 + 1, 30.0), "slept into the next day")
	await get_tree().create_timer(1.5).timeout
	lines.append("HASH " + DesyncTest.state_hash())
	var sf := FileAccess.open(out_path + ".json", FileAccess.WRITE)
	sf.store_string(DesyncTest.state_snapshot())
	sf.close()
	_finish()

func _finish() -> void:
	Net.leave()
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(lines))
		f.close()
	get_tree().quit()

func _until(cond: Callable, timeout: float) -> bool:
	var t := 0.0
	while not cond.call() and t < timeout:
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	return cond.call()

func _check(ok: bool, what: String) -> void:
	lines.append(("ok   " if ok else "FAIL ") + what)
