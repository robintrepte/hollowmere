extends Node
## Talks to the hosted MCP relay over Nakama. Incoming commands run through AgentTools
## and Coop.act, so an agent is just another player as far as the world is concerned.

signal command_done(id: String, result: Dictionary)
signal thought(text: String)
signal mode_changed

const POLL := 1.0
const MAX_AGENTS := 3

var tokens: Array = []          ## [{id, name, scopes, expires}]
var last_thought := ""
var last_actions: Array = []
var spectator := false
var _poll_t := 0.0
var _busy := false
var partners: Dictionary = {}   ## pid -> Player node
var _walk: Array = []
var _walk_player: Player

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Net.session_changed.connect(func(on: bool):
		if on:
			refresh_tokens()
		else:
			tokens.clear())

func has_agents() -> bool:
	return not partners.is_empty() or spectator

func _process(delta: float) -> void:
	_step_walk(delta)
	if spectator and OS.get_name() == "Web":
		# Background tabs throttle rAF; keep a heartbeat so catch-up still runs.
		pass
	_poll_t -= delta
	if _poll_t > 0.0 or _busy or not Net.has_session() or not GameState.started:
		return
	_poll_t = POLL
	_take()

func _take() -> void:
	_busy = true
	var res: Dictionary = await Net.call_rpc("agent_take", {})
	_busy = false
	if res.has("error") or res.get("cmds", []).is_empty():
		return
	for cmd in res.cmds:
		await handle(cmd)

## Runs one MCP command (also used by the in-game panel and tests).
func handle(cmd: Dictionary) -> Dictionary:
	var tool := str(cmd.get("tool", cmd.get("name", "")))
	var raw = cmd.get("args", cmd.get("arguments", {}))
	var args: Dictionary = {}
	if raw is Dictionary:
		args = raw
	elif raw is String:
		var parsed = JSON.parse_string(raw)
		if parsed is Dictionary:
			args = parsed
	var actor := str(cmd.get("actor", cmd.get("pid", Net.local_id())))
	var scopes: Array = cmd.get("scopes", AgentTools.SCOPES)
	var ctx := {"pid": actor, "scopes": scopes, "main": _main()}
	if tool == "narrate":
		last_thought = str(args.get("text", ""))
		thought.emit(last_thought)
	var out := AgentTools.run(tool, args, ctx)
	if out.get("pending", "") != "":
		out = await _run_pending(str(out.pending), args, ctx)
	_remember(tool, out)
	var cid := str(cmd.get("id", ""))
	if cid != "" and Net.has_session():
		Net.call_rpc("agent_done", {"id": cid, "result": out})
	command_done.emit(cid, out)
	return out

func _run_pending(kind: String, args: Dictionary, ctx: Dictionary) -> Dictionary:
	var main := _main()
	if main == null or main.player == null:
		return AgentTools.err("game is not open")
	var who: Player = _actor_node(str(ctx.pid), main)
	if who == null:
		return AgentTools.err("no body to steer")
	match kind:
		"walk":
			return await walk_to(who, args, main)
		"interact":
			who.interact_pressed.emit(GameState.to_tile(who.position))
			return AgentTools.ok({"interacted": true})
		"use_tool":
			var tile := _tile_arg(args, who)
			who.use_pressed.emit(tile)
			return AgentTools.ok({"tile": {"x": tile.x, "y": tile.y}})
		"plant", "water_area", "harvest_area":
			return await _area_work(kind, args, who, main)
		"sleep":
			EventBus.menu_requested.emit("sleep", {})
			return AgentTools.ok({"sleep": true})
		"farm_routine":
			return await _farm_routine(who, main)
		"deposit_all":
			return AgentTools.call_act("ship", [], ctx)
		"dialogue_choose":
			return AgentTools.ok({"note": "pick with the dialogue UI; the line is already on screen"})
		"battle_move", "battle_switch", "battle_item", "battle_flee":
			return _battle_act(kind, args, main)
		"mine_block", "place_block":
			who.use_pressed.emit(_tile_arg(args, who))
			return AgentTools.ok({})
	return AgentTools.err("cannot run " + kind)

func walk_to(who: Player, args: Dictionary, main: Node) -> Dictionary:
	var world: World = main.world
	if world == null:
		return AgentTools.err("no map")
	var dest := _tile_arg(args, who)
	if args.has("map") and str(args.map) != who.get("pid") and str(args.map) != "":
		var map_id := str(args.map)
		if map_id != GameState.local_player().map_id and who.local:
			EventBus.map_change_requested.emit(map_id, dest)
			await EventBus.map_changed
	var path: Array = world.path_between(GameState.to_tile(who.position), dest)
	if path.is_empty():
		return AgentTools.err("no path")
	_walk = path
	_walk_player = who
	who.locked = true
	var t := 0.0
	while _walk.size() > 0 and t < 20.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	who.locked = spectator and who.local
	return AgentTools.ok({"at": {"x": GameState.to_tile(who.position).x, "y": GameState.to_tile(who.position).y}})

