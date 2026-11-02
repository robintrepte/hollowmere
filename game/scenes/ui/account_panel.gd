class_name AccountPanel
extends PanelContainer
## Hollowmere account: "Mit Tretu-Konto anmelden" (the only account sign-in) or play as a guest;
## display name, cloud saves. A guest saves its farm to the Tretu-Konto with the same Tretu sign-in.
## Tretu-Konto players also get the Tretu menu (Tretu-Credits, notifications, choose a farm).

signal closed

var _body: VBoxContainer
var _status: Label
var _server_dot: Label
var _busy := false
var _tretu_pending := false

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -165
	offset_right = 165
	offset_top = -148
	offset_bottom = 148
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := UITheme.label("Hollowmere account", 13, UITheme.WOOD_DK)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	_server_dot = UITheme.label("", 8, UITheme.MUTED)
	head.add_child(_server_dot)
	# Scrolls when the content is taller than the panel (Tretu menu, large text, small screens).
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 4)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_body)
	_status = UITheme.label("", 9, UITheme.HEART)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(300, 0)
	v.add_child(_status)
	var close := UITheme.button("Close", func(): closed.emit())
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	v.add_child(close)
	Net.session_changed.connect(_on_session)
	Tretu.status.connect(func(text: String): _say(text, true))
	_rebuild()
	_check_server()

func _exit_tree() -> void:
	if _tretu_pending:
		Tretu.cancel()

func _on_session(_in: bool) -> void:
	_rebuild()

func _check_server() -> void:
	_server_dot.text = "checking..."
	var ok: bool = await Net.ping_server()
	if not is_inside_tree():
		return
	_server_dot.text = "● online" if ok else "● offline"
	_server_dot.add_theme_color_override("font_color", UITheme.LEAF if ok else UITheme.HEART)

func _rebuild() -> void:
	for c in _body.get_children():
		c.queue_free()
	if Net.has_session():
		_signed_in()
	else:
		_signed_out()
		_fit_height()

func _hint(text: String) -> void:
	var l := UITheme.label(text, 8, UITheme.MUTED)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(300, 0)
	_body.add_child(l)

func _row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	_body.add_child(h)
	return h

func _signed_out() -> void:
	_hint("Sign in with your Tretu-Konto to keep your farms in the cloud and play co-op online. One account for all Tretu games and apps. Offline play always works.")
	_tretu_button(_row(), tr("Sign in with Tretu"))
	if not Tretu.enabled():
		_hint("Tretu sign-in is not set up for this build.")
	var r := _row()
	var guest := UITheme.button("Play as guest", func(): _run(func(): return await Net.login_device()))
	guest.name = "GuestButton"
	guest.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(guest)
	if OS.get_name() != "Web":
		_server_row()

func _server_row() -> void:
	var r := _row()
	r.add_child(UITheme.label("Server", 8, UITheme.MUTED))
	var host := LineEdit.new()
	host.text = tr("%s:%d") % [Settings.server_host, Settings.server_port]
	host.add_theme_font_size_override("font_size", UITheme.fs(8))
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(host)
	var ssl := CheckBox.new()
	ssl.text = "TLS"
	ssl.button_pressed = Settings.server_ssl
	ssl.add_theme_font_size_override("font_size", UITheme.fs(8))
	r.add_child(ssl)
	r.add_child(UITheme.button("Use", func():
		var parts := host.text.strip_edges().split(":")
		Settings.server_host = parts[0]
		Settings.server_port = int(parts[1]) if parts.size() > 1 and parts[1].is_valid_int() else (443 if ssl.button_pressed else 7350)
		Settings.server_ssl = ssl.button_pressed
		Settings.save_settings()
		Net.reset_client()
		_check_server()))

