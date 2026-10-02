extends Node
## Client half of net_test: joins the host over ENet, exercises co-op, writes results to --out.

var lines: PackedStringArray = []
var out_path := ""
var _chat: Array = []
var _trade: Dictionary = {}

func _ready() -> void:
	var port := Net.ENET_PORT
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.substr(7))
		elif a.begins_with("--out="):
			out_path = a.substr(6)
	Net.account_id = "client_test"
	Net.display_name = "Visitor"
	Net.chat_received.connect(func(_f: String, t: String): _chat.append(t))
	Coop.trade_updated.connect(func(s: Dictionary): _trade = s)
	_check(Net.join_lan("127.0.0.1", port), "join_lan")
	_check(await _until(func(): return GameState.started, 15.0), "received the farm snapshot")
	if not GameState.started:
		_finish()
		return
	var me := GameState.local_player()
	_check(me != null and me.id == "client_test", "playing as our own farmhand")
	_check(GameState.player("local") != null and GameState.player("local").name == "Hosty", "host's farmer is in the world")
	_check(await _until(func(): return Coop.online_players().size() == 1, 5.0), "roster lists the host")
	var money0 := GameState.money()
	var day0 := GameState.day()

	Coop.send_chat("hello-host")
	_check(await _until(func(): return _chat.any(func(t: String): return t.begins_with("tiled:")), 10.0), "host replied over chat")
	var tiled: String = "0,0"
	for t: String in _chat:
		if t.begins_with("tiled:"):
			tiled = t.trim_prefix("tiled:")
	var tile := Vector2i(int(tiled.get_slice(",", 0)), int(tiled.get_slice(",", 1)))
	_check(await _until(func(): return GameState.grid("farm").is_tilled(tile), 5.0), "tilled soil replicated at %s" % tile)
	_check(bool(GameState.grid("farm").soil_at(tile).get("watered", false)), "watering replicated")
	_check(await _until(func(): return GameState.money() == money0 + 123, 5.0), "shared money replicated (%d -> %d)" % [money0, GameState.money()])

	var party0 := me.party.size()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var c := Creature.create("sproutle", 4, rng)
	Coop.act("befriend_act", [JSON.stringify(c.to_dict())])
	_check(await _until(func(): return GameState.local_player().party.size() == party0 + 1 or GameState.find_creature(c.uid) != null, 5.0), "befriended Wildling filed by the host")

	var mine: Dictionary = {}
	for e: Dictionary in GameState.local_player().inventory.all_entries():
		if Data.get_item(str(e.id)).get("cat", "") != "tool":
			mine = e
			break
	_check(not mine.is_empty(), "have something to trade")
	var pars0 := GameState.local_player().inventory.count("parsnip")
	Coop.trade_op("open", {"to": "local"})
	_check(await _until(func(): return str(_trade.get("status", "")) == "open", 5.0), "host joined the trade")
	Coop.trade_op("offer", {"tid": int(_trade.tid), "offer": [{"kind": "item", "uid": mine.uid, "n": 1}]})
	_check(await _until(func(): return not _trade.get("offer", {}).get("local", []).is_empty(), 5.0), "host put up an offer")
	Coop.trade_op("ready", {"tid": int(_trade.tid)})
	_check(await _until(func(): return str(_trade.get("status", "")) == "done", 5.0), "trade completed")
	_check(await _until(func(): return GameState.local_player().inventory.count("parsnip") == pars0 + 1, 5.0), "received the host's parsnip")

	Coop.request_sleep()
	Coop.send_chat("sleeping")
	_check(await _until(func(): return GameState.day() == day0 + 1, 10.0), "slept through to the next day together")
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
