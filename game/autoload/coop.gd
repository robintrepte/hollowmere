extends Node
## Co-op replication. Host = authority for world (tiles, money, time, ranch, chest).
## Each client is authority for its own position; its PlayerData lives on the host and
## is mirrored back after every action. All world actions go through `act()`.

signal snapshot_loaded()
signal remote_moved(pid: String, map_id: String, pos: Vector2, facing: Vector2, moving: bool)
signal remote_left(pid: String)
signal act_result(result: Dictionary)

const CHUNK := 3000
const ACTIONS := ["use_tool", "use_item", "harvest_at", "load_machine", "ship", "eat", "pick_up_object", "buy", "sell",
	"craft", "construct", "upgrade_tool", "buy_backpack", "equip_backpack", "deliver_board", "set_pair_act", "clear_pair_act", "incubate", "set_job_act", "move_creature_act",
	"befriend_act", "dex_seen_act", "reward_act", "warden_won_act", "guardian_result_act", "legend_result_act",
	"mine_floor_act", "open_treasure_act", "festival_act", "story_seen_act", "chain_act", "show_act", "rematch_won_act", "claim_quest_act",
	"invest_skill_act", "respec_skills_act", "fish_cast_act", "fish_result_act", "equip_tackle_act", "unequip_tackle_act", "upgrade_rod_act", "first_gift_act",
	"deep_enter_act", "deep_boss_act", "crack_geode_act", "donate_museum_act", "enchant_act", "anvil_act", "grindstone_act", "battle_spoils_act"]

var _chunks: Dictionary = {}       # transfer id -> Array
var _ready_to_sleep: Dictionary = {}
var _dirty_player := false
var _pos_timer := 0.0
var _push_timer := 0.0
var _meta_dirty := false
var _meta_timer := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	EventBus.tile_changed.connect(_on_tile_changed)
	EventBus.objects_changed.connect(_on_objects_changed)
	EventBus.money_changed.connect(func(_m, _d): _broadcast_world())
	EventBus.time_changed.connect(func(m): if m % 30 == 0: _broadcast_world())
	EventBus.day_started.connect(_on_day_started)
	EventBus.inventory_changed.connect(func(): _dirty_player = true)
	EventBus.party_changed.connect(func(): _meta_dirty = true; _dirty_player = true)
	EventBus.quest_updated.connect(func(): _meta_dirty = true)
	Net.peer_left.connect(func(pid): remote_left.emit(pid); _cancel_trades_of(pid))
	Net.chat_received.connect(func(from_name: String, text: String):
		if from_name != (GameState.local_player().name if GameState.local_player() else ""):
			EventBus.toast.emit("%s: %s" % [from_name, text], "chat"))

# --- Actions --------------------------------------------------------------------------

## Performs a world action as the local player. Offline/host: immediate result.
func act(action: String, args: Array) -> Dictionary:
	assert(action in ACTIONS)
	if Net.is_authority():
		_meta_dirty = true
		return GameState.callv(action, [Net.local_id()] + args)
	_flush_player()
	rpc_id(1, "req", action, args)
	return {"ok": true, "pending": true, "fx": [], "sfx": "", "reason": ""}

@rpc("any_peer", "reliable")
func req(action: String, args: Array) -> void:
	if not Net.is_authority() or not action in ACTIONS:
		return
	var sender := multiplayer.get_remote_sender_id()
	var pid := _pid_of(sender)
	if pid == "":
		return
	var res: Dictionary = GameState.callv(action, [pid] + args)
	var p := GameState.player(pid)
	rpc_id(sender, "result", _plain(res), JSON.stringify(p.to_dict()))
	_meta_dirty = true

@rpc("authority", "reliable")
func result(res: Dictionary, player_json: String) -> void:
	_apply_player(player_json)
	act_result.emit(res)

## Like act(), but a client waits for the host's answer (results arrive in request order).
func act_async(action: String, args: Array) -> Dictionary:
	var r := act(action, args)
	if r.get("pending", false):
		r = await act_result
	return r

