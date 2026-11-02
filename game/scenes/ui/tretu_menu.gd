class_name TretuMenu
extends VBoxContainer
## The Tretu part of the account panel for players signed in with a Tretu-Konto:
## Tretu-Credits balance, unread notifications, links to tretu.de, Mein Konto / profile,
## and the "choose a farm" notice when an old Discord / Steam farm is still waiting.
## Built only from Tretu.summary / Tretu.farm_choice, so it can be filled without a server (tests).

## Player asked to see the farm chooser.
signal choose_farm_requested
## A link button was pressed (the account panel opens it; tests read it).
signal link_requested(url: String)

func _ready() -> void:
	add_theme_constant_override("separation", 3)
	rebuild()
	Tretu.summary_changed.connect(rebuild)

## Rebuilds from the current Tretu state (or the given one).
func rebuild(summary: Dictionary = {}, choice: Dictionary = {}) -> void:
	var s: Dictionary = summary if not summary.is_empty() else Tretu.summary
	var c: Dictionary = choice if not choice.is_empty() else Tretu.farm_choice
	for ch in get_children():
		remove_child(ch)
		ch.queue_free()
	add_child(UITheme.label("Tretu-Konto", 11, UITheme.WOOD_DK))
	var state := str(s.get("state", ""))
	if state == "off":
		_note(tr("Tretu-Credits and notifications are not set up on this server."))
	elif state == "":
		_note(tr("Loading your Tretu-Credits..."))
	else:
		var r1 := _row()
		var bal := int(s.get("balance", -1))
		var credits := UITheme.label(tr("Tretu-Credits: %s") % (Tretu.credits_text(bal) if bal >= 0 else "–"), 10, UITheme.INK)
		credits.name = "Credits"
		credits.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r1.add_child(credits)
		r1.add_child(_link(tr("Wallet"), Tretu.wallet_url()))
		var r2 := _row()
		var unread := int(s.get("unread", -1))
		var txt := tr("Notifications")
		if unread == 0:
			txt = tr("No new notifications")
		elif unread == 1:
			txt = tr("1 new notification")
		elif unread > 1:
			txt = tr("%s new notifications") % Tretu.unread_badge(unread)
		var nl := UITheme.label(txt, 10, UITheme.HEART if unread > 0 else UITheme.INK)
		nl.name = "Unread"
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r2.add_child(nl)
		r2.add_child(_link(tr("Open"), Tretu.notifications_url()))
		if state == "stale":
			_note(tr("As of %d min ago: tretu.de is not reachable right now.") % int(s.get("age_min", 1)))
		elif state == "unavailable":
			_note(tr("tretu.de is not reachable right now. Try again later."))
	_farm_notice(c)
	var r3 := _row()
	r3.add_child(_link(tr("My account"), Tretu.account_url()))
	var profile := Tretu.profile_url(Tretu.profile_username)
	if profile != "":
		r3.add_child(_link(tr("Tretu profile"), profile))
	_farm_button(c, r3)

## Notice above the buttons when another farm is waiting (or one can be restored).
func _farm_notice(c: Dictionary) -> void:
	var txt := farm_notice_text(c)
	if txt == "":
		return
	var l := UITheme.label(txt, 9, UITheme.HEART if c.get("pending", false) else UITheme.MUTED)
	l.name = "FarmNotice"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(300, 0)
	add_child(l)

func _farm_button(c: Dictionary, row: HBoxContainer) -> void:
	if farm_notice_text(c) == "":
		return
	var b := UITheme.button(tr("Choose a farm") if c.get("pending", false) else tr("Archived farms"), func(): choose_farm_requested.emit())
	b.name = "ChooseFarm"
	row.add_child(b)

static func farm_notice_text(c: Dictionary) -> String:
	var others := Tretu.other_farms(c)
	var waiting := others.filter(func(o): return o.kind != "archived")
	if c.get("pending", false) and not waiting.is_empty():
		return TranslationServer.translate("Your old %s account has a farm too. Choose which one to keep.") % Tretu.provider_name(str(waiting[0].kind))
	var arch := Tretu.archived_farms(c)
	if arch.is_empty():
		return ""
	return TranslationServer.translate("An archived farm can be restored until %s.") % Tretu.date_text(float(arch[0].restore_until))

func _row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	add_child(h)
	return h

func _note(text: String) -> void:
	var l := UITheme.label(text, 8, UITheme.MUTED)
	l.name = "Note"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(300, 0)
	add_child(l)

func _link(text: String, url: String) -> Button:
	var b := UITheme.button(text, func(): link_requested.emit(url))
	b.set_meta("url", url)
	return b
