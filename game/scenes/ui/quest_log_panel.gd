class_name QuestLogPanel
extends JournalPanel
## Quest log: the main story and active side, tutorial and seasonal quests (with tracking), the day's
## daily quests (streak, one reroll), Village Board requests, weekly challenges and finished quests.

const LOG_TABS := [["quests", "Quests"], ["daily", "Daily"], ["board", "Requests"], ["weekly", "This week"], ["done", "Completed"]]
const FILTERS := [["all", "All"], ["main", "Main"], ["side", "Side"], ["seasonal", "Seasonal"]]
const TYPE_COLORS := {"main": "#c0603a", "side": "#4a7ab0", "daily": "#5fa64b", "tutorial": "#8a6ab0", "seasonal": "#c08a2a", "event": "#c04a7a"}

var filter := "all"

func _init(p: PlayerData = null, start_tab: String = "quests") -> void:
	super(p, start_tab)

func _tab_list() -> Array:
	return LOG_TABS

func _render(id: String) -> void:
	match id:
		"quests": _quests()
		"daily": _daily()
		"board": _board()
		"weekly": _weekly()
		"done": _done()

static func type_name(t: String) -> String:
	match t:
		"main": return TranslationServer.translate("Main")
		"side": return TranslationServer.translate("Side")
		"daily": return TranslationServer.translate("Daily")
		"tutorial": return TranslationServer.translate("Tutorial")
		"seasonal": return TranslationServer.translate("Seasonal")
		"event": return TranslationServer.translate("Event")
		"weekly": return TranslationServer.translate("Weekly")
	return t

func _filters() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	_body.add_child(row)
	for f in FILTERS:
		var b := UITheme.button(f[1], func(): filter = f[0]; _refresh())
		b.disabled = filter == f[0]
		row.add_child(b)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sp)
	var st := Quests.state(player)
	if st.tutorial == "playing":
		row.add_child(UITheme.button("Skip tutorial", func():
			var c: int = await _ask_skip()
			if c == 0:
				Quests.skip_tutorial(player, TimeService.now())
				Settings.profile_set("tutorial_seen", true)
				EventBus.quest_updated.emit()
				_refresh()))
	elif st.tutorial in ["skipped", ""]:
		row.add_child(UITheme.button("Play tutorial", func():
			Quests.state(player).tutorial = "playing"
			for qid in Quests.tutorial_ids():
				Quests.state(player).done.erase(qid)
			Quests.next_tutorial(player, TimeService.now())
			EventBus.quest_updated.emit()
			_refresh()))

func _ask_skip() -> int:
	var n := get_parent()
	while n and not n is MenuShell:
		n = n.get_parent()
	if n == null or (n as MenuShell).ui == null:
		return 0
	return await (n as MenuShell).ui.ask(tr("Skip the tutorial? You still get all of its rewards."), [tr("Skip"), tr("Keep playing")])

func _quests() -> void:
	_filters()
	var w: Dictionary = GameState.world
	var ch := Adventure.chapter(w)
	if filter in ["all", "main"] and not ch.is_empty():
		var col := _quest_card("", tr("Chapter %d · %s") % [int(w.quest) + 1, tr(str(ch.title))], "main", Adventure.QUEST_GIVER)
		col.add_child(_wrap(Adventure.tracker(w, player), 8, UITheme.WOOD))
		if not ch.goal.is_empty() and w.flags.get("story_seen:" + str(ch.id), false):
			var pr := Adventure.goal_progress(ch.goal, Adventure.story_facts(w, player))
			col.add_child(_bar(int(pr[0]), int(pr[1])))
	var st := Quests.state(player)
	var shown := 0
	for qid in st.active:
		var d := Quests.def_of(player, qid)
		var t := str(d.get("type", "side"))
		if t == "daily":
			continue
		if filter == "seasonal" and not t in ["seasonal", "event"]:
			continue
		if filter in ["main", "side"] and t != filter:
			continue
		_active_card(qid, d)
		shown += 1
	if shown == 0 and filter != "main":
		_body.add_child(_wrap(tr("No quests right now. Villagers with a ! over their head have something for you."), 9, UITheme.MUTED))

func _quest_card(qid: String, title: String, type: String, giver: String) -> VBoxContainer:
	var h := _card()
	if giver != "":
		h.add_child(UITheme.icon_rect(Art.portrait(giver), 32))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 1)
	h.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	col.add_child(head)
	head.add_child(Badge.new(type_name(type), Color(TYPE_COLORS.get(type, "#7a6a5a"))))
	var tl := UITheme.label(title, 10, UITheme.INK)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(tl)
	if qid != "":
		var tracked: bool = qid in Quests.state(player).tracked
		var tb := UITheme.button("★" if tracked else "☆", func():
			Quests.toggle_track(player, qid)
			EventBus.quest_updated.emit()
			_refresh())
		tb.tooltip_text = tr("Stop tracking") if tracked else tr("Track on screen")
		head.add_child(tb)
	return col

func _active_card(qid: String, d: Dictionary) -> VBoxContainer:
	var t := str(d.get("type", "side"))
	var col := _quest_card(qid if t != "daily" else "", Quests.title(player, qid), t, str(d.get("giver", "")))
	col.add_child(_wrap(InputHints.fill(Quests.step_text(player, qid)), 9, UITheme.WOOD))
	var pr := Quests.progress(player, GameState.world, qid)
	if int(pr[1]) > 1:
		col.add_child(_bar(int(pr[0]), int(pr[1])))
	var steps: Array = d.get("steps", [])
	if steps.size() > 1:
		var at := int(Quests.state(player).active[qid].step)
		col.add_child(UITheme.label(tr("Step %d of %d") % [at + 1, steps.size()], 8, UITheme.MUTED))
	var rt := QuestFlow.reward_text(d.get("reward", {}))
	if rt != "":
		col.add_child(UITheme.label(tr("Reward: %s") % rt, 8, UITheme.MUTED))
	return col

func _bar(v: int, mx: int) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 5)
	bar.max_value = maxi(1, mx)
	bar.value = v
	return bar

func _daily() -> void:
	var st := Quests.state(player)
	var streak := int(st.daily.get("streak", 0))
	var info := tr("Three new quests every day at midnight.")
	if streak > 0:
		info += " " + tr("Streak: %d days (bonus every %d).") % [streak, Quests.STREAK_EVERY]
	_body.add_child(_wrap(info, 9, UITheme.MUTED))
	for qid in st.daily.ids:
		if st.active.has(qid):
			var col := _active_card(qid, Quests.def_of(player, qid))
			if not st.daily.rerolled:
				var b := UITheme.button("New task (once a day)", func():
					if Quests.reroll_daily(player, GameState.world, qid, TimeService.now()):
						Audio.sfx("tick")
						EventBus.quest_updated.emit()
					_refresh())
				b.size_flags_horizontal = Control.SIZE_SHRINK_END
				col.add_child(b)
		elif st.done.has(qid):
			var d: Dictionary = st.done[qid].get("def", {})
			var h := _card()
			h.add_child(UITheme.label("✓ " + tr(str(d.get("title", ""))), 10, UITheme.LEAF.darkened(0.3)))

func _done() -> void:
	var st := Quests.state(player)
	var ids: Array = st.done.keys().filter(func(q): return not str(q).begins_with("daily:"))
	ids.sort_custom(func(a, b): return float(st.done[a].get("at", 0)) > float(st.done[b].get("at", 0)))
	var chapters := Adventure.chapters()
	for i in mini(int(GameState.world.quest), chapters.size()):
		ids.append("chapter:%d" % i)
	if ids.is_empty():
		_body.add_child(_wrap(tr("Finished quests show up here."), 9, UITheme.MUTED))
	for qid in ids:
		var h := _card()
		if str(qid).begins_with("chapter:"):
			var ch: Dictionary = chapters[int(str(qid).substr(8))]
			h.add_child(Badge.new(type_name("main"), Color(TYPE_COLORS.main)))
			h.add_child(UITheme.label(tr(str(ch.title)), 9, UITheme.INK))
			continue
		var d: Dictionary = Data.quests.get(qid, {})
		var t := str(d.get("type", "side"))
		h.add_child(Badge.new(type_name(t), Color(TYPE_COLORS.get(t, "#7a6a5a"))))
		h.add_child(UITheme.label(tr(str(d.get("title", qid))), 9, UITheme.INK))
