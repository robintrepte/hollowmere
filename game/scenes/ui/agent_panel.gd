class_name AgentPanel
extends PanelContainer
## Tokens for MCP clients, spectator mode, and up to three virtual farmhands.

signal closed

var _body: VBoxContainer
var _status: Label
var _busy := false

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -200
	offset_right = 200
	offset_top = -150
	offset_bottom = 150
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	head.add_child(UITheme.label("AI agents", 13, UITheme.WOOD_DK))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	head.add_child(UITheme.button("Close", func(): closed.emit()))
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 4)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_body)
	_status = UITheme.label("", 8, UITheme.MUTED)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(380, 0)
	v.add_child(_status)
	AgentBridge.mode_changed.connect(_rebuild)
	_rebuild()
	if Net.has_session():
		_reload()

func _reload() -> void:
	await AgentBridge.refresh_tokens()
	if is_inside_tree():
		_rebuild()

func _rebuild() -> void:
	for c in _body.get_children():
		c.queue_free()
	_hint(tr("The game must stay open. Background browser tabs pause the world."))
	if OS.get_name() == "Web":
		_hint(tr("Keep this tab visible while an agent is playing."))
	_heading("Your character")
	var r := HBoxContainer.new()
	_body.add_child(r)
	r.add_child(UITheme.button("Let an agent play (I watch)" if not AgentBridge.spectator else "Take control back", func():
		if AgentBridge.spectator:
			AgentBridge.take_back()
		else:
			AgentBridge.set_spectator(true)
		_rebuild()))
	if AgentBridge.last_thought != "":
		_hint(tr("Thinking: %s") % AgentBridge.last_thought, UITheme.INK)
	_heading(tr("Virtual partners (%d/%d)") % [AgentBridge.partners.size(), AgentBridge.MAX_AGENTS])
	for pid in AgentBridge.partners:
		var row := HBoxContainer.new()
		_body.add_child(row)
		var pl := GameState.player(pid)
		row.add_child(UITheme.label(pl.name if pl else pid, 10, UITheme.INK))
		row.add_child(UITheme.button("Send home", func(): AgentBridge.dismiss_partner(pid)))
	if AgentBridge.partners.size() < AgentBridge.MAX_AGENTS and GameState.started:
		var name_e := LineEdit.new()
		name_e.placeholder_text = tr("Partner name")
		name_e.add_theme_font_size_override("font_size", UITheme.fs(10))
		var row2 := HBoxContainer.new()
		_body.add_child(row2)
		row2.add_child(name_e)
		row2.add_child(UITheme.button("Invite helper", func():
			var id := AgentBridge.spawn_partner(name_e.text)
			_status.text = tr("Partner %s is on the farm. Point an MCP client at them with actor=%s.") % [id, id] if id != "" else tr("Could not add a partner (host only, max 3).")))
	_heading("MCP tokens")
	if not Net.has_session():
		_hint(tr("Sign in to create a token a helper can use from Claude, Cursor or any MCP client."))
		return
	for t in AgentBridge.tokens:
		var row3 := HBoxContainer.new()
		_body.add_child(row3)
		var lab := UITheme.label("%s  (%s)" % [t.get("name", "token"), ", ".join(t.get("scopes", []))], 9, UITheme.INK)
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row3.add_child(lab)
		row3.add_child(UITheme.button("Revoke", func():
			await AgentBridge.revoke_token(str(t.get("id", "")))
			_rebuild()))
	_body.add_child(UITheme.button("New token (observe + act + chat)", func(): _mint(["observe", "act", "chat"])))
	_body.add_child(UITheme.button("New token with economy", func(): _mint(["observe", "act", "chat", "economy"])))
	_hint(tr("Paste the token once into your MCP client. Docs: docs/agents.md"))

func _mint(scopes: Array) -> void:
	if _busy:
		return
	_busy = true
	var res: Dictionary = await AgentBridge.issue_token("MCP", scopes, 30)
	_busy = false
	if res.has("token"):
		DisplayServer.clipboard_set(str(res.token))
		_status.text = tr("Token copied. It will not be shown again.")
	else:
		_status.text = str(res.get("error", "Could not create a token."))
	_rebuild()

func _heading(text: String) -> void:
	_body.add_child(UITheme.label(text, 10, UITheme.WOOD_DK))

func _hint(text: String, col: Color = UITheme.MUTED) -> void:
	var l := UITheme.label(text, 8, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(380, 0)
	_body.add_child(l)
