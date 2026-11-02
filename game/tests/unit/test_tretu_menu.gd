extends GutTest
## In-game Tretu menu (Tretu-Credits, notifications) and "choose your farm", without a server:
## parsing of the RPC answers, the texts, and the panels built from them.
## (The RPCs themselves are covered by server/nakama/tests/.)

const T_ID := "11111111-1111-4111-8111-111111111111"
const D_ID := "22222222-2222-4222-8222-222222222222"
const A_ID := "33333333-3333-4333-8333-333333333333"

var _locale := ""

func before_each() -> void:
	_locale = TranslationServer.get_locale()
	TranslationServer.set_locale("en")

func after_each() -> void:
	TranslationServer.set_locale(_locale)

func _mk_summary(state := "ok", balance = 120, unread = 3, age = null) -> Dictionary:
	var r := {"enabled": true, "platform": true, "state": state}
	if balance != null:
		r.balance = balance
		r.currency = "TC"
	if unread != null:
		r.unread = unread
	if age != null:
		r.ageSec = age
	return Tretu.parse_summary(r)

func _mk_choice(pending := true) -> Dictionary:
	var opts := [
		{"id": T_ID, "kind": "tretu", "current": true, "name": "Carol",
			"saves": [{"slot": 0, "farm": "Tretu Acres", "player": "Carol", "day": 3, "money": 100, "savedAt": 1000}]},
	]
	if pending:
		opts.append({"id": D_ID, "kind": "discord", "current": false, "name": "carol_dc", "saves": [
			{"slot": 2, "farm": "Second Field", "player": "Carol", "day": 2, "money": 10, "savedAt": 1500},
			{"slot": 0, "farm": "Old Willow", "player": "Carol", "day": 80, "money": 9000, "befriended": 12, "savedAt": 2000},
		]})
	opts.append({"id": A_ID, "kind": "archived", "current": false, "name": "Carol", "was": "steam",
		"archivedAt": 1767225600, "restoreUntil": 1767225600 + 90 * 86400, "saves": {}})
	return Tretu.parse_farm_choice({"enabled": true, "pending": pending, "keepDays": 90, "options": opts})

func _find(root: Node, node_name: String) -> Node:
	return root.find_child(node_name, true, false)

func _texts(root: Node) -> String:
	var out: PackedStringArray = []
	for n in root.find_children("*", "", true, false):
		if n is Label or n is Button:
			out.append(n.text)
	return "\n".join(out)

# --- Parsing ----------------------------------------------------------------------------------------

func test_parse_summary_ok() -> void:
	var s := _mk_summary()
	assert_eq(s.state, "ok")
	assert_eq(s.balance, 120)
	assert_eq(s.unread, 3)

func test_parse_summary_stale_shows_age_in_minutes() -> void:
	var s := _mk_summary("stale", 90, 1, 61)
	assert_eq(s.state, "stale")
	assert_eq(s.balance, 90)
	assert_eq(s.age_min, 2, "61 s rounds up to 2 min")
	assert_eq(_mk_summary("stale", 90, 1, 5).age_min, 1, "never '0 min ago'")

func test_parse_summary_off_and_errors() -> void:
	assert_eq(Tretu.parse_summary({}).state, "", "not loaded yet")
	assert_eq(Tretu.parse_summary({"enabled": false}).state, "off")
	assert_eq(Tretu.parse_summary({"enabled": true, "platform": false}).state, "off", "platform not configured on the server")
	assert_eq(Tretu.parse_summary({"error": "Can't reach the Hollowmere server."}).state, "unavailable")
	assert_eq(_mk_summary("unavailable", null, null).balance, -1)

func test_parse_summary_ignores_odd_values() -> void:
	var s := Tretu.parse_summary({"enabled": true, "platform": true, "state": "ok", "balance": "lots", "unread": -4})
	assert_eq(s.balance, -1)
	assert_eq(s.unread, -1)
	assert_eq(s.state, "unavailable", "nothing usable -> treated as unavailable")
	assert_eq(Tretu.parse_summary({"enabled": true, "platform": true, "state": "weird", "balance": 1}).state, "unavailable")
	assert_eq(Tretu.parse_summary({"enabled": true, "platform": true, "state": "ok", "balance": 2.5, "unread": 1}).balance, -1)
	assert_eq(_mk_summary("ok", -15, 0).balance, -15, "an adjusted balance can be negative")

