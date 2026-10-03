class_name CoopPanel
extends PanelContainer
## Play together. From the title: join a friend's farm by code or LAN address.
## In game: host (online code or LAN), see who's here, trade, challenge, chat, leave.

signal closed

var ui: UIRoot
var in_game := false
var _body: VBoxContainer
var _status: Label
var _busy := false

func _init(u: UIRoot = null, game: bool = false) -> void:
	ui = u
	in_game = game

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -170
	offset_right = 170
	offset_top = -135
	offset_bottom = 135
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	add_child(v)
	v.add_child(UITheme.label("Play together", 13, UITheme.WOOD_DK))
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 4)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_body)
	_status = UITheme.label("", 9, UITheme.HEART)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(310, 0)
	v.add_child(_status)
	var close := UITheme.button("Close", func(): closed.emit())
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	v.add_child(close)
	Net.peer_joined.connect(func(_p, _n): _rebuild())
	Net.peer_left.connect(func(_p): _rebuild())
	Net.session_changed.connect(func(_s): _rebuild())
	EventBus.net_status.connect(func(t: String): _say(t))
	_rebuild()

func _rebuild() -> void:
	if not is_inside_tree():
		return
	for c in _body.get_children():
		c.queue_free()
	if not in_game:
		_join_view()
	elif Net.is_online():
		_session_view()
	else:
		_host_view()