func _signed_in() -> void:
	var who := UITheme.label(tr("Signed in as %s%s") % [Net.display_name, "  (guest)" if Net.is_guest else ""], 11, UITheme.INK)
	_body.add_child(who)
	var r := _row()
	var nm := LineEdit.new()
	nm.text = Net.display_name
	nm.max_length = 20
	nm.add_theme_font_size_override("font_size", UITheme.fs(10))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(nm)
	r.add_child(UITheme.button("Rename", func(): _run(func(): return await Net.set_display_name(nm.text.strip_edges()), "Name saved.")))
	if not Net.is_tretu:
		# Guest (or an old account whose session is still stored): the Tretu sign-in keeps this farm.
		_hint("Guest farms live on this device. Save them to your Tretu-Konto to keep them anywhere and play on every device.")
		_tretu_button(_row(), tr("Save to Tretu-Konto"))
	var cloud := CheckBox.new()
	cloud.text = "Back up farms to the cloud when saving"
	cloud.button_pressed = Settings.cloud_saves
	cloud.add_theme_font_size_override("font_size", UITheme.fs(9))
	cloud.toggled.connect(func(on: bool):
		Settings.cloud_saves = on
		Settings.save_settings())
	_body.add_child(cloud)
	var r2 := _row()
	r2.add_child(UITheme.button("Upload all farms now", func(): _run(_upload_all, "Farms backed up to the cloud.")))
	r2.add_child(UITheme.button("Sign out", func(): _run(_sign_out)))
	if Net.is_tretu and Tretu.enabled():
		_body.add_child(HSeparator.new())
		var menu := TretuMenu.new()
		menu.name = "TretuMenu"
		menu.link_requested.connect(_open_url)
		menu.choose_farm_requested.connect(_open_farm_choice)
		_body.add_child(menu)
		# Fresh numbers whenever the panel opens (the server caches and rate-limits this).
		Tretu.refresh_summary(true)
		Tretu.check_farm_choice()
	_fit_height()

## The Tretu menu adds rows: a taller panel (still inside the 360 px base view; the rest scrolls).
func _fit_height() -> void:
	var tall := Net.has_session() and Net.is_tretu and Tretu.enabled()
	offset_top = -172 if tall else -148
	offset_bottom = 172 if tall else 148

func _open_farm_choice() -> void:
	var ui := _ui_root()
	if ui == null:
		return
	var p := FarmChoicePanel.new()
	p.farm_switched.connect(_rebuild)
	ui.open(p)

func _ui_root() -> UIRoot:
	var n := get_parent()
	while n != null and not n is UIRoot:
		n = n.get_parent()
	return n as UIRoot

func _upload_all() -> String:
	var n: int = await SaveManager.upload_all()
	return "" if n > 0 else "No farms to upload yet."

func _sign_out() -> String:
	await Net.logout()
	return ""

func _say(msg: String, good := false) -> void:
	_status.text = msg
	_status.add_theme_color_override("font_color", UITheme.LEAF if good else UITheme.HEART)

## Runs an async account call that returns "" on success or an error message.
func _run(fn: Callable, ok_msg := "") -> void:
	if _busy:
		return
	_busy = true
	_say("Talking to the server...", true)
	var err: String = await fn.call()
	_busy = false
	if not is_inside_tree():
		return
	if err != "":
		_say(err)
	else:
		_say(ok_msg, true)
		if ok_msg == "":
			_status.text = ""
		Audio.sfx("open")

## "Mit Tretu-Konto anmelden" / "Save to Tretu-Konto" (same sign-in; from a guest it keeps the farm).
## Missing only in a build without tretu/auth_issuer and tretu/client_id.
func _tretu_button(row: HBoxContainer, text: String) -> void:
	if not Tretu.enabled():
		return
	var b := UITheme.button(text, func(): _run(_tretu_sign_in))
	b.name = "TretuButton"
	b.icon = Art.social_icon("tretu")
	b.expand_icon = true
	b.add_theme_constant_override("icon_max_width", 14)
	b.add_theme_constant_override("h_separation", 5)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(b)

func _tretu_sign_in() -> String:
	_tretu_pending = true
	var err: String = await Tretu.sign_in()
	_tretu_pending = false
	return err

func _open_url(url: String) -> void:
	if OS.get_name() == "Web":
		JavaScriptBridge.eval("window.open(%s, '_blank', 'noopener')" % JSON.stringify(url), true)
	else:
		OS.shell_open(url)
