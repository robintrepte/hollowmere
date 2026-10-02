class_name UIRoot
extends CanvasLayer
## Modal panel stack + dialogue/choice helpers. Opening a panel locks the player and
## pauses the clock when playing solo (co-op time keeps flowing, like Stardew).

signal stack_changed

var root: Control
var dim: ColorRect
var stack: Array = []
var dialogue: DialogueBox
## True while any modal panel or dialogue is up; the local player doesn't move then.
static var blocking := false

func _ready() -> void:
	layer = 20
	root = Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.theme()
	add_child(root)
	dim = ColorRect.new()
	dim.color = Color(0.05, 0.03, 0.06, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.visible = false
	root.add_child(dim)
	dialogue = DialogueBox.new()
	dialogue.visible = false
	root.add_child(dialogue)

func is_open() -> bool:
	return not stack.is_empty() or dialogue.visible

func open(panel: Control, dimmed: bool = true) -> Control:
	root.add_child(panel)
	stack.append(panel)
	dim.visible = dimmed or dim.visible
	root.move_child(dim, root.get_child_count() - 2)
	_pause(true)
	if panel.has_signal("closed"):
		panel.closed.connect(func(): close(panel), CONNECT_ONE_SHOT)
	Audio.sfx("open")
	stack_changed.emit()
	return panel

func close(panel: Control = null) -> void:
	if stack.is_empty():
		return
	if panel == null:
		panel = stack[-1]
	if not panel in stack:
		return
	stack.erase(panel)
	if is_instance_valid(panel):
		panel.queue_free()
	dim.visible = not stack.is_empty()
	if not stack.is_empty():
		root.move_child(dim, root.get_child_count() - 2)
	if stack.is_empty() and not dialogue.visible:
		_pause(false)
	Audio.sfx("close")
	stack_changed.emit()

func close_all() -> void:
	while not stack.is_empty():
		close()

func top() -> Control:
	return stack[-1] if not stack.is_empty() else null

func _pause(on: bool) -> void:
	blocking = on
	if on:
		if not Net.is_online() and Settings.auto_pause_menus:
			GameClock.pause("ui")
	else:
		GameClock.resume("ui")

## Shows lines one by one. Returns the chosen index if `choices` given, else -1.
func say(lines: Array, speaker: String = "", portrait: Texture2D = null, choices: Array = []) -> int:
	root.move_child(dialogue, root.get_child_count() - 1)
	_pause(true)
	var r: int = await dialogue.run(lines, speaker, portrait, choices)
	if stack.is_empty():
		_pause(false)
	return r

func ask(prompt: String, options: Array, speaker: String = "", portrait: Texture2D = null) -> int:
	return await say([prompt], speaker, portrait, options)

func _unhandled_input(event: InputEvent) -> void:
	if dialogue.visible:
		return
	if event.is_action_pressed("menu") and not stack.is_empty():
		var t: Control = stack[-1]
		if not t.has_method("blocks_escape") or not t.blocks_escape():
			close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("inventory") and not stack.is_empty() and stack[-1] is InventoryPanel:
		close()
		get_viewport().set_input_as_handled()
