extends GutTest
## Offline parts of accounts + cloud saves (the live server is covered by tests/net/server_test),
## and the account panel: "Mit Tretu-Konto anmelden" is the only account sign-in, guests stay.

const SLOT := 5

var _had_local := false
var _backup := {}

func before_each() -> void:
	_had_local = FileAccess.file_exists(SaveManager.slot_path(SLOT))
	_backup = SaveManager.read_payload(SLOT)

func after_each() -> void:
	if _had_local:
		SaveManager.install_payload(SLOT, _backup)
	else:
		for suffix in ["", ".bak", ".tmp"]:
			DirAccess.remove_absolute(SaveManager.slot_path(SLOT) + suffix)

func _payload(saved_at: float, farm := "Cloud") -> Dictionary:
	return {"version": 1, "meta": {"farm": farm, "saved_at": saved_at, "day": 5}, "state": {"marker": farm}}

func test_cloud_save_missing_locally_is_newer() -> void:
	for suffix in ["", ".bak"]:
		DirAccess.remove_absolute(SaveManager.slot_path(SLOT) + suffix)
	var cloud := [{"slot": SLOT, "meta": _payload(100).meta, "payload": _payload(100)}]
	assert_eq(SaveManager.newer_in_cloud(cloud).size(), 1)

func test_older_or_equal_cloud_save_is_ignored() -> void:
	assert_true(SaveManager.install_payload(SLOT, _payload(500, "Local")))
	var older := [{"slot": SLOT, "meta": _payload(400).meta, "payload": _payload(400)}]
	var same := [{"slot": SLOT, "meta": _payload(500.5).meta, "payload": _payload(500.5)}]
	assert_eq(SaveManager.newer_in_cloud(older).size(), 0)
	assert_eq(SaveManager.newer_in_cloud(same).size(), 0, "sub-second drift is not a conflict")

func test_newer_cloud_save_installs_with_backup() -> void:
	assert_true(SaveManager.install_payload(SLOT, _payload(500, "Local")))
	var cloud := [{"slot": SLOT, "meta": _payload(900).meta, "payload": _payload(900)}]
	var newer := SaveManager.newer_in_cloud(cloud)
	assert_eq(newer.size(), 1)
	assert_true(SaveManager.install_payload(SLOT, newer[0].payload))
	assert_eq(SaveManager.read_payload(SLOT).state.marker, "Cloud")
	assert_true(FileAccess.file_exists(SaveManager.slot_path(SLOT) + ".bak"), "previous local save kept as .bak")

func test_install_rejects_payload_without_state() -> void:
	assert_false(SaveManager.install_payload(SLOT, {"meta": {}}))

func test_friendly_errors() -> void:
	assert_eq(Net.friendly_error(NakamaException.new("", -1)), "Can't reach the Hollowmere server.")
	assert_eq(Net.friendly_error(NakamaException.new("Token expired.", 401)), "Sign-in expired, please sign in again.")
	assert_eq(Net.friendly_error(NakamaException.new("Username is already in use.", 409)), "That name is already taken.")
	# An old client calling a removed sign-in gets the server's own, translatable text.
	assert_eq(Net.friendly_error(NakamaException.new("This sign-in is no longer available. Sign in with your Tretu account.", 400)),
		"This sign-in is no longer available. Sign in with your Tretu account.")
	assert_eq(Net.tretu_error(NakamaException.new("This farm already belongs to another Tretu-Konto.", 400)),
		"This farm already belongs to another Tretu-Konto.")
	assert_eq(Net.tretu_error(NakamaException.new("Tretu sign-in is not reachable right now.", 503)), "Can't reach the Tretu sign-in right now.")
	assert_eq(Net.tretu_error(NakamaException.new("invalid token", 401)), "Tretu sign-in failed.")

func test_offline_by_default() -> void:
	assert_false(Net.is_online())
	assert_true(Net.is_authority(), "offline play owns its own world")

func test_removed_sign_ins_are_gone() -> void:
	for m in ["login_email", "link_email", "login_google", "login_apple", "login_discord", "social_providers"]:
		assert_false(Net.has_method(m), "Net.%s was removed (Tretu-Konto only)" % m)
	assert_true(Net.has_method("login_tretu") and Net.has_method("login_device"))

# --- Account panel --------------------------------------------------------------------------------

var _net_keep := {}
var _tretu_keep := {}