func _hint(text: String, col: Color = UITheme.MUTED) -> void:
	var l := UITheme.label(text, 8, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(310, 0)
	_body.add_child(l)

func _row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	_body.add_child(h)
	return h

func _edit(parent: Control, text: String, placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.add_theme_font_size_override("font_size", UITheme.fs(10))
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(e)
	return e

func _heading(text: String) -> void:
	_body.add_child(UITheme.label(text, 10, UITheme.WOOD_DK))

# --- Title: join -------------------------------------------------------------------------------

func _join_view() -> void:
	_heading("Join a friend online")
	if Net.has_session():
		var r := _row()
		var code := _edit(r, "", "Farm code, e.g. K7QM2D")
		code.max_length = 8
		code.text_changed.connect(func(t: String):
			var up := t.to_upper()
			if up != t:
				code.text = up
				code.caret_column = up.length())
		r.add_child(UITheme.button("Join", func(): _join_online(code.text)))
		code.text_submitted.connect(func(t: String): _join_online(t))
		code.call_deferred("grab_focus")
	else:
		var r0 := _row()
		r0.add_child(UITheme.label("Online play needs a free account.", 9, UITheme.INK))
		r0.add_child(UITheme.button("Sign in", func(): ui.open(AccountPanel.new())))
	_heading("Same Wi-Fi or LAN")
	var r2 := _row()
	var addr := _edit(r2, "127.0.0.1", "Host address")
	r2.add_child(UITheme.button("Join LAN", func(): _join_lan(addr.text)))
	_hint("To host, load your farm, then press O (or Esc > Play together). Friends' progress is saved on the host's farm.")

func _join_online(code: String) -> void:
	code = code.strip_edges().to_upper()
	if code.length() < 6:
		_say("Farm codes are 6 letters.")
		return
	await _join(func(): return await Net.join_online(code))

func _join_lan(addr: String) -> void:
	var parts := addr.strip_edges().split(":")
	var port := int(parts[1]) if parts.size() > 1 else Net.ENET_PORT
	await _join(func(): return Net.join_lan(parts[0], port))

func _join(start: Callable) -> void:
	if _busy:
		return
	_busy = true
	_say("Knocking on the farm gate...", true)
	var ok: bool = await start.call()
	if ok:
		ok = await _await_snapshot(15.0)
	_busy = false
	if not ok:
		if Net.is_online():
			Net.leave()
		if is_inside_tree() and _status.text.begins_with("Knocking"):
			_say("Couldn't reach that farm. Check the code and that the host is online.")
		return
	if is_inside_tree():
		closed.emit()

func _await_snapshot(timeout: float) -> bool:
	var got := [false]
	var on_snap := func(): got[0] = true
	Coop.snapshot_loaded.connect(on_snap)
	var t := 0.0
	while not got[0] and t < timeout and Net.is_online():
		await get_tree().create_timer(0.1).timeout
		t += 0.1
	Coop.snapshot_loaded.disconnect(on_snap)
	return got[0]

# --- In game, not hosting yet ---------------------------------------------------------------------

func _host_view() -> void:
	_hint("Open your farm to friends. They join with their own character and help with everything; the farm, money and Wildlings stay yours and save on your computer.", UITheme.INK)
	_heading("Online")
	if Net.has_session():
		_body.add_child(UITheme.button("Open farm online", _host_online))
	else:
		var r := _row()
		r.add_child(UITheme.label("Hosting online needs a free account.", 9, UITheme.INK))
		r.add_child(UITheme.button("Sign in", func(): ui.open(AccountPanel.new())))
	if OS.get_name() != "Web":
		_heading("Same Wi-Fi or LAN")
		_body.add_child(UITheme.button("Open farm on LAN", func():
			if Net.host_lan():
				_rebuild()
			else:
				_say(tr("Couldn't open port %d. Is another farm already open?") % Net.ENET_PORT)))

func _host_online() -> void:
	if _busy:
		return
	_busy = true
	_say("Opening the farm gate...", true)
	var code: String = await Net.host_online()
	_busy = false
	if code == "":
		_say("Couldn't open the farm online. Try again in a moment.")
		return
	_say("", true)
	_rebuild()

# --- In a session --------------------------------------------------------------------------------

func _session_view() -> void:
	if Net.mode == "host":
		var r := _row()
		var lan := Net.match_code.begins_with("LAN")
		r.add_child(UITheme.label("Farm code:" if not lan else "LAN address:", 10, UITheme.INK))
		var code_text := Net.match_code if not lan else _lan_address()
		var code := UITheme.label(code_text, 14, UITheme.WOOD_DK)
		code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(code)
		r.add_child(UITheme.button("Copy", func():
			DisplayServer.clipboard_set(code_text)
			_say("Copied!", true)))
	else:
		_hint(tr("You're visiting %s's farm.") % _host_name(), UITheme.INK)
	var players := Coop.online_players()
	_heading(tr("Here now (%d)") % (players.size() + 1))
	if players.is_empty():
		_hint("Waiting for friends to join...")
	for pl: Dictionary in players:
		var r2 := _row()
		var nm := UITheme.label("● " + str(pl.name), 10, UITheme.INK)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r2.add_child(nm)
		var pid: String = pl.pid
		r2.add_child(UITheme.button("Trade", func():
			Coop.trade_op("open", {"to": pid})
			closed.emit()))
		r2.add_child(UITheme.button("Battle", func():
			if not GameState.local_player().has_usable_party():
				_say("Your Wildlings need a rest first.")
				return
			Coop.challenge(pid)
			_say(tr("Challenge sent to %s.") % pl.name, true)))
	var rc := _row()
	var chat := _edit(rc, "", "Say something...")
	chat.max_length = 200
	var send := func():
		Coop.send_chat(chat.text)
		chat.text = ""
	rc.add_child(UITheme.button("Send", send))
	chat.text_submitted.connect(func(_t: String): send.call())
	var hosting := Net.mode == "host"
	var leave := UITheme.button("Close farm" if hosting else "Leave farm", func():
		await Net.leave()
		if hosting:
			_rebuild()
		else:
			closed.emit())
	leave.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_body.add_child(leave)

func _host_name() -> String:
	var hp := GameState.player("local")
	return hp.name if hp else "the host"

func _lan_address() -> String:
	for a in IP.get_local_addresses():
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return a
	return "127.0.0.1"

func _say(msg: String, good := false) -> void:
	if not is_inside_tree():
		return
	_status.text = msg
	_status.add_theme_color_override("font_color", UITheme.LEAF if good else UITheme.HEART)
