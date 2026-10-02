extends Node
## Headless co-op visitor used by coop_smoke: joins over LAN, accepts trades and friendly
## battles, and plays its turns (first move, first healthy replacement).

var _view: BattleEngine
var _host := "local"

func _ready() -> void:
	var port := Net.ENET_PORT
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.substr(7))
	Net.account_id = "bot"
	Net.display_name = "Mossy"
	Coop.trade_invited.connect(func(tid: int, _n: String): Coop.trade_op("join", {"tid": tid}))
	Coop.trade_updated.connect(_on_trade)
	Coop.pvp_challenge.connect(func(from_pid: String, _n: String): Coop.accept_challenge(from_pid))
	Coop.pvp_started.connect(_on_pvp)
	Coop.pvp_action.connect(_on_pvp_msg)
	Net.coop_ended.connect(func(_r: String): get_tree().quit())
	Net.join_lan("127.0.0.1", port)
	await get_tree().create_timer(150.0).timeout
	get_tree().quit()

func _on_trade(s: Dictionary) -> void:
	if str(s.status) != "open" or not s.offer.get("bot", []).is_empty():
		return
	var p := GameState.local_player()
	for e: Dictionary in p.inventory.all_entries():
		if Data.get_item(str(e.id)).get("cat", "") != "tool":
			Coop.trade_op("offer", {"tid": int(s.tid), "offer": [{"kind": "item", "uid": e.uid, "n": mini(3, int(e.n))}]})
			return

func _on_pvp(s: Dictionary) -> void:
	_host = str(s.opponent)
	var mine: Array = []
	for c: Creature in GameState.local_player().party:
		mine.append(Creature.from_dict(c.to_dict()))
	var theirs: Array = []
	for d in s.team:
		theirs.append(Creature.from_dict(d))
	_view = BattleEngine.new(mine, theirs, BattleEngine.Kind.PVP, int(s.seed), str(s.name), "Mossy")

func _on_pvp_msg(m: Dictionary) -> void:
	match str(m.get("op", "")):
		"ev":
			if _view:
				_view.apply_snapshot(m.st, true)
		"turn":
			Coop.send_pvp_action(_host, {"op": "act", "a": {"k": "move", "i": 0}})
		"force":
			Coop.send_pvp_action(_host, {"op": "force", "i": _view.sides[0].first_alive() if _view else 0})