func _keep_account_state() -> void:
	_net_keep = {"session": Net.session, "is_guest": Net.is_guest, "is_tretu": Net.is_tretu, "display_name": Net.display_name, "account_id": Net.account_id}
	for k in ["auth_issuer", "client_id"]:
		_tretu_keep[k] = ProjectSettings.get_setting("tretu/" + k, "")

func _restore_account_state() -> void:
	for k in _net_keep:
		Net.set(k, _net_keep[k])
	for k in _tretu_keep:
		ProjectSettings.set_setting("tretu/" + k, _tretu_keep[k])

## A signed-in session without a server (a JWT that is valid for an hour).
func _fake_session(uid: String, name: String) -> NakamaSession:
	var b64 := func(d: Dictionary) -> String: return Marshalls.utf8_to_base64(JSON.stringify(d)).replace("+", "-").replace("/", "_").replace("=", "")
	var exp := int(Time.get_unix_time_from_system()) + 3600
	var jwt := "%s.%s.sig" % [b64.call({"alg": "HS256", "typ": "JWT"}), b64.call({"uid": uid, "usn": name, "exp": exp, "iat": exp - 3600})]
	return NakamaSession.new(jwt, false, null)

func _panel() -> AccountPanel:
	var p := AccountPanel.new()
	add_child_autofree(p)
	return p

func _buttons(root: Node) -> Array:
	return root.find_children("*", "Button", true, false).filter(func(b): return not b is CheckBox)

func _texts(root: Node) -> PackedStringArray:
	var out: PackedStringArray = []
	for b in _buttons(root):
		out.append((b as Button).text)
	return out

func test_signed_out_panel_offers_only_tretu_and_guest() -> void:
	_keep_account_state()
	Net.session = null
	var p := _panel()
	var tretu := p.find_child("TretuButton", true, false) as Button
	assert_not_null(tretu, "Mit Tretu-Konto anmelden")
	assert_eq(tretu.text, "Sign in with Tretu")
	assert_not_null(tretu.icon)
	assert_not_null(p.find_child("GuestButton", true, false), "guest play stays")
	var texts := _texts(p)
	for gone in ["Google", "Apple", "Discord", "Sign in", "Create account", "Add email to this account"]:
		assert_false(gone in texts, "no %s button" % gone)
	for e in p.find_children("*", "LineEdit", true, false):
		assert_false((e as LineEdit).secret, "no password field")
		assert_false((e as LineEdit).placeholder_text.contains("Email"), "no email field")
	_restore_account_state()

func test_guest_panel_offers_save_to_tretu() -> void:
	_keep_account_state()
	Net.session = _fake_session("44444444-4444-4444-8444-444444444444", "Farmer 1234")
	Net.is_guest = true
	Net.is_tretu = false
	Net.display_name = "Farmer 1234"
	assert_true(Net.has_session())
	var p := _panel()
	var save := p.find_child("TretuButton", true, false) as Button
	assert_not_null(save, "a guest can save the farm to the Tretu-Konto")
	assert_eq(save.text, "Save to Tretu-Konto")
	assert_false("Add email to this account" in _texts(p))
	assert_null(p.find_child("TretuMenu", true, false), "no Tretu menu before the upgrade")
	_restore_account_state()

func test_tretu_panel_has_menu_and_no_upgrade() -> void:
	_keep_account_state()
	Net.session = _fake_session("55555555-5555-4555-8555-555555555555", "mia")
	Net.is_guest = false
	Net.is_tretu = true
	Net.display_name = "mia"
	var p := _panel()
	assert_null(p.find_child("TretuButton", true, false), "already a Tretu-Konto")
	assert_not_null(p.find_child("TretuMenu", true, false))
	_restore_account_state()

func test_build_without_tretu_config_says_so() -> void:
	_keep_account_state()
	Net.session = null
	ProjectSettings.set_setting("tretu/auth_issuer", "")
	var p := _panel()
	assert_null(p.find_child("TretuButton", true, false))
	var labels: PackedStringArray = []
	for l in p.find_children("*", "Label", true, false):
		labels.append((l as Label).text)
	assert_true("Tretu sign-in is not set up for this build." in labels, "a clear message instead of a missing button")
	assert_not_null(p.find_child("GuestButton", true, false), "guest play still works")
	_restore_account_state()

func test_only_the_tretu_mark_is_drawn() -> void:
	var t := Art.social_icon("tretu")
	assert_eq(t.get_width(), 16)
	assert_false(t.get_image().is_invisible(), "Tretu mark drawn")
	assert_true(Art.social_icon("google").get_image().is_invisible(), "no Google mark any more")