func test_indicator_text() -> void:
	assert_eq(Tretu.indicator_text(_mk_summary()), "120 TC · 3 new")
	assert_eq(Tretu.indicator_text(_mk_summary("ok", 5, 0)), "5 TC", "no unread, no badge")
	assert_eq(Tretu.indicator_text(_mk_summary("ok", 5, 250)), "5 TC · 99+ new")
	assert_eq(Tretu.indicator_text(_mk_summary("unavailable", null, null)), "")
	assert_eq(Tretu.indicator_text(Tretu.parse_summary({})), "")
	assert_eq(Tretu.unread_badge(0), "")
	assert_eq(Tretu.unread_badge(7), "7")

func test_indicator_text_in_german() -> void:
	TranslationServer.set_locale("de")
	assert_eq(Tretu.indicator_text(_mk_summary("ok", 1234, 2)), "1.234 TC · 2 neu")
	assert_eq(Tretu.date_text(1767225600 + 30 * 86400), "31.1.2026")

func test_links_point_at_tretu_de() -> void:
	assert_eq(Tretu.wallet_url(), "https://tretu.de/wallet")
	assert_eq(Tretu.notifications_url(), "https://tretu.de/benachrichtigungen")

func test_parse_farm_choice() -> void:
	var c := _mk_choice()
	assert_true(c.pending)
	assert_eq(c.keep_days, 90)
	assert_eq(c.options.size(), 3)
	var dc: Dictionary = c.options[1]
	assert_eq(dc.kind, "discord")
	assert_eq(dc.saves[0].farm, "Old Willow", "newest save first")
	assert_eq(dc.saves[0].befriended, 12)
	assert_eq((c.options[2].saves as Array).size(), 0, "an empty Lua table arrives as {}: no saves")
	assert_eq(Tretu.other_farms(c).size(), 2)
	assert_eq(Tretu.archived_farms(c).size(), 1)
	assert_eq(Tretu.date_text(c.options[2].restore_until), "2026-04-01")

func test_parse_farm_choice_drops_bad_entries() -> void:
	var c := Tretu.parse_farm_choice({"enabled": true, "pending": true, "options": [
		{"id": "short", "kind": "tretu"}, {"id": D_ID, "kind": "minecraft"}, "nope", {"id": D_ID, "kind": "steam", "current": "yes"},
	]})
	assert_eq(c.options.size(), 1)
	assert_false(c.options[0].current, "only a real true counts")
	assert_eq(Tretu.parse_farm_choice({"enabled": false, "pending": true}).pending, false)
	assert_eq(Tretu.parse_farm_choice({"enabled": true, "options": {}}).options.size(), 0)

func test_session_change_clears_the_menu() -> void:
	Tretu.summary = _mk_summary()
	Tretu.farm_choice = _mk_choice()
	Tretu._on_session_changed(false)
	assert_eq(Tretu.summary.state, "")
	assert_false(Tretu.farm_choice.pending)

func test_account_button_text() -> void:
	assert_eq(TitleScreen.account_text(false, "", false, {}), "Sign in")
	assert_eq(TitleScreen.account_text(true, "Mia", false, _mk_summary()), "● Mia", "no Tretu numbers for other accounts")
	assert_eq(TitleScreen.account_text(true, "Mia", true, _mk_summary()), "● Mia  ·  120 TC · 3 new")
	assert_eq(TitleScreen.account_text(true, "Mia", true, Tretu.parse_summary({})), "● Mia", "still loading")

# --- Tretu menu in the account panel ----------------------------------------------------------------

func _menu(s: Dictionary, c: Dictionary = {}) -> TretuMenu:
	var m := TretuMenu.new()
	add_child_autofree(m)
	m.rebuild(s, c if not c.is_empty() else Tretu.parse_farm_choice({}))
	return m

