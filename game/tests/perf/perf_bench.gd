extends Node
## Frame-time benchmark for the busiest scenes: a fully planted farm with machines and 30 working
## Wildlings at dusk, the village, a region with wild spawns, and a battle. Vsync is off and the
## camera keeps moving. Needs a window (not --headless).
##   godot --path game res://tests/perf/perf_bench.tscn -- --out=/abs/dir [--budget-ms=4] [--seconds=4]
## The budget is the 95th-percentile frame time on this machine; 4 ms on an Apple M-series leaves
## room for a 2015 MacBook (~4-5x slower) to hold 60 fps.

var out_dir := "user://perf"
var budget_ms := 4.0
var seconds := 4.0
var main: Node
var results: Array = []

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--budget-ms="):
			budget_ms = float(a.substr(12))
		elif a.begins_with("--seconds="):
			seconds = float(a.substr(10))
	DirAccess.make_dir_recursive_absolute(out_dir)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await _wait(0.3)
	var slot := SaveManager.first_free_slot()
	main._start_new({"player_name": "Bench", "farm_name": "Bench", "starter": "sproutle", "seed": 31337})
	await _wait(1.0)
	await main.ui.dialogue.dismiss()
	main.ui.close_all()
	_fill_farm()
	GameState.world.minute = 19 * 60
	await _go("farm", Vector2i(30, 20))
	await _measure("farm_full_dusk", true)
	await _go("town", Vector2i(21, 18))
	await _measure("village", true)
	await _go("whisperwood", Vector2i(37, 18))
	await _measure("whisperwood", true)
	main.controller.adventure._battle({"kind": "wild", "species": "thornwarden", "level": 30, "ai": 2, "friendly": true})
	await _wait(1.5)
	await _measure("battle", false)
	if slot >= 0:
		SaveManager.delete_slot(slot)
	_report()

func _fill_farm() -> void:
	var g: FarmGrid = GameState.grid("farm")
	var crops: Array = Data.crop_order.filter(func(c): return GameState.season() in Data.crops[c].seasons)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var planted := 0
	var machines := ["keg", "preserves_jar", "furnace", "sprinkler", "scarecrow"]
	for y in g.h:
		for x in g.w:
			var p := Vector2i(x, y)
			if not g.can_till(p):
				continue
			g.till(p)
			if planted % 23 == 11:
				g.place_object(p, machines[(planted / 23) % machines.size()])
			elif g.plant(p, crops[planted % crops.size()] + "_seeds", GameState.season()):
				g.soil[Tiles.key(p)].crop.age = float(rng.randi_range(0, 12))
				g.water(p)
			planted += 1
	for i in 30:
		var c := Creature.create(Data.species.keys()[i * 3 % Data.species.size()], 20, rng)
		c.owner = GameState.local_player().id
		GameState.ranch.append(c)
	print("farm: %d tiles planted or built, %d Wildlings on the ranch" % [planted, GameState.ranch.size()])

func _go(map_id: String, t: Vector2i) -> void:
	EventBus.map_change_requested.emit(map_id, t)
	await _wait(1.0)
	main.player.locked = false

func _measure(name: String, roam: bool) -> void:
	var times: Array = []
	var draws: Array = []
	var start: Vector2 = main.player.position if main.player else Vector2.ZERO
	var t0 := Time.get_ticks_usec()
	var last := t0
	while (Time.get_ticks_usec() - t0) / 1e6 < seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		times.append((now - last) / 1000.0)
		if (now - last) > 16700 and times.size() > 5:
			print("  long frame %.1f ms at minute %d" % [(now - last) / 1000.0, GameState.minute()])
		last = now
		draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		if roam and main.player:
			var k := (now - t0) / 1e6
			main.player.position = start + Vector2(cos(k * 0.9), sin(k * 1.3)) * 220.0
	times = times.slice(5)
	times.sort()
	draws.sort()
	var n := times.size()
	var avg := 0.0
	for v in times:
		avg += v
	avg /= maxf(1.0, n)
	var r := {
		"scene": name, "frames": n, "fps": 1000.0 / avg, "avg_ms": avg,
		"p95_ms": times[int(n * 0.95)], "p99_ms": times[int(n * 0.99)], "max_ms": times[-1],
		"draw_calls_p95": draws[int(draws.size() * 0.95)],
		"frames_over_16ms": times.filter(func(v): return v > 16.7).size(),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
	}
	results.append(r)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out_dir.path_join("perf_%s.png" % name))
	print("%-16s %6.0f fps  avg %5.2f ms  p95 %5.2f ms  p99 %5.2f ms  max %6.2f ms  >16ms %2d  draws %4d  nodes %5d  mem %5.1f MB" % [
		name, r.fps, r.avg_ms, r.p95_ms, r.p99_ms, r.max_ms, int(r.frames_over_16ms), int(r.draw_calls_p95), int(r.nodes), r.mem_mb])

func _report() -> void:
	var f := FileAccess.open(out_dir.path_join("perf.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"budget_p95_ms": budget_ms, "gpu": RenderingServer.get_video_adapter_name(), "results": results}, "  "))
	f.close()
	var over: Array = results.filter(func(r): return r.p95_ms > budget_ms)
	for r in over:
		print("OVER BUDGET %s: p95 %.2f ms > %.2f ms" % [r.scene, r.p95_ms, budget_ms])
	print("PERF DONE, %d over budget" % over.size())
	get_tree().quit(1 if not over.is_empty() else 0)

func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout
