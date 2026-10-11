class_name AgentPanel
extends PanelContainer
## MCP setup: address, token, who plays, and up to three farmhands.
## Sized to the viewport; the middle scrolls so nothing sits off screen.

signal closed

var _body: VBoxContainer
var _scroll: ScrollContainer
var _status: Label
var _notes: Array = []
var _secret := ""
var _spend := false
var _busy := false
var _inner_w := 260.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	add_theme_stylebox_override("panel", UITheme.parchment(8))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var title := UITheme.label("AI helpers", 13, UITheme.WOOD_DK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(UITheme.button("Close", func(): closed.emit()))
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	v.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 4)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_body)
	_status = UITheme.label("", 8, UITheme.LEAF)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_status)
	AgentBridge.mode_changed.connect(_rebuild)
	get_viewport().size_changed.connect(_fit)
	if not Settings.ui_scale_changed.is_connected(_fit):
		Settings.ui_scale_changed.connect(_fit)
	_fit()
	_rebuild()
	if Net.has_session():
		_reload()

func _fit() -> void:
	var box := _host_size()
	var margin := 8.0
	var w := minf(336.0, maxf(120.0, box.x - margin * 2.0))
	var h := minf(320.0, maxf(120.0, box.y - margin * 2.0))
	# Drop wrap widths before resizing, or a previous layout keeps the panel
	# at its old minimum and it spills past a smaller window.
	_inner_w = 0.0
	_apply_wrap()
	offset_left = -w * 0.5
	offset_right = w * 0.5
	offset_top = -h * 0.5
	offset_bottom = h * 0.5
	size = Vector2(w, h)
	_inner_w = maxf(40.0, w - 28.0)
	_apply_wrap()
	call_deferred("_sync_wrap")

func _exit_tree() -> void:
	if Settings.ui_scale_changed.is_connected(_fit):
		Settings.ui_scale_changed.disconnect(_fit)
	var vp := get_viewport()
	if vp != null and vp.size_changed.is_connected(_fit):
		vp.size_changed.disconnect(_fit)

func _sync_wrap() -> void:
	if not is_instance_valid(_scroll) or _scroll.size.x < 8.0:
		return
	var w := _scroll.size.x
	var bar := _scroll.get_v_scroll_bar()
	if bar != null and bar.visible:
		w -= bar.size.x
	# Stay inside the panel. A wrap width equal to the scroll width feeds
	# back into the panel's minimum size and pushes it past the window.
	_inner_w = clampf(w - 8.0, 40.0, maxf(40.0, size.x - 28.0))
	_apply_wrap()

func _host_size() -> Vector2:
	var host := get_parent() as Control
	if host != null and host.size.x > 8.0 and host.size.y > 8.0:
		return host.size
	var view := get_viewport_rect().size
	return view if view.x > 8.0 else Vector2(320, 180)

func _reload() -> void:
	await AgentBridge.refresh_tokens()
	if is_inside_tree():
		_rebuild()

func _rebuild() -> void:
	if _body == null:
		return
	_notes.clear()
	for c in _body.get_children():
		c.queue_free()
	_note("A helper plays in this open game. Keep the window in front.")
	if OS.get_name() == "Web":
		_note("Keep this tab in front. A hidden browser tab pauses the farm.")
	_connect_section()
	_who_section()
	_farmhands()
	_apply_wrap()

func _connect_section() -> void:
	_heading("Connect")
	var url := AgentTools.mcp_url()
	_copy_line("Address", url, url)
	if not Net.has_session():
		_note("Sign in to create a token.")
		return
	if _secret != "":
		_copy_line("Token", _secret, _secret)
		_note("Shown only once. Copy it now.")
		_body.add_child(UITheme.button("Copy for Cursor", func(): _copy(_cursor_snippet(), tr("Setup copied."))))
	_heading("Your tokens")
	if AgentBridge.tokens.is_empty() and _secret == "":
		_note("No tokens yet.")
	for t in AgentBridge.tokens:
		var tid := str(t.get("id", ""))
		var row := _row()
		var lab := UITheme.label("%s · %s" % [str(t.get("name", "token")), _scope_text(t.get("scopes", []))], 8, UITheme.INK)
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lab.clip_text = true
		row.add_child(lab)
		row.add_child(UITheme.button("Revoke", _revoke.bind(tid)))
	var spend := CheckBox.new()
	spend.text = tr("Allow spending gold")
	spend.button_pressed = _spend
	spend.add_theme_font_size_override("font_size", UITheme.fs(8))
	spend.add_theme_color_override("font_color", UITheme.INK)
	spend.add_theme_color_override("font_hover_color", UITheme.WOOD_DK)
	spend.add_theme_color_override("font_pressed_color", UITheme.INK)
	spend.toggled.connect(func(on: bool): _spend = on)
	_body.add_child(spend)
	_body.add_child(UITheme.button("Create token", _mint))

func _who_section() -> void:
	_heading("Who plays")
	if AgentBridge.spectator:
		_note("You are watching.", UITheme.INK)
		if AgentBridge.last_thought != "":
			_note(tr("Thinking: %s") % AgentBridge.last_thought, UITheme.INK)
		_body.add_child(UITheme.button("I'll play", func():
			AgentBridge.take_back()
			_rebuild()))
	else:
		_body.add_child(UITheme.button("Let a helper play", func():
			AgentBridge.set_spectator(true)
			_rebuild()))

func _farmhands() -> void:
	_heading(tr("Farmhands (%d/%d)") % [AgentBridge.partners.size(), AgentBridge.MAX_AGENTS])
	_note("Pass the copied id as actor.")
	for pid in AgentBridge.partners:
		var id := str(pid)
		var row := _row()
		var pl := GameState.player(id)
		var nm := UITheme.label(pl.name if pl else id, 9, UITheme.INK)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.clip_text = true
		row.add_child(nm)
		row.add_child(UITheme.label(id, 8, UITheme.MUTED))
		row.add_child(UITheme.button("Copy", _copy.bind(id, tr("Copied!"))))
		row.add_child(UITheme.button("Send home", _dismiss.bind(id)))
	if AgentBridge.partners.size() < AgentBridge.MAX_AGENTS and GameState.started:
		var row2 := _row()
		var name_e := LineEdit.new()
		name_e.placeholder_text = tr("Farmhand name")
		name_e.max_length = 16
		name_e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_e.add_theme_font_size_override("font_size", UITheme.fs(9))
		row2.add_child(name_e)
		var invite := func():
			var id := AgentBridge.spawn_partner(name_e.text)
			if id == "":
				_say(tr("Could not add a farmhand (host only, up to 3)."), false)
			else:
				_say(tr("%s joined. In the helper, set actor to %s.") % [id, id])
				_rebuild()
		row2.add_child(UITheme.button("Invite", invite))
		name_e.text_submitted.connect(func(_t: String): invite.call())

func _mint() -> void:
	if _busy:
		return
	_busy = true
	var scopes: Array = ["observe", "act", "chat"]
	if _spend:
		scopes.append("economy")
	var res: Dictionary = await AgentBridge.issue_token("MCP", scopes, 30)
	_busy = false
	if not is_inside_tree():
		return
	if res.has("token"):
		_secret = str(res.token)
		_copy(_secret, tr("Copied!"))
	else:
		_say(tr("Could not create a token."), false)
	_rebuild()

func _revoke(id: String) -> void:
	await AgentBridge.revoke_token(id)
	if is_inside_tree():
		_rebuild()

func _dismiss(id: String) -> void:
	AgentBridge.dismiss_partner(id)
	_rebuild()

func _copy_line(caption: String, shown: String, value: String) -> void:
	_heading(caption)
	var row := _row()
	var e := LineEdit.new()
	e.text = shown
	e.editable = false
	e.select_all_on_focus = true
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.custom_minimum_size = Vector2(0, 0)
	e.add_theme_font_size_override("font_size", UITheme.fs(8))
	row.add_child(e)
	row.add_child(UITheme.button("Copy", _copy.bind(value, tr("Copied!"))))

func _cursor_snippet() -> String:
	return JSON.stringify({
		"mcpServers": {
			"hollowmere": {
				"url": AgentTools.mcp_url(),
				"headers": {"Authorization": "Bearer " + _secret},
			},
		},
	}, "  ")

func _scope_text(scopes: Array) -> String:
	if "economy" in scopes:
		return tr("Watch, play, chat, gold")
	return tr("Watch, play, chat")

func _copy(text: String, done: String = "") -> void:
	DisplayServer.clipboard_set(text)
	_say(done if done != "" else tr("Copied!"))

func _heading(text: String) -> void:
	_body.add_child(UITheme.label(text, 10, UITheme.WOOD_DK))

func _note(text: String, col: Color = UITheme.MUTED) -> void:
	var l := UITheme.label(text, 8, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(l)
	_notes.append(l)

func _row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	_body.add_child(h)
	return h

func _apply_wrap() -> void:
	if is_instance_valid(_status):
		_status.custom_minimum_size.x = _inner_w
	for l in _notes:
		if is_instance_valid(l):
			l.custom_minimum_size.x = _inner_w

func _say(msg: String, good := true) -> void:
	if not is_instance_valid(_status):
		return
	_status.text = msg
	_status.add_theme_color_override("font_color", UITheme.LEAF if good else UITheme.HEART)