func _plain(res: Dictionary) -> Dictionary:
	var fx: Array = []
	for f in res.get("fx", []):
		fx.append([f[0], (f[1] as Color).to_html()])
	var out := res.duplicate(true)
	out.fx = fx
	return out

func _pid_of(peer_id: int) -> String:
	return Net.peers.get(peer_id, {}).get("pid", "")

# --- Join handshake + snapshots ------------------------------------------------------------

@rpc("any_peer", "reliable")
func hello(pid: String, pname: String) -> void:
	if not Net.is_authority():
		return
	var sender := multiplayer.get_remote_sender_id()
	Net.peers[sender] = {"pid": pid, "name": pname}
	GameState.ensure_player(pid, pname)
	_send_snapshot(sender)
	Net.peer_joined.emit(pid, pname)
	EventBus.toast.emit("%s joined your farm!" % pname, "coop")
	broadcast_roster()

func broadcast_roster() -> void:
	if Net.mode != "host":
		return
	var r := {1: {"pid": "local", "name": GameState.local_player().name}}
	for k in Net.peers:
		r[k] = Net.peers[k]
	rpc("roster", r)

@rpc("authority", "reliable")
func roster(r: Dictionary) -> void:
	Net.peers.clear()
	var me := multiplayer.get_unique_id()
	for k in r:
		if int(k) != me:
			Net.peers[int(k)] = r[k]

func _send_snapshot(peer_id: int) -> void:
	var raw := JSON.stringify(GameState.to_dict()).to_utf8_buffer()
	var packed := raw.compress(FileAccess.COMPRESSION_GZIP)
	var tid := randi()
	var n := int(ceil(float(packed.size()) / CHUNK))
	for i in n:
		rpc_id(peer_id, "snapshot_chunk", tid, i, n, raw.size(), packed.slice(i * CHUNK, mini(packed.size(), (i + 1) * CHUNK)))