func _step_walk(delta: float) -> void:
	if _walk.is_empty() or _walk_player == null or not is_instance_valid(_walk_player):
		return
	var t: Vector2i = _walk[0]
	var dest := GameState.tile_center(t)
	var step: Vector2 = dest - _walk_player.position
	if step.length() < 3.0:
		_walk.pop_front()
		return
	_walk_player.position += step.limit_length(Player.WALK_SPEED * delta)
	_walk_player.facing = step.normalized()
	_walk_player.doll.facing = _walk_player.facing
	_walk_player.doll.moving = true

func _area_work(kind: String, args: Dictionary, who: Player, main: Node) -> Dictionary:
	var center := _tile_arg(args, who)
	var r := int(args.get("r", 2))
	var n := 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var q := center + Vector2i(dx, dy)
			if kind == "harvest_area":
				var r2: Dictionary = Coop.act("harvest_at", [q])
				if r2.get("ok", false):
					n += 1
			else:
				who.use_pressed.emit(q)
				n += 1
				await get_tree().process_frame
	return AgentTools.ok({"did": n, "kind": kind})

func _farm_routine(who: Player, main: Node) -> Dictionary:
	var g: FarmGrid = GameState.grids.get(who.get("pid") if false else GameState.local_player().map_id)
	if g == null:
		g = GameState.grids.get("farm")
	var harvested := 0
	var watered := 0
	if g:
		for t in g.planted_tiles():
			if g.crop_ready(t):
				if Coop.act("harvest_at", [t]).get("ok", false):
					harvested += 1
			elif not g.soil.get(Tiles.key(t), {}).get("watered", false):
				who.use_pressed.emit(t)
				watered += 1
	return AgentTools.ok({"harvested": harvested, "watered": watered})

func _battle_act(kind: String, args: Dictionary, main: Node) -> Dictionary:
	var b: BattleScreen = main.battle
	if b == null:
		return AgentTools.err("not in a battle")
	match kind:
		"battle_move":
			b._picked.emit({"k": "move", "i": int(args.get("i", 0))})
		"battle_switch":
			b._picked.emit({"k": "switch", "i": int(args.get("i", 0))})
		"battle_item":
			b._picked.emit({"k": "item", "id": str(args.get("id", ""))})
		"battle_flee":
			b._picked.emit({"k": "run"})
	return AgentTools.ok({"did": kind})

func _tile_arg(args: Dictionary, who: Player) -> Vector2i:
	if args.has("x"):
		return Vector2i(int(args.x), int(args.get("y", 0)))
	if args.has("tile"):
		var t = args.tile
		if t is Dictionary:
			return Vector2i(int(t.get("x", 0)), int(t.get("y", 0)))
	return GameState.to_tile(who.position)

func _actor_node(pid: String, main: Node) -> Player:
	if pid == Net.local_id() or pid == "local" or pid == "":
		return main.player
	if partners.has(pid) and is_instance_valid(partners[pid]):
		return partners[pid]
	return main.remotes.get(pid)

func _main() -> Node:
	return get_tree().get_first_node_in_group("main")

func _remember(tool: String, out: Dictionary) -> void:
	last_actions.append({"tool": tool, "ok": out.get("ok", false)})
	if last_actions.size() > 12:
		last_actions.pop_front()

func set_spectator(on: bool) -> void:
	spectator = on
	var main := _main()
	if main and main.player:
		main.player.locked = on
	mode_changed.emit()

func spawn_partner(pname: String, look: Dictionary = {}) -> String:
	if partners.size() >= MAX_AGENTS:
		return ""
	if not GameState.started or not Net.is_authority():
		return ""
	var pid := "agent:%d" % (partners.size() + 1)
	while GameState.players.has(pid):
		pid = "agent:%d" % (int(pid.get_slice(":", 1)) + 1)
	var p := GameState.ensure_player(pid, pname if pname != "" else "Helper")
	if not look.is_empty():
		p.look = look
	var main := _main()
	if main == null or main.world == null:
		return pid
	var node := Player.new()
	node.pid = pid
	node.local = false
	node.world = main.world
	node.position = GameState.local_player().pos + Vector2(24, 0)
	main.world.add_child(node)
	partners[pid] = node
	mode_changed.emit()
	return pid

func dismiss_partner(pid: String) -> void:
	if partners.has(pid) and is_instance_valid(partners[pid]):
		partners[pid].queue_free()
	partners.erase(pid)
	GameState.players.erase(pid)
	mode_changed.emit()

func take_back() -> void:
	set_spectator(false)
	_walk.clear()

func refresh_tokens() -> void:
	var res: Dictionary = await Net.call_rpc("agent_list_tokens", {})
	if not res.has("error"):
		tokens = res.get("tokens", [])

func issue_token(tname: String, scopes: Array, days: int = 30) -> Dictionary:
	var res: Dictionary = await Net.call_rpc("agent_issue_token", {"name": tname, "scopes": scopes, "days": days})
	await refresh_tokens()
	return res

func revoke_token(id: String) -> void:
	await Net.call_rpc("agent_revoke_token", {"id": id})
	await refresh_tokens()