func test_menu_shows_balance_and_unread() -> void:
	var m := _menu(_mk_summary())
	assert_eq((_find(m, "Credits") as Label).text, "Tretu-Credits: 120 TC")
	assert_eq((_find(m, "Unread") as Label).text, "3 new notifications")
	assert_null(_find(m, "Note"), "no warning while everything is fine")
	assert_null(_find(m, "FarmNotice"))
	assert_eq((_find(_menu(_mk_summary("ok", 0, 1)), "Unread") as Label).text, "1 new notification")
	assert_eq((_find(_menu(_mk_summary("ok", 0, 0)), "Unread") as Label).text, "No new notifications")

func test_menu_links_open_wallet_and_notifications() -> void:
	var m := _menu(_mk_summary())
	watch_signals(m)
	var urls: Array = []
	for b in m.find_children("*", "Button", true, false):
		if b.has_meta("url"):
			urls.append(b.get_meta("url"))
	assert_has(urls, "https://tretu.de/wallet")
	assert_has(urls, "https://tretu.de/benachrichtigungen")
	for b in m.find_children("*", "Button", true, false):
		if b.has_meta("url") and b.get_meta("url") == "https://tretu.de/wallet":
			b.pressed.emit()
	assert_signal_emitted_with_parameters(m, "link_requested", ["https://tretu.de/wallet"])

func test_menu_when_the_platform_is_down() -> void:
	var stale := _menu(_mk_summary("stale", 90, 2, 300))
	assert_eq((_find(stale, "Credits") as Label).text, "Tretu-Credits: 90 TC", "last good value stays visible")
	assert_string_contains((_find(stale, "Note") as Label).text, "5 min ago")
	var down := _menu(_mk_summary("unavailable", null, null))
	assert_eq((_find(down, "Credits") as Label).text, "Tretu-Credits: –")
	assert_string_contains((_find(down, "Note") as Label).text, "not reachable")
	var off := _menu(Tretu.parse_summary({"enabled": true, "platform": false}))
	assert_null(_find(off, "Credits"))
	assert_string_contains((_find(off, "Note") as Label).text, "not set up")
	assert_string_contains((_find(_menu(Tretu.parse_summary({})), "Note") as Label).text, "Loading")

func test_menu_offers_the_farm_choice() -> void:
	var m := _menu(_mk_summary(), _mk_choice(true))
	watch_signals(m)
	assert_eq((_find(m, "FarmNotice") as Label).text, "Your old Discord account has a farm too. Choose which one to keep.")
	var b := _find(m, "ChooseFarm") as Button
	assert_eq(b.text, "Choose a farm")
	b.pressed.emit()
	assert_signal_emitted(m, "choose_farm_requested")
	var later := _menu(_mk_summary(), _mk_choice(false))
	assert_eq((_find(later, "FarmNotice") as Label).text, "An archived farm can be restored until 2026-04-01.")
	assert_eq((_find(later, "ChooseFarm") as Button).text, "Archived farms")

func test_menu_text_in_german() -> void:
	TranslationServer.set_locale("de")
	var m := _menu(_mk_summary("ok", 1500, 4), _mk_choice(true))
	assert_eq((_find(m, "Credits") as Label).text, "Tretu-Credits: 1.500 TC")
	assert_eq((_find(m, "Unread") as Label).text, "4 neue Benachrichtigungen")
	assert_string_contains(_texts(m), "Wallet")
	assert_string_contains(_texts(m), "Mein Konto")
	assert_eq((_find(m, "FarmNotice") as Label).text, "Dein altes Discord-Konto hat auch eine Farm. Wähle, welche du behalten willst.")

# --- Choose your farm -------------------------------------------------------------------------------

