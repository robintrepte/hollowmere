class_name QuestFlow
extends Node
## Runs the local player's quests: hands out dailies, moves steps on, pays out finished quests,
## lets villagers offer and take in quests, and counts steps walked, maps visited and battles won.
## Owned by the Controller.

var ctl: Controller
var _queued := false
var _last_tile := Vector2i(-9999, -9999)
var _tile_t := 0.0
var _claiming: Dictionary = {}
var _arrow: QuestArrow
var _target := Vector2.INF

func _init(c: Controller) -> void:
	ctl = c

func _ready() -> void:
	EventBus.quest_updated.connect(queue_check)
	EventBus.inventory_changed.connect(queue_check)
	EventBus.party_changed.connect(queue_check)
	EventBus.story_advanced.connect(func(_c): queue_check())
	EventBus.map_changed.connect(_on_map)
	EventBus.battle_finished.connect(_on_battle)
	TimeService.tick.connect(queue_check)
	var layer := CanvasLayer.new()
	layer.layer = 9
	add_child(layer)
	_arrow = QuestArrow.new()
	layer.add_child(_arrow)
	queue_check()

func _p() -> PlayerData:
	return GameState.local_player()

func queue_check() -> void:
	if not _queued:
		_queued = true
		_check.call_deferred()

func _check() -> void:
	_queued = false
	var p := _p()
	if not GameState.started or p == null:
		return
	var now := TimeService.now()
	var changed := false
	if Quests.roll_daily(p, GameState.world, now):
		EventBus.toast.emit(tr("New daily quests are on your list."), "book")
		changed = true
	var st := Quests.state(p)
	if st.tutorial == "playing" and Quests.next_tutorial(p, now) != "":
		changed = true
	for ev in Quests.update(p, GameState.world, now):
		changed = true
		if ev.event == "step":
			EventBus.toast.emit(tr("%s: %s") % [Quests.title(p, ev.qid), InputHints.fill(Quests.step_text(p, ev.qid))], "book")
	var batch := Quests.unclaimed(p).filter(func(q): return not _claiming.has(q))
	var quiet := batch.size() > 2
	var total := {}
	for qid in batch:
		changed = true
		_claiming[qid] = true
		var got := await _claim(qid, quiet)
		_claiming.erase(qid)
		for k in got:
			if got[k] is int or got[k] is float:
				total[k] = int(total.get(k, 0)) + int(got[k])
	if quiet and not total.is_empty():
		Audio.sfx("levelup")
		EventBus.toast.emit(tr("%d quests complete · %s") % [batch.size(), reward_text(total)], "star")
	if changed:
		EventBus.quest_updated.emit()
	refresh_markers()

func refresh_markers() -> void:
	for n in get_tree().get_nodes_in_group("npcs"):
		if n is Npc and n.vid != "":
			n.set_marker(marker_for(n.vid))

## Pays out one quest; returns its reward. Quiet claims leave the toast to the caller.
func _claim(qid: String, quiet: bool = false) -> Dictionary:
	var p := _p()
	var title := Quests.title(p, qid)
	var r: Dictionary = await Coop.act_async("claim_quest_act", [qid])
	if not r.get("ok", false):
		return {}
	var reward: Dictionary = r.get("reward", Quests.reward_of(p, qid))
	if not quiet:
		Audio.sfx("levelup")
		var text := reward_text(reward)
		EventBus.toast.emit(tr("Quest complete: %s") % title + (" · " + text if text != "" else ""), "star")
	if r.has("bonus"):
		EventBus.toast.emit(tr("%d-day daily streak! Bonus: %s") % [int(r.streak), reward_text(r.bonus)], "star")
	if Quests.state(p).tutorial == "playing":
		Quests.next_tutorial(p, TimeService.now())
	return reward

static func reward_text(reward: Dictionary) -> String:
	var bits: Array = []
	for k in reward:
		match k:
			"money":
				bits.append(CoinLabel.text(int(reward[k])))
			"friendship":
				for vid in reward[k]:
					bits.append(TranslationServer.translate("♥ %s") % Data.villager_name(vid))
			"recipe":
				bits.append(TranslationServer.translate("Recipe: %s") % Data.item_name(str(reward[k])))
			"skill_points":
				bits.append(TranslationServer.translate("%d skill points") % int(reward[k]))
			"chips":
				bits.append(TranslationServer.translate("%d chips") % int(reward[k]))
			"emote", "flag":
				pass
			_:
				if Data.has_item(k):
					bits.append(TranslationServer.translate("%d %s") % [int(reward[k]), Data.item_name(k)])
	return ", ".join(bits)

# --- Villagers ------------------------------------------------------------------------

