class_name FarmChoicePanel
extends PanelContainer
## "Choose your farm": a Tretu-Konto player who also has an old Discord / Steam account (or an
## archived farm) sees every farm with its cloud saves and keeps one. The server archives the
## others (never deletes them) and they stay restorable here for `keep_days` days.

signal closed
## Emitted after a successful switch (the account panel and title screen refresh).
signal farm_switched

var _choice: Dictionary
var _list: VBoxContainer
var _status: Label
var _busy := false
## Option id waiting for the second "Yes, keep it" click.
var confirming := ""

## `choice` = Tretu.parse_farm_choice(...) result; defaults to the last one Tretu fetched.
func _init(choice: Dictionary = {}) -> void:
	_choice = choice

func _ready() -> void:
	if _choice.is_empty():
		_choice = Tretu.farm_choice
	add_theme_stylebox_override("panel", UITheme.parchment(10))
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -190
	offset_right = 190
	offset_top = -160
	offset_bottom = 160
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	add_child(v)
	v.add_child(UITheme.label("Choose your farm", 13, UITheme.WOOD_DK))
	var intro := UITheme.label(intro_text(_choice), 9, UITheme.INK)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size = Vector2(350, 0)
	v.add_child(intro)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(350, 150)
	v.add_child(scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	_status = UITheme.label("", 9, UITheme.HEART)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(350, 0)
	v.add_child(_status)
	var close := UITheme.button(tr("Decide later") if _choice.get("pending", false) else tr("Close"), func(): closed.emit())
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	v.add_child(close)
	_fill()

static func intro_text(choice: Dictionary) -> String:
	var days := int(choice.get("keep_days", 90))
	var waiting := (choice.get("options", []) as Array).filter(func(o): return o.kind in ["discord", "steam"])
	if choice.get("pending", false) and not waiting.is_empty():
		return TranslationServer.translate("Your Tretu-Konto and your old %s account each have a farm. Keep the one you want to play. The other one is archived, not deleted, and you can restore it here for %d days.") \
			% [Tretu.provider_name(str(waiting[0].kind)), days]
	return TranslationServer.translate("Archived farms can be restored here for %d days. Restoring one archives the farm you play now.") % days

## Card title for one farm.
static func option_title(o: Dictionary) -> String:
	match str(o.get("kind", "")):
		"tretu":
			return TranslationServer.translate("Tretu-Konto (playing now)") if o.get("current", false) else TranslationServer.translate("Tretu-Konto")
		"discord":
			return TranslationServer.translate("Old Discord account")
		"steam":
			return TranslationServer.translate("Old Steam account")
		"archived":
			return TranslationServer.translate("Archived until %s") % Tretu.date_text(float(o.get("restore_until", 0)))
	return ""

## One cloud save as a line: "Old Willow Farm · Carol · Day 80 · 9.000 gold".
static func save_line(sv: Dictionary) -> String:
	var farm := str(sv.get("farm", ""))
	var who := str(sv.get("player", ""))
	var parts: PackedStringArray = []
	parts.append(TranslationServer.translate("%s Farm") % farm if farm != "" else TranslationServer.translate("Unnamed farm"))
	if who != "":
		parts.append(who)
	parts.append(TranslationServer.translate("Day %d") % int(sv.get("day", 0)))
	parts.append(CoinLabel.text(int(sv.get("money", 0))))
	return " · ".join(parts)

static func button_text(o: Dictionary) -> String:
	if o.get("kind", "") == "archived":
		return TranslationServer.translate("Restore this farm")
	if o.get("current", false):
		return TranslationServer.translate("Keep this farm")
	return TranslationServer.translate("Play this farm")

func _fill() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	for o: Dictionary in _choice.get("options", []):
		_list.add_child(_card(o))

func _card(o: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "Farm_" + str(o.id).left(8)
	card.add_theme_stylebox_override("panel", UITheme.box(UITheme.PARCHMENT_DK if o.get("current", false) else UITheme.PARCHMENT, UITheme.WOOD, 1, 3, 5, false))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	card.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := UITheme.label(option_title(o), 10, UITheme.WOOD_DK)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	if str(o.get("name", "")) != "":
		head.add_child(UITheme.label(str(o.name), 9, UITheme.MUTED))
	var saves: Array = o.get("saves", [])
	if saves.is_empty():
		v.add_child(UITheme.label(tr("No farms in the cloud yet."), 9, UITheme.MUTED))
	for i in mini(saves.size(), 3):
		var l := UITheme.label(save_line(saves[i]), 9, UITheme.INK)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(l)
	if saves.size() > 3:
		v.add_child(UITheme.label(tr("+%d more") % (saves.size() - 3), 8, UITheme.MUTED))
	# Nothing to do on the farm you already play when nothing is waiting.
	if o.get("current", false) and not _choice.get("pending", false):
		return card
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	v.add_child(row)
	if confirming == str(o.id):
		var q := UITheme.label(tr("Keep this one and archive the others?"), 9, UITheme.HEART)
		q.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		q.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(q)
		var yes := UITheme.button(tr("Yes, keep it"), func(): _choose(str(o.id)))
		yes.name = "Confirm"
		row.add_child(yes)
		row.add_child(UITheme.button(tr("Back"), func():
			confirming = ""
			_fill()))
	else:
		var b := UITheme.button(button_text(o), func():
			confirming = str(o.id)
			_fill())
		b.name = "Pick"
		row.add_child(b)
	return card

func _choose(id: String) -> void:
	if _busy:
		return
	_busy = true
	_say(tr("Switching farms..."), true)
	var err: String = await Tretu.choose_farm(id)
	_busy = false
	if not is_inside_tree():
		return
	confirming = ""
	if err != "":
		_say(err)
		_fill()
		return
	Audio.sfx("open")
	farm_switched.emit()
	EventBus.toast.emit(tr("Farm switched. The other farm is archived for %d days.") % int(_choice.get("keep_days", 90)), "")
	closed.emit()

func _say(msg: String, good := false) -> void:
	_status.text = msg
	_status.add_theme_color_override("font_color", UITheme.LEAF if good else UITheme.HEART)
