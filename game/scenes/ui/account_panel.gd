class_name AccountPanel
extends PanelContainer
## Hollowmere account: email / guest / Google sign-in, display name, cloud saves, server address.

signal closed

var _body: VBoxContainer
var _status: Label
var _server_dot: Label
var _busy := false

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -165
	offset_right = 165
	offset_top = -128
	offset_bottom = 128
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
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 4)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_body)
	_status = UITheme.label("", 9, UITheme.HEART)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(300, 0)
	v.add_child(_status)
	var close := UITheme.button("Close", func(): closed.emit())
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	v.add_child(close)
	Net.session_changed.connect(_on_session)
	_rebuild()
	_check_server()

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

func _field(placeholder: String, secret := false) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.secret = secret
	e.add_theme_font_size_override("font_size", UITheme.fs(10))
	e.custom_minimum_size = Vector2(0, 20)
	_body.add_child(e)
	return e

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
	_hint("Sign in to keep your farms in the cloud and play co-op online. Offline play always works.")
	var email := _field("Email")
	var pw := _field("Password (8+ characters)", true)
	var nm := _field("Farmer name (new accounts)")
	nm.max_length = 20
	var r := _row()
	r.add_child(UITheme.button("Sign in", func(): _run(func(): return await Net.login_email(email.text.strip_edges(), pw.text, false))))
	r.add_child(UITheme.button("Create account", func():
		if nm.text.strip_edges() == "":
			_say("Pick a farmer name first.")
			return
		_run(func(): return await Net.login_email(email.text.strip_edges(), pw.text, true, nm.text.strip_edges()))))
	var r2 := _row()
	r2.add_child(UITheme.button("Play as guest", func(): _run(func(): return await Net.login_device())))
	if OS.get_name() == "Web":
		r2.add_child(UITheme.button("Sign in with Google", _google))
	pw.text_submitted.connect(func(_t: String): _run(func(): return await Net.login_email(email.text.strip_edges(), pw.text, false)))
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
	if Net.is_guest:
		_hint("Guest accounts live on this device. Add an email to keep your farms anywhere.")
		var email := _field("Email")
		var pw := _field("Password (8+ characters)", true)
		_body.add_child(UITheme.button("Add email to this account", func(): _run(func(): return await Net.link_email(email.text.strip_edges(), pw.text), "Account secured.")))
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

func _google() -> void:
	JavaScriptBridge.eval("window.hollowmereGoogleToken = ''; window.hollowmereGoogleSignIn()", true)
	_say("Finish signing in with Google in the popup...", true)
	for i in 240:
		await get_tree().create_timer(0.5).timeout
		var err := str(JavaScriptBridge.eval("window.hollowmereGoogleError || ''", true))
		if err != "":
			_say(err)
			return
		var tok: String = Net.web_google_token()
		if tok != "":
			JavaScriptBridge.eval("window.hollowmereHideGoogle()", true)
			_run(func(): return await Net.login_google(tok))
			return
	_say("Google sign-in timed out.")