func test_farm_card_texts() -> void:
	var c := _mk_choice()
	assert_eq(FarmChoicePanel.option_title(c.options[0]), "Tretu-Konto (playing now)")
	assert_eq(FarmChoicePanel.option_title(c.options[1]), "Old Discord account")
	assert_eq(FarmChoicePanel.option_title(c.options[2]), "Archived until 2026-04-01")
	var line := FarmChoicePanel.save_line(c.options[1].saves[0])
	assert_string_contains(line, "Old Willow Farm")
	assert_string_contains(line, "Day 80")
	assert_string_contains(line, "9,000")
	assert_eq(FarmChoicePanel.button_text(c.options[0]), "Keep this farm")
	assert_eq(FarmChoicePanel.button_text(c.options[1]), "Play this farm")
	assert_eq(FarmChoicePanel.button_text(c.options[2]), "Restore this farm")
	assert_string_contains(FarmChoicePanel.intro_text(c), "old Discord account")
	assert_string_contains(FarmChoicePanel.intro_text(c), "90 days")

func test_farm_panel_lists_every_farm_and_asks_before_switching() -> void:
	var p := FarmChoicePanel.new(_mk_choice(true))
	add_child_autofree(p)
	var all := _texts(p)
	assert_string_contains(all, "Tretu Acres Farm")
	assert_string_contains(all, "Old Willow Farm")
	assert_string_contains(all, "No farms in the cloud yet.", "the archived farm has no saves")
	assert_string_contains(all, "Decide later")
	var picks := p.find_children("Pick", "Button", true, false)
	assert_eq(picks.size(), 3, "every farm can be kept while the choice is open")
	(picks[1] as Button).pressed.emit()
	assert_eq(p.confirming, D_ID)
	assert_not_null(_find(p, "Confirm"), "second click needed")

func test_failed_switch_keeps_the_panel_open_with_a_message() -> void:
	var p := FarmChoicePanel.new(_mk_choice(true))
	add_child_autofree(p)
	watch_signals(p)
	p.confirming = D_ID
	p._fill()
	(_find(p, "Confirm") as Button).pressed.emit()
	await wait_until(func(): return not p._busy, 5.0)
	assert_signal_not_emitted(p, "farm_switched")
	assert_signal_not_emitted(p, "closed")
	assert_string_contains(p._status.text, "Tretu-Konto first", "not signed in with Tretu here")
	assert_eq(p.confirming, "")

func test_nothing_to_click_on_the_current_farm_once_decided() -> void:
	var p := FarmChoicePanel.new(_mk_choice(false))
	add_child_autofree(p)
	var picks := p.find_children("Pick", "Button", true, false)
	assert_eq(picks.size(), 1, "only the archived farm has a button")
	assert_eq((picks[0] as Button).text, "Restore this farm")
	assert_string_contains(_texts(p), "Close")

# --- Errors -----------------------------------------------------------------------------------------

func test_rpc_errors_use_the_servers_words() -> void:
	assert_eq(Net.rpc_error(NakamaException.new("That farm is not one of yours.", 404)), "That farm is not one of yours.",
		"not the email-login text for 404")
	assert_eq(Net.rpc_error(NakamaException.new("x", 401)), "Sign-in expired, please sign in again.")
	assert_eq(Net.rpc_error(NakamaException.new("", -1)), "Can't reach the Hollowmere server.")
	assert_eq(Net.rpc_error(NakamaException.new("x", 429)), "Too many tries. Wait a minute and try again.")
	assert_eq(Net.rpc_error(NakamaException.new("runtime error: attempt to index nil", 500)), "Something went wrong.",
		"internal errors are not shown")
	assert_eq(Net.rpc_error(NakamaException.new("Could not switch farms right now. Nothing was changed.", 500)),
		"Could not switch farms right now. Nothing was changed.")
	TranslationServer.set_locale("de")
	assert_eq(Net.rpc_error(NakamaException.new("That farm is not one of yours.", 404)), "Diese Farm gehört nicht zu deinen Konten.")

func test_archived_account_login_message() -> void:
	assert_string_contains(Net.friendly_error(NakamaException.new("User account banned.", 403)), "archived")
	assert_eq(Net.friendly_error(NakamaException.new("Tretu sign-in is not reachable right now.", 503)), "Tretu sign-in is not reachable right now.")