@rpc("authority", "reliable")
func snapshot_chunk(tid: int, i: int, n: int, raw_size: int, data: PackedByteArray) -> void:
	if not _chunks.has(tid):
		_chunks[tid] = []
		_chunks[tid].resize(n)
	_chunks[tid][i] = data
	for c in _chunks[tid]:
		if c == null:
			return
	var all := PackedByteArray()
	for c in _chunks[tid]:
		all.append_array(c)
	_chunks.erase(tid)
	var txt := all.decompress(raw_size, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	var d = JSON.parse_string(txt)
	if d is Dictionary:
		var keep_pos := Vector2.INF
		var keep_map := ""
		var lp := GameState.local_player()
		if GameState.started and lp and lp.id == Net.local_id():
			keep_pos = lp.pos
			keep_map = lp.map_id
		GameState.from_dict(d)
		if keep_pos != Vector2.INF and GameState.local_player():
			GameState.local_player().pos = keep_pos
			GameState.local_player().map_id = keep_map
		Net.coop_started.emit(false)
		snapshot_loaded.emit()

# --- World replication -------------------------------------------------------------------------

func _on_tile_changed(map_id: String, t: Vector2i) -> void:
	if Net.mode != "host" or not (map_id in GameState.PERSISTENT_MAPS or map_id.begins_with("deep:") or map_id.begins_with("mine:")):
		return
	var g := GameState.grid(map_id)
	var k := Tiles.key(t)
	rpc("tile_sync", map_id, k, g.get_ground(t), g.get_deco(t), JSON.stringify(g.soil.get(k, null)), JSON.stringify(g.objects.get(k, null)))

@rpc("authority", "reliable")
func tile_sync(map_id: String, k: String, ground: int, deco: int, soil_json: String, obj_json: String) -> void:
	var g := GameState.grid(map_id)
	var t := Tiles.parse_key(k)
	if not g.in_bounds(t):
		return
	g.ground[g.idx(t)] = ground
	g.deco[g.idx(t)] = deco
	var s = JSON.parse_string(soil_json)
	if s is Dictionary:
		if s.has("crop"):
			FarmGrid.fix_crop_types(s.crop)
		g.soil[k] = s
	else:
		g.soil.erase(k)
	var o = JSON.parse_string(obj_json)
	if o is Dictionary:
		g.objects[k] = o
	else:
		g.objects.erase(k)
	EventBus.tile_changed.emit(map_id, t)

func _on_objects_changed(map_id: String) -> void:
	if Net.mode != "host" or not map_id in GameState.PERSISTENT_MAPS:
		return
	var g := GameState.grid(map_id)
	rpc("objects_sync", map_id, JSON.stringify(g.objects))

@rpc("authority", "reliable")
func objects_sync(map_id: String, json: String) -> void:
	var d = JSON.parse_string(json)
	if d is Dictionary:
		GameState.grid(map_id).objects = d
		EventBus.objects_changed.emit(map_id)

func _broadcast_world() -> void:
	if Net.mode != "host":
		return
	var w := GameState.world
	rpc("world_sync", int(w.money), int(w.minute), int(w.day), String(w.weather))

@rpc("authority", "unreliable_ordered")
func world_sync(money_v: int, minute_v: int, day_v: int, weather: String) -> void:
	var w := GameState.world
	var dm := money_v - int(w.money)
	w.money = money_v
	w.minute = minute_v
	w.weather = weather
	if dm != 0:
		EventBus.money_changed.emit(money_v, dm)
	EventBus.time_changed.emit(minute_v)

func _on_day_started(_d: int, _report: Dictionary) -> void:
	_ready_to_sleep.clear()
	if Net.mode == "host":
		for peer_id in Net.peers:
			_send_snapshot(peer_id)

# --- Sleeping together -----------------------------------------------------------------------

func request_sleep() -> void:
	if not Net.is_online():
		GameState.end_day(false)
		return
	if Net.is_authority():
		_mark_sleep(Net.local_id())
	else:
		_flush_player()
		rpc_id(1, "sleep_ready")

@rpc("any_peer", "reliable")
func sleep_ready() -> void:
	_mark_sleep(_pid_of(multiplayer.get_remote_sender_id()))

func _mark_sleep(pid: String) -> void:
	_ready_to_sleep[pid] = true
	var total := Net.peers.size() + 1
	if _ready_to_sleep.size() >= total:
		GameState.end_day(false)
	else:
		rpc("sleep_status", _ready_to_sleep.size(), total)
		EventBus.toast.emit("Waiting for others to go to bed (%d/%d)" % [_ready_to_sleep.size(), total], "zzz")

@rpc("authority", "reliable")
func sleep_status(n: int, total: int) -> void:
	EventBus.toast.emit("Waiting for others to go to bed (%d/%d)" % [n, total], "zzz")

# --- Player state + movement ---------------------------------------------------------------------

func _flush_player() -> void:
	if Net.mode != "client" or not _dirty_player:
		return
	_dirty_player = false
	var p := GameState.local_player()
	if p:
		rpc_id(1, "push_player", JSON.stringify(p.to_dict()))

@rpc("any_peer", "reliable")
func push_player(json: String) -> void:
	if not Net.is_authority():
		return
	var pid := _pid_of(multiplayer.get_remote_sender_id())
	var d = JSON.parse_string(json)
	if pid == "" or not d is Dictionary:
		return
	var p := PlayerData.from_dict(d)
	p.id = pid
	GameState.players[pid] = p

func _apply_player(json: String) -> void:
	var d = JSON.parse_string(json)
	if not d is Dictionary:
		return
	var old := GameState.local_player()
	var p := PlayerData.from_dict(d)
	if old:
		p.pos = old.pos
		p.map_id = old.map_id
		p.selected = old.selected
	GameState.players[p.id] = p
	EventBus.inventory_changed.emit()
	EventBus.energy_changed.emit(p.energy, p.energy_cap())
	_dirty_player = false

func _process(delta: float) -> void:
	if not Net.is_online() or not GameState.started:
		return
	_push_timer += delta
	if _push_timer > 5.0:
		_push_timer = 0.0
		_flush_player()
	if Net.mode == "host" and _meta_dirty:
		_meta_timer += delta
		if _meta_timer > 0.4:
			_meta_timer = 0.0
			_meta_dirty = false
			_broadcast_meta()

# --- Farm-level state (ranch, chest, dex, buildings, quests) ---------------------------------

func _broadcast_meta() -> void:
	if Net.peers.is_empty():
		return
	var d := GameState.to_dict()
	d.erase("grids")
	d.erase("players")
	var raw := JSON.stringify(d).to_utf8_buffer()
	rpc("meta_sync", raw.size(), raw.compress(FileAccess.COMPRESSION_GZIP))

@rpc("authority", "reliable")
func meta_sync(raw_size: int, data: PackedByteArray) -> void:
	var d = JSON.parse_string(data.decompress(raw_size, FileAccess.COMPRESSION_GZIP).get_string_from_utf8())
	if d is Dictionary and GameState.started:
		GameState.apply_meta(d)

## Called by the local player node ~10x per second.
func send_position(map_id: String, pos: Vector2, facing: Vector2, moving: bool) -> void:
	if not Net.is_online():
		return
	rpc("pos_sync", Net.local_id(), map_id, pos, facing, moving)

@rpc("any_peer", "unreliable_ordered")
func pos_sync(pid: String, map_id: String, pos: Vector2, facing: Vector2, moving: bool) -> void:
	var p := GameState.player(pid)
	if p:
		p.pos = pos
		p.map_id = map_id
	remote_moved.emit(pid, map_id, pos, facing, moving)

# --- Chat + trades ------------------------------------------------------------------------------------

func send_chat(text: String) -> void:
	text = text.strip_edges().substr(0, 200)
	if text == "":
		return
	var nm := GameState.local_player().name
	Net.chat_received.emit(nm, text)
	if Net.is_online():
		rpc("chat", nm, text)

@rpc("any_peer", "reliable")
func chat(from_name: String, text: String) -> void:
	Net.chat_received.emit(from_name, text.substr(0, 200))

## Gift/trade an item or Wildling to another player (host applies).
func send_gift(to_pid: String, kind: String, ref: String, n: int) -> void:
	if Net.is_authority():
		_do_gift(Net.local_id(), to_pid, kind, ref, n)
	else:
		_flush_player()
		rpc_id(1, "gift_req", to_pid, kind, ref, n)

@rpc("any_peer", "reliable")
func gift_req(to_pid: String, kind: String, ref: String, n: int) -> void:
	var from := _pid_of(multiplayer.get_remote_sender_id())
	if from != "":
		_do_gift(from, to_pid, kind, ref, n)

func _do_gift(from_pid: String, to_pid: String, kind: String, ref: String, n: int) -> void:
	var a := GameState.player(from_pid)
	var b := GameState.player(to_pid)
	if a == null or b == null:
		return
	var label := ""
	if kind == "item":
		var f := a.inventory.find(ref)
		if f.is_empty():
			return
		var e: Dictionary = f.inv.take(ref, mini(n, int(f.entry.n)))
		GameState.give_item(b, e.id, int(e.n), int(e.q), e.meta)
		label = "%d %s" % [int(e.n), Data.item_name(e.id)]
	elif kind == "creature":
		var c := GameState.find_creature(ref)
		if c == null or not c in a.party or a.party.size() <= 1:
			return
		a.party.erase(c)
		GameState.add_creature(b, c)
		label = c.display_name()
	_sync_player(from_pid)
	_sync_player(to_pid)
	_notify(to_pid, tr("%s sent you %s!") % [a.name, label])

func _sync_player(pid: String) -> void:
	for peer_id in Net.peers:
		if Net.peers[peer_id].pid == pid:
			rpc_id(peer_id, "result", {"ok": true, "fx": [], "sfx": "", "reason": ""}, JSON.stringify(GameState.player(pid).to_dict()))
	if pid == Net.local_id():
		EventBus.inventory_changed.emit()
		EventBus.party_changed.emit()

func _notify(pid: String, text: String) -> void:
	if pid == Net.local_id():
		EventBus.toast.emit(text, "gift")
		return
	for peer_id in Net.peers:
		if Net.peers[peer_id].pid == pid:
			rpc_id(peer_id, "notify", text)

@rpc("authority", "reliable")
func notify(text: String) -> void:
	EventBus.toast.emit(text, "gift")

# --- Friendly battles (PvP) ------------------------------------------------------------------------
## The challenger's machine runs the battle engine; the opponent sends moves.

signal pvp_challenge(from_pid: String, from_name: String)
signal pvp_action(action: Dictionary)
signal pvp_started(setup: Dictionary)

func challenge(to_pid: String) -> void:
	for peer_id in _peer_ids_for(to_pid):
		rpc_id(peer_id, "pvp_invite", Net.local_id(), GameState.local_player().name)

@rpc("any_peer", "reliable")
func pvp_invite(from_pid: String, from_name: String) -> void:
	pvp_challenge.emit(from_pid, from_name)

func decline_challenge(from_pid: String) -> void:
	for peer_id in _peer_ids_for(from_pid):
		rpc_id(peer_id, "notify", tr("%s can't battle right now.") % GameState.local_player().name)

func accept_challenge(from_pid: String) -> void:
	var team: Array = []
	for c in GameState.local_player().party:
		team.append(c.to_dict())
	for peer_id in _peer_ids_for(from_pid):
		rpc_id(peer_id, "pvp_accept", Net.local_id(), GameState.local_player().name, JSON.stringify(team))

@rpc("any_peer", "reliable")
func pvp_accept(pid: String, pname: String, team_json: String) -> void:
	var arr = JSON.parse_string(team_json)
	if not arr is Array:
		return
	var seed_v := randi()
	pvp_started.emit({"opponent": pid, "name": pname, "team": arr, "seed": seed_v, "host_side": true})
	var my_team: Array = []
	for c in GameState.local_player().party:
		my_team.append(c.to_dict())
	for peer_id in _peer_ids_for(pid):
		rpc_id(peer_id, "pvp_begin", Net.local_id(), GameState.local_player().name, JSON.stringify(my_team), seed_v)

@rpc("any_peer", "reliable")
func pvp_begin(pid: String, pname: String, team_json: String, seed_v: int) -> void:
	var arr = JSON.parse_string(team_json)
	if arr is Array:
		pvp_started.emit({"opponent": pid, "name": pname, "team": arr, "seed": seed_v, "host_side": false})

## Both sides run the same deterministic engine with the same seed and exchange choices.
func send_pvp_action(to_pid: String, action: Dictionary) -> void:
	for peer_id in _peer_ids_for(to_pid):
		rpc_id(peer_id, "pvp_act", action)

@rpc("any_peer", "reliable")
func pvp_act(action: Dictionary) -> void:
	pvp_action.emit(action)

func _peer_ids_for(pid: String) -> Array:
	var out: Array = []
	if Net.mode == "client":
		# Clients route through the server peer id (1) when the target is the host.
		if pid == "local":
			return [1]
	for peer_id in Net.peers:
		if Net.peers[peer_id].pid == pid:
			out.append(peer_id)
	if out.is_empty() and Net.mode == "client":
		out.append(1)
	return out

# --- Trades (host arbitrates; both players offer, both confirm, host swaps atomically) ---------

signal trade_invited(tid: int, from_name: String)
signal trade_updated(state: Dictionary)

var _trades: Dictionary = {}   # host only: tid -> state

## Sends a trade operation to the host (or handles it locally when we are the host).
func trade_op(op: String, data: Dictionary = {}) -> void:
	if Net.is_authority():
		_trade_op(Net.local_id(), op, data)
	else:
		_flush_player()
		rpc_id(1, "trade_op_rpc", op, JSON.stringify(data))

@rpc("any_peer", "reliable")
func trade_op_rpc(op: String, json: String) -> void:
	var pid := _pid_of(multiplayer.get_remote_sender_id())
	var d = JSON.parse_string(json)
	if Net.is_authority() and pid != "" and d is Dictionary:
		_trade_op(pid, op, d)

func _trade_op(pid: String, op: String, d: Dictionary) -> void:
	if op == "open":
		var to := str(d.get("to", ""))
		if GameState.player(to) == null or to == pid:
			return
		var tid := randi() % 1000000000
		_trades[tid] = {"tid": tid, "a": pid, "b": to, "a_name": GameState.player(pid).name, "b_name": GameState.player(to).name,
			"offer": {pid: [], to: []}, "ok": {pid: false, to: false}, "status": "invite", "msg": ""}
		_send_trade(tid)
		if to == Net.local_id():
			trade_invited.emit(tid, GameState.player(pid).name)
		else:
			for peer_id in _peer_ids_for(to):
				rpc_id(peer_id, "trade_invite", tid, GameState.player(pid).name)
		return
	var tid2 := int(d.get("tid", -1))
	var t: Dictionary = _trades.get(tid2, {})
	if t.is_empty() or not pid in [t.a, t.b]:
		return
	match op:
		"join":
			if pid == t.b:
				t.status = "open"
		"offer":
			var offer: Array = d.get("offer", [])
			var err := GameState.validate_offer(GameState.player(pid), offer)
			if err != "":
				t.msg = err
			else:
				t.offer[pid] = offer.slice(0, 9)
				t.msg = ""
			t.ok[t.a] = false
			t.ok[t.b] = false
		"ready":
			t.ok[pid] = bool(d.get("on", true))
			if t.ok[t.a] and t.ok[t.b]:
				var a := GameState.player(t.a)
				var b := GameState.player(t.b)
				var err2 := GameState.execute_trade(a, t.offer[t.a], b, t.offer[t.b])
				if err2 == "":
					t.status = "done"
					_sync_player(t.a)
					_sync_player(t.b)
					_meta_dirty = true
				else:
					t.msg = err2
					t.ok[t.a] = false
					t.ok[t.b] = false
		"cancel":
			t.status = "closed"
			t.msg = tr("%s closed the trade.") % GameState.player(pid).name
	_send_trade(tid2)
	if t.status in ["done", "closed"]:
		_trades.erase(tid2)

func _send_trade(tid: int) -> void:
	var t: Dictionary = _trades[tid]
	var view := t.duplicate(true)
	view["views"] = {}
	for pid in [t.a, t.b]:
		view.views[pid] = _describe_offer(GameState.player(pid), t.offer[pid])
	for pid in [t.a, t.b]:
		if pid == Net.local_id():
			trade_updated.emit(view)
		else:
			for peer_id in _peer_ids_for(pid):
				rpc_id(peer_id, "trade_state", JSON.stringify(view))

## Human-readable lines (with icons) for an offer, built on the host where the items live.
func _describe_offer(p: PlayerData, offer: Array) -> Array:
	var out: Array = []
	for o: Dictionary in offer:
		if o.kind == "item":
			var f := p.inventory.find(str(o.uid))
			if not f.is_empty():
				out.append({"icon": "item", "id": f.entry.id, "text": "%s x%d" % [Data.item_name(f.entry.id), int(o.n)]})
		else:
			var c := GameState.find_creature(str(o.uid))
			if c:
				out.append({"icon": "creature", "id": c.species_id, "text": "%s Lv%d" % [c.display_name(), c.level]})
	return out

@rpc("authority", "reliable")
func trade_invite(tid: int, from_name: String) -> void:
	trade_invited.emit(tid, from_name)

@rpc("any_peer", "reliable")
func trade_state(json: String) -> void:
	var d = JSON.parse_string(json)
	if d is Dictionary:
		d.tid = int(d.tid)
		trade_updated.emit(d)

func _cancel_trades_of(pid: String) -> void:
	for tid in _trades.keys():
		var t: Dictionary = _trades[tid]
		if pid in [t.a, t.b]:
			t.status = "closed"
			t.msg = tr("The other player left.")
			_send_trade(tid)
			_trades.erase(tid)

## Everyone else currently connected: [{pid, name}].
func online_players() -> Array:
	var out: Array = []
	for peer_id in Net.peers:
		var info: Dictionary = Net.peers[peer_id]
		if info.pid != Net.local_id():
			out.append({"pid": info.pid, "name": info.name})
	return out
