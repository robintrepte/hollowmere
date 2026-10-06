class_name MenuShell
extends PanelContainer
## The game menu: one almost-fullscreen window with icon tabs for inventory, party, crafting,
## journal, map, skills and settings. Hotkeys open it on their tab; pressing the key again closes it.
## Q / E (LB / RB, or a swipe on touch) step through the tabs.

signal closed

const TABS := [
	["inventory", "Inventory", "_tab_inventory", "inventory"],
	["party", "Party", "_tab_party", "party"],
	["craft", "Crafting", "_tab_craft", "craft"],
	["quests", "Quests", "_tab_quests", "quests"],
	["journal", "Journal", "_tab_journal", "journal"],
	["skills", "Skills", "_tab_skills", "skills"],
	["collection", "Collection", "_tab_collection", "collection"],
	["map", "Map", "_tab_map", "map"],
	["settings", "Settings", "_tab_settings", ""],
]

const HOTKEYS := ["inventory", "party", "craft", "quests", "journal", "skills", "map"]

var ui: UIRoot
var tab := "inventory"
var bar: IconTabBar
var content: Control
var current: Control
var _swipe_from := Vector2.INF

func _init(ui_root: UIRoot = null, start_tab: String = "inventory") -> void:
	ui = ui_root
	tab = start_tab

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(6))
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_fit()
	get_viewport().size_changed.connect(_fit)
	Settings.ui_scale_changed.connect(_fit)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	bar = IconTabBar.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(bar)
	for t in TABS:
		if available(t[0]):
			bar.add_tab(t[0], t[1], Art.item(t[2]), t[3])
	head.add_child(UITheme.button("×", func(): closed.emit()))
	content = Control.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.clip_contents = true
	v.add_child(content)
	bar.tab_selected.connect(_show)
	bar.select(tab if tab in bar.ids() else "inventory")
	_fit()

## Tabs whose systems are not part of this build stay hidden.
static func available(id: String) -> bool:
	match id:
		"skills":
			return ResourceLoader.exists("res://scenes/ui/skill_panel.gd")
		"collection":
			return ResourceLoader.exists("res://scenes/ui/collection_panel.gd")
	return true

## Most of the parent, inside the safe area (notches, home indicator).
## The parent is the scaled UI root, so its size is already in layout pixels.
func _fit() -> void:
	var view := get_viewport_rect().size
	var host := get_parent() as Control
	var box := view
	if host != null and host.size.x > 1.0 and host.size.y > 1.0:
		box = host.size
	var safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	var inset := Vector4(0, 0, 0, 0)
	if win.x > 0 and win.y > 0 and safe.size.x > 0 and box.x > 0.0:
		var sx := box.x / float(win.x)
		var sy := box.y / float(win.y)
		inset = Vector4(safe.position.x * sx, safe.position.y * sy, (win.x - safe.end.x) * sx, (win.y - safe.end.y) * sy)
	var m := Vector2(box.x * 0.03, box.y * 0.03)
	offset_left = maxf(m.x, inset.x)
	offset_top = maxf(m.y, inset.y)
	offset_right = -maxf(m.x, inset.z)
	offset_bottom = -maxf(m.y, inset.w)
	if bar:
		var room := box.x - offset_left + offset_right - 40.0
		bar.set_compact(box.x < 560.0 or Settings.text_scale > 1.2 or bar.full_width() > room)

func _make(id: String) -> Control:
	var p := GameState.local_player()
	match id:
		"inventory": return InventoryPanel.new(p)
		"party": return PartyPanel.new(p)
		"craft": return CraftPanel.new(p, "crafting")
		"journal": return JournalPanel.new(p)
		"quests": return QuestLogPanel.new(p)
		"map": return MapPanel.new()
		"settings": return SettingsPanel.new()
		"skills": return load("res://scenes/ui/skill_panel.gd").new(p)
		"collection": return load("res://scenes/ui/collection_panel.gd").new(p)
	return Control.new()

func _show(id: String) -> void:
	tab = id
	if is_instance_valid(current):
		if current.has_method("on_tab_hidden"):
			current.on_tab_hidden()
		# Inventory emits closed from _exit_tree. Unhook that before freeing the tab,
		# or a tab switch closes the whole menu.
		if current.has_signal("closed") and current.closed.is_connected(_forward_tab_closed):
			current.closed.disconnect(_forward_tab_closed)
		current.queue_free()
	current = _make(id)
	current.set("embedded", true)
	content.add_child(current)
	current.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	current.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if current.has_signal("closed"):
		current.closed.connect(_forward_tab_closed, CONNECT_ONE_SHOT)
	if current.has_method("on_tab_shown"):
		current.on_tab_shown()
	Audio.sfx("tick", 0.0)
	if Settings.using_pad:
		UIRoot.focus_first.call_deferred(current)

## A tab's own close button closes the menu. Ignored once the shell is already leaving the tree.
func _forward_tab_closed() -> void:
	if is_inside_tree():
		closed.emit()

func blocks_escape() -> bool:
	return is_instance_valid(current) and current.has_method("blocks_escape") and current.blocks_escape()

## The hotkey of the open tab closes the menu; another tab's hotkey switches to it.
func handle_hotkey(action: String) -> bool:
	for t in TABS:
		if t[3] == action and t[0] in bar.ids():
			if tab == t[0]:
				closed.emit()
			else:
				bar.select(t[0])
			return true
	return false

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_Q:
			bar.step(-1)
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_E:
			bar.step(1)
			get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_LEFT_SHOULDER:
			bar.step(-1)
			get_viewport().set_input_as_handled()
		elif event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			bar.step(1)
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		if event.pressed:
			_swipe_from = event.position if bar.get_global_rect().grow(24).has_point(event.position) else Vector2.INF
		elif _swipe_from != Vector2.INF:
			var d: Vector2 = event.position - _swipe_from
			_swipe_from = Vector2.INF
			if absf(d.x) > get_viewport_rect().size.x * 0.25 and absf(d.y) < absf(d.x) * 0.4:
				bar.step(-1 if d.x > 0 else 1)
