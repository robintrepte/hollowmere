extends GutTest
## Offline parts of accounts + cloud saves (the live server is covered by tests/net/server_test).

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
	assert_eq(Net.friendly_error(NakamaException.new("Invalid credentials.", 401)), "Wrong email or password.")
	assert_eq(Net.friendly_error(NakamaException.new("", -1)), "Can't reach the Hollowmere server.")
	assert_eq(Net.friendly_error(NakamaException.new("Password must be at least 8 characters long.", 400)), "Password needs at least 8 characters.")
	assert_eq(Net.friendly_error(NakamaException.new("Email already in use.", 409)), "That name or email is already taken.")

func test_offline_by_default() -> void:
	assert_false(Net.is_online())
	assert_true(Net.is_authority(), "offline play owns its own world")

func test_social_buttons_hidden_without_oauth() -> void:
	assert_eq(Net.social_providers().size(), 0, "desktop / no web shell → no Google/Apple/Discord buttons")
	for id in ["google", "apple", "discord"]:
		var t := Art.social_icon(id)
		assert_not_null(t)
		assert_eq(t.get_width(), 16)
