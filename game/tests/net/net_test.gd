extends Node
## Two-process co-op test over ENet. This process hosts a farm; it launches a second Godot
## (net_client.tscn) that joins, and both sides check what they see.
##   godot --headless --path game res://tests/net/net_test.tscn

const TIMEOUT := 90.0

var port := 0
var result_path := ""
var fails := 0
var _client_pid := -1
var _trade_offered := false

func _ready() -> void:
	port = 25000 + randi() % 2000
	result_path = OS.get_cache_dir().path_join("hollowmere_net_%d.txt" % port)
	DirAccess.remove_absolute(result_path)
	GameState.new_game({"player_name": "Hosty", "farm_name": "Net", "starter": "sproutle", "seed": 4242})
	GameState.local_player().inventory.add("parsnip", 4)
	_check(Net.host_lan(port), "host opens LAN port %d" % port)
	Net.chat_received.connect(_on_chat)
	Coop.trade_invited.connect(func(tid: int, _n: String): Coop.trade_op("join", {"tid": tid}))
	Coop.trade_updated.connect(_on_trade)
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "res://tests/net/net_client.tscn", "--", "--port=%d" % port, "--out=%s" % result_path]
	_client_pid = OS.create_process(OS.get_executable_path(), args)
	_check(_client_pid > 0, "client process started")
	var t := 0.0
	while t < TIMEOUT and OS.is_process_running(_client_pid):
		await get_tree().create_timer(0.2).timeout
		t += 0.2
	if OS.is_process_running(_client_pid):
		OS.kill(_client_pid)
		_check(false, "client finished in time")
	_check(GameState.player("client_test") != null, "host created the visitor's farmhand")
	var cp := GameState.player("client_test")
	if cp:
		_check(cp.inventory.count("parsnip") >= 1, "host sees the parsnip the visitor received")
	_check(GameState.day() == 1, "the day advanced once both slept (day %d)" % GameState.day())
	var txt := FileAccess.get_file_as_string(result_path)
	if txt == "":
		_check(false, "client wrote results")
	else:
		for line in txt.split("\n", false):
			print("  client: ", line)
			if line.begins_with("FAIL"):
				fails += 1
	Net.leave()
	print("NET TEST DONE, %d failures" % fails)
	get_tree().quit(1 if fails > 0 else 0)

func _on_chat(_from: String, text: String) -> void:
	match text:
		"hello-host":
			var g := GameState.grid("farm")
			var tile := Vector2i(-1, -1)
			for y in range(4, g.h):
				for x in range(4, g.w):
					if tile.x < 0 and g.can_till(Vector2i(x, y)):
						tile = Vector2i(x, y)
			g.till(tile)
			g.water(tile)
			EventBus.tile_changed.emit("farm", tile)
			GameState.add_money(123)
			Coop.send_chat("tiled:%d,%d" % [tile.x, tile.y])
		"sleeping":
			Coop.request_sleep()

func _on_trade(s: Dictionary) -> void:
	if str(s.status) != "open":
		return
	var theirs: Array = s.offer.get("client_test", [])
	if theirs.is_empty() or _trade_offered:
		if not theirs.is_empty() and not bool(s.ok.get("local", false)) and not s.offer.get("local", []).is_empty():
			Coop.trade_op("ready", {"tid": int(s.tid)})
		return
	_trade_offered = true
	var e: Dictionary = GameState.local_player().inventory.first_of("parsnip")
	Coop.trade_op("offer", {"tid": int(s.tid), "offer": [{"kind": "item", "uid": e.uid, "n": 1}]})

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1
