class_name PauseMenu
extends PanelContainer
## Esc menu: resume, shortcuts to the party / journal / crafting panels (the only way in on a phone),
## save, settings, quit to title / desktop.

signal closed
signal quit_to_title

var ui: UIRoot

func _init(u: UIRoot = null) -> void:
	ui = u

func _ready() -> void:
	add_theme_stylebox_override("panel", UITheme.parchment(12))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size.x = 176
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var t := UITheme.label("Paused" if not Net.is_online() else "Menu", 14, UITheme.WOOD_DK)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var resume := UITheme.button("Resume", func(): closed.emit())
	v.add_child(resume)
	var panels := HBoxContainer.new()
	panels.add_theme_constant_override("separation", 4)
	v.add_child(panels)
	var pd := GameState.local_player()
	for spec in [["Party", func(): return PartyPanel.new(pd)], ["Journal", func(): return JournalPanel.new(pd)],
			["Crafting", func(): return CraftPanel.new(pd, "crafting")]]:
		var make: Callable = spec[1]
		var b := UITheme.button(spec[0], func():
			closed.emit()
			ui.open(make.call()))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = pd == null
		panels.add_child(b)
	var save := UITheme.button("Save game", func():
		if SaveManager.save_game():
			EventBus.toast.emit("Game saved.", "")
		else:
			EventBus.toast.emit("Only the host can save in co-op.", ""))
	save.disabled = not Net.is_authority()
	v.add_child(save)
	v.add_child(UITheme.button("Play together", func():
		closed.emit()
		ui.open(CoopPanel.new(ui, true))))
	v.add_child(UITheme.button("Settings", func(): ui.open(SettingsPanel.new())))
	v.add_child(UITheme.button("Quit to title", func():
		if Net.is_authority():
			SaveManager.save_game()
		quit_to_title.emit()))
	if OS.get_name() != "Web":
		v.add_child(UITheme.button("Quit game", func():
			if Net.is_authority():
				SaveManager.save_game()
			get_tree().quit()))
	resume.call_deferred("grab_focus")