## Hand-ins first, then a new quest offer. Returns true if the talk was about quests.
func talk(vid: String) -> bool:
	var p := _p()
	var now := TimeService.now()
	var name := Data.villager_name(vid)
	var finished := Quests.talk(p, GameState.world, vid, now)
	if not finished.is_empty():
		for f in finished:
			var lines: Array = f.lines if not f.lines.is_empty() else [tr("Thank you, that's a big help!")]
			await ctl.ui.say(lines, name, Art.portrait(vid))
		Audio.sfx("sparkle")
		EventBus.inventory_changed.emit()
		queue_check()
		return true
	var offers := Quests.offers(p, GameState.world, now, vid).filter(func(q): return not _snoozed(p, q))
	if offers.is_empty():
		return false
	var qid: String = offers[0]
	var d: Dictionary = Data.quests[qid]
	var intro: Array = d.get("intro", [])
	if intro.is_empty():
		intro = [tr("Got a moment? I could use your help with something.")]
	await ctl.ui.say(intro, name, Art.portrait(vid))
	var first := Quests.format_step(d.steps[0])
	var c: int = await ctl.ui.ask(tr("%s: %s") % [tr(str(d.title)), first], [tr("Accept"), tr("Not now")], name, Art.portrait(vid))
	if c == 0:
		Quests.start(p, qid, now)
		EventBus.toast.emit(tr("New quest: %s") % tr(str(d.title)), "book")
		Audio.sfx("sparkle")
		EventBus.quest_updated.emit()
	else:
		Quests.state(p)["snooze"] = Quests.state(p).get("snooze", {})
		Quests.state(p).snooze[qid] = GameState.day()
	return true

func _snoozed(p: PlayerData, qid: String) -> bool:
	return int(Quests.state(p).get("snooze", {}).get(qid, -1)) == GameState.day()

## "!" when a villager has a quest for the player, "?" when something is ready to hand in.
func marker_for(vid: String) -> String:
	var p := _p()
	if p == null or not GameState.started:
		return ""
	if Quests.turn_in_ready(p, vid):
		return "?"
	var offers := Quests.offers(p, GameState.world, TimeService.now(), vid).filter(func(q): return not _snoozed(p, q))
	return "!" if not offers.is_empty() else ""

# --- Counters -------------------------------------------------------------------------

## World position of the first tracked quest's target on this map (a villager or a spot).
func _find_target(p: PlayerData) -> Vector2:
	for qid in Quests.state(p).tracked:
		var t := Quests.target(p, qid)
		if t.is_empty():
			continue
		if t.has("vid") and ctl.world and ctl.world.npcs.has(t.vid):
			return ctl.world.npcs[t.vid].position
		if t.has("tile") and str(t.map) == p.map_id:
			return GameState.tile_center(t.tile)
	return Vector2.INF

func _on_map(map_id: String) -> void:
	var p := _p()
	if p == null:
		return
	p.stat_add("visit:" + map_id)
	queue_check()

func _on_battle(res: Dictionary) -> void:
	var p := _p()
	if p and str(res.get("result", "")) in ["win", "pvp_win"]:
		p.stat_add("win_battle")
		queue_check()

func _process(delta: float) -> void:
	_tile_t += delta
	if ctl.player == null or not GameState.started:
		_arrow.visible = false
		return
	_arrow.point_at(_target, ctl.player.get_viewport())
	if _tile_t < 0.25:
		return
	_tile_t = 0.0
	var p := _p()
	_target = _find_target(p)
	var t := GameState.to_tile(ctl.player.position)
	if t == _last_tile:
		return
	if _last_tile.x > -9999:
		p.stat_add("walk")
	_last_tile = t
	if Quests.at_tile(p, p.map_id, t):
		queue_check()
	elif int(p.stats.get("walk", 0)) % 5 == 0:
		queue_check()


## A small arrow at the screen edge pointing at a tracked quest's target when it is off screen.
class QuestArrow extends Control:
	var _dir := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		visible = false
		size = Vector2(18, 18)
		pivot_offset = size / 2.0

	func point_at(world_pos: Vector2, vp: Viewport) -> void:
		if world_pos == Vector2.INF:
			visible = false
			return
		var view := vp.get_visible_rect().size
		var screen := vp.get_canvas_transform() * world_pos
		var inner := Rect2(Vector2(28, 28), view - Vector2(56, 56))
		if inner.has_point(screen):
			visible = false
			return
		var center := view / 2.0
		var d := (screen - center).normalized()
		var reach := minf(absf((inner.size.x / 2.0) / d.x) if d.x != 0.0 else INF, absf((inner.size.y / 2.0) / d.y) if d.y != 0.0 else INF)
		position = center + d * reach - size / 2.0
		rotation = d.angle()
		visible = true
		queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var pts := PackedVector2Array([c + Vector2(9, 0), c + Vector2(-6, -7), c + Vector2(-3, 0), c + Vector2(-6, 7)])
		draw_colored_polygon(pts, UITheme.COIN)
		draw_polyline(pts + PackedVector2Array([pts[0]]), UITheme.OUTLINE, 1.5)
