extends Node
## Online layer: Nakama accounts/cloud saves and co-op sessions.
## Co-op transport is either Nakama relayed matches (works in browsers) or ENet (LAN/tests).
## The host owns the simulation; clients send action requests and receive state.

signal session_changed(logged_in: bool)
signal coop_started(is_host: bool)
signal coop_ended(reason: String)
signal peer_joined(pid: String, name: String)
signal peer_left(pid: String)
signal chat_received(from_name: String, text: String)

const ENET_PORT := 24680

var client: NakamaClient
var session: NakamaSession
var socket: NakamaSocket
var bridge: NakamaMultiplayerBridge
var account_id: String = ""
var display_name: String = ""
var mode: String = "offline"   ## offline | host | client
var match_code: String = ""
## peer_id (int) -> {pid, name}
var peers: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)

func _make_client() -> void:
	if client:
		return
	var host := Settings.server_host
	var port := Settings.server_port
	var ssl := Settings.server_ssl
	## The web build talks to the server that served it (nginx proxies /v2 and /ws to Nakama).
	if OS.get_name() == "Web" and host == Settings.default_server("host", "127.0.0.1"):
		var loc := str(JavaScriptBridge.eval("location.hostname", true))
		if loc != "":
			host = loc
			ssl = str(JavaScriptBridge.eval("location.protocol", true)) == "https:"
			var p := str(JavaScriptBridge.eval("location.port", true))
			port = int(p) if p.is_valid_int() else (443 if ssl else 80)
	client = Nakama.create_client(Settings.server_key, host, port, "https" if ssl else "http", 10, NakamaLogger.LOG_LEVEL.ERROR)

## Drops the client so the next call picks up changed server settings.
func reset_client() -> void:
	client = null
	session = null
	socket = null
	bridge = null

func server_label() -> String:
	_make_client()
	return "%s:%d" % [client.host, client.port]

func ping_server() -> bool:
	_make_client()
	# HTTPRequest counts its timeout in frame time: the first frames after a slow start can be
	# seconds long and end the request at once. Only a timeout in wall-clock time counts.
	var started := Time.get_ticks_msec()
	for attempt in 3:
		var req := HTTPRequest.new()
		req.timeout = 4.0
		req.accept_gzip = false
		add_child(req)
		if req.request("%s://%s:%d/healthcheck" % [client.scheme, client.host, client.port]) != OK:
			req.queue_free()
			return false
		var r: Array = await req.request_completed
		req.queue_free()
		if int(r[0]) == HTTPRequest.RESULT_TIMEOUT and Time.get_ticks_msec() - started < 4000:
			continue
		return int(r[0]) == HTTPRequest.RESULT_SUCCESS and int(r[1]) == 200
	return false

func call_rpc(id: String, payload: Dictionary = {}) -> Dictionary:
	if not has_session():
		return {"error": TranslationServer.translate("Sign in first.")}
	var res = await client.rpc_async(session, id, JSON.stringify(payload))
	if res.is_exception():
		return {"error": rpc_error(res.get_exception())}
	var j = JSON.parse_string(res.payload) if res.payload != "" else {}
	return j if j is Dictionary else {}

## Messages the Hollowmere server module sends to players (hollowmere.lua, tretu.lua), listed here
## so they are extracted and translated like every other UI text.
const SERVER_TEXT := {
	"coop_closed": "that farm isn't open right now",
	"coop_code": "codes are 6 letters",
	"removed": "This sign-in is no longer available. Sign in with your Tretu account.",
	"taken": "This farm already belongs to another Tretu-Konto.",
	"tretu_first": "Sign in with your Tretu account first.",
	"tretu_again": "Sign in with your Tretu account again.",
	"tretu_down": "Tretu sign-in is not reachable right now.",
	"busy": "Too many requests, try again in a minute.",
	"pick": "Pick one of your farms.",
	"not_yours": "That farm is not one of yours.",
	"changed": "Your accounts changed in the meantime. Please look again.",
	"no_switch": "Could not switch farms right now. Nothing was changed.",
}

## Errors from RPCs: transport problems get a fixed text, the server's own message otherwise.
static func rpc_error(ex: NakamaException) -> String:
	match ex.status_code:
		-1, 0, 502, 504:
			return TranslationServer.translate("Can't reach the Hollowmere server.")
		401:
			return TranslationServer.translate("Sign-in expired, please sign in again.")
		429:
			return TranslationServer.translate("Too many tries. Wait a minute and try again.")
	if ex.message == "" or ex.status_code >= 500 and not ex.message in SERVER_TEXT.values():
		return TranslationServer.translate("Something went wrong.") if ex.status_code != 503 \
			else TranslationServer.translate("Can't reach the Hollowmere server.")
	return TranslationServer.translate(ex.message)

## Errors from sign-in calls (Tretu-Konto, guest) and renaming.
static func friendly_error(ex: NakamaException) -> String:
	var m: String = ex.message
	if m.contains("not reachable") or m in SERVER_TEXT.values():
		return TranslationServer.translate(m)
	match ex.status_code:
		-1, 0, 503:
			return TranslationServer.translate("Can't reach the Hollowmere server.")
		401:
			return TranslationServer.translate("Sign-in expired, please sign in again.")
		409:
			return TranslationServer.translate("That name is already taken.")
		429:
			return TranslationServer.translate("Too many tries. Wait a minute and try again.")
	if m.contains("banned"):
		return TranslationServer.translate("This account was archived when you picked a farm for your Tretu-Konto. Sign in with Tretu instead.")
	if m.contains("Username"):
		return TranslationServer.translate("Names can use letters, numbers and _ (up to 20).")
	return TranslationServer.translate(m) if m != "" else TranslationServer.translate("Something went wrong.")

func local_id() -> String:
	if mode == "client":
		return account_id if account_id != "" else "peer_%d" % multiplayer.get_unique_id()
	return "local"

func is_authority() -> bool:
	return mode != "client"

func is_online() -> bool:
	return mode != "offline"

func has_session() -> bool:
	return session != null and not session.is_expired()

# --- Accounts ----------------------------------------------------------------------------

## Guest play: an account for this device only (no sign-in). "Save to Tretu-Konto" upgrades it.
func login_device(device_id: String = "") -> String:
	_make_client()
	var dev := device_id if device_id != "" else _device_id()
	var s: NakamaSession = await client.authenticate_device_async(dev, null, true)
	return await _finish_login(s)

## Tretu-Konto, the only account sign-in: the server hook asks auth.tretu.de who the access token
## belongs to and signs into "tretu:<sub>". An old Hollowmere account of the same player (legacy_ids,
## Discord, Steam) is carried over on the first login. See autoload/tretu.gd.
## Signed in as a guest (or an old account): the Tretu-Konto is linked to THIS account first, so its
## farms continue as the Tretu farms ("Save to Tretu-Konto"). If the Tretu-Konto already has a
## Hollowmere account, this is a normal sign-in (the guest's farms stay on this device).
func login_tretu(access_token: String) -> String:
	_make_client()
	if has_session() and not is_tretu:
		var linked := await _link_tretu(access_token)
		if linked != "":
			return linked
	var s: NakamaSession = await client.authenticate_custom_async("tretu-login", null, true, {"tretu_token": access_token})
	if s != null and s.is_exception():
		return tretu_error(s.get_exception())
	return await _finish_login(s)

## Links the Tretu-Konto to the signed-in (guest) account. "" = linked, or nothing to link because the
## Tretu-Konto already has a farm (AlreadyExists); otherwise the error to show.
func _link_tretu(access_token: String) -> String:
	var body := NakamaAPI.ApiAccountCustom.create(NakamaAPI, {"id": "tretu-link", "vars": {"tretu_token": access_token}})
	var res: NakamaAsyncResult = await client._api_client.link_custom_async(session, body)
	if not res.is_exception():
		return ""
	var ex := res.get_exception()
	if ex.status_code == 409 or ex.grpc_status_code == 6:
		return ""
	return tretu_error(ex)

## Errors from a Tretu sign-in (or guest upgrade) -> text for the account panel.
static func tretu_error(ex: NakamaException) -> String:
	if ex.message.contains("not reachable"):
		return TranslationServer.translate("Can't reach the Tretu sign-in right now.")
	if ex.status_code in [400, 401, 403]:
		if ex.message.contains("not enabled"):
			return TranslationServer.translate("Tretu sign-in is not enabled on this server.")
		if ex.message.contains("banned") or ex.message in SERVER_TEXT.values() or ex.message.contains("locked"):
			return friendly_error(ex)
		return TranslationServer.translate("Tretu sign-in failed.")
	return friendly_error(ex)

## After choosing another farm: redeem the server's one-time ticket for a normal login of that farm.
func login_tretu_switch(ticket: String) -> String:
	_make_client()
	var s: NakamaSession = await client.authenticate_custom_async("tretu-switch", null, false, {"tretu_switch": ticket})
	return await _finish_login(s)

## A session the server minted for this player (fallback when the switch ticket could not be
## redeemed). Has no refresh token.
func adopt_session(token: String) -> String:
	_make_client()
	var s := NakamaSession.new(token, false, null)
	if not s.valid or s.is_expired():
		return tr("Sign in with your Tretu-Konto again.")
	if mode == "offline":
		socket = null
		bridge = null
	return await _finish_login(s)

func web_oauth_token(which: String) -> String:
	if OS.get_name() != "Web":
		return ""
	var key := "hollowmere%sToken" % which.capitalize()
	return str(JavaScriptBridge.eval("window.%s || ''" % key, true))

func web_oauth_error(which: String) -> String:
	if OS.get_name() != "Web":
		return ""
	return str(JavaScriptBridge.eval("window.hollowmere%sError || ''" % which.capitalize(), true))

## Farm code from a join link (https://hollowmere.tretu.de/?join=K7QM2D, sent as the presence
## joinUrl on tretu.de while a Tretu player hosts). "" when there is none.
func web_join_code() -> String:
	if OS.get_name() != "Web":
		return ""
	var raw := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('join') || ''", true))
	var code := ""
	for ch in raw.to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			code += ch
	return code if code.length() == 6 else ""

func _finish_login(s: NakamaSession) -> String:
	if s == null:
		return "Can't reach the Hollowmere server."
	if s.is_exception():
		return friendly_error(s.get_exception())
	session = s
	account_id = s.user_id
	display_name = s.username
	_save_refresh(s)
	await _load_account()
	session_changed.emit(true)
	Settings.sync_profile()
	TimeService.sync_server()
	return ""

## Guest (device-only) account. "Save to Tretu-Konto" links it (or an old email / Google / Apple /
## Discord account whose session is still stored) to the Tretu-Konto: see login_tretu.
var is_guest: bool = false
## Signed in with a Tretu-Konto (custom id "tretu:<sub>"): presence and stats go to tretu.de.
var is_tretu: bool = false

func _load_account() -> void:
	var acc = await client.get_account_async(session)
	if acc.is_exception():
		return
	is_tretu = acc.custom_id.begins_with("tretu:")
	is_guest = acc.email == "" and acc.user.google_id == "" and acc.user.apple_id == "" and acc.custom_id == ""
	if is_tretu:
		# Kept current by the platform's user.updated webhook (server side).
		var meta = JSON.parse_string(str(acc.user.metadata)) if str(acc.user.metadata) != "" else null
		if meta is Dictionary and str(meta.get("tretu_username", "")) != "":
			Tretu.profile_username = str(meta.tretu_username)
	if acc.user.display_name != "":
		display_name = acc.user.display_name
	else:
		var nm: String = "Farmer %d" % randi_range(1000, 9999) if is_guest else acc.user.username
		if not (await client.update_account_async(session, null, nm)).is_exception():
			display_name = nm

func set_display_name(nm: String) -> String:
	if not has_session():
		return "Sign in first."
	var res = await client.update_account_async(session, null, nm)
	if res.is_exception():
		return friendly_error(res.get_exception())
	display_name = nm
	session_changed.emit(true)
	return ""

## Restores the saved Nakama session; without one, a stored Tretu login signs in silently.
func try_restore_session() -> bool:
	if await _restore_nakama_session():
		return true
	if Tretu.enabled():
		return await Tretu.silent_sign_in()
	return false

## The session saved on this device, if it is still valid (no Tretu silent sign-in).
func restore_saved_session() -> bool:
	return await _restore_nakama_session()

func _restore_nakama_session() -> bool:
	_make_client()
	var cfg := ConfigFile.new()
	if cfg.load("user://session.cfg") != OK:
		return false
	var tok: String = cfg.get_value("s", "token", "")
	var ref: String = cfg.get_value("s", "refresh", "")
	if tok == "":
		return false
	var s := NakamaSession.new(tok, false, ref if ref != "" else null)
	if s.is_expired():
		if ref == "" or s.is_refresh_expired():
			return false
		s = await client.session_refresh_async(s)
	if s == null or s.is_exception() or s.is_expired():
		return false
	session = s
	account_id = s.user_id
	display_name = s.username
	_save_refresh(s)
	await _load_account()
	session_changed.emit(true)
	Settings.sync_profile()
	TimeService.sync_server()
	return true

func logout() -> void:
	if is_tretu and has_session():
		await call_rpc("tretu_offline")
	if is_tretu:
		Tretu.forget_tokens()
	if client and session:
		await client.session_logout_async(session)
	session = null
	account_id = ""
	display_name = ""
	is_guest = false
	is_tretu = false
	DirAccess.remove_absolute("user://session.cfg")
	session_changed.emit(false)

func _save_refresh(s: NakamaSession) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("s", "token", s.token)
	cfg.set_value("s", "refresh", s.refresh_token)
	cfg.save("user://session.cfg")

func _device_id() -> String:
	var cfg := ConfigFile.new()
	cfg.load("user://device.cfg")
	var id: String = cfg.get_value("d", "id", "")
	if id == "":
		id = OS.get_unique_id() if OS.get_name() != "Web" else ""
		if id == "":
			id = "%08x%08x%08x" % [randi(), randi(), randi()]
		cfg.set_value("d", "id", id)
		cfg.save("user://device.cfg")
	return id

# --- Cloud saves -------------------------------------------------------------------------------

signal cloud_synced(ok: bool, message: String)

func cloud_save(slot: int, payload: Dictionary) -> bool:
	if not has_session():
		return false
	var obj := NakamaWriteStorageObject.new("saves", "slot_%d" % slot, 1, 1, JSON.stringify(SaveManager.pack_cloud(payload)), "")
	var res = await client.write_storage_objects_async(session, [obj])
	if res.is_exception():
		var msg := friendly_error(res.get_exception())
		push_warning("Cloud save failed: %s" % msg)
		cloud_synced.emit(false, msg)
		return false
	cloud_synced.emit(true, "")
	return true

## [{slot, meta, payload}] for this account's cloud slots.
func cloud_list() -> Array:
	if not has_session():
		return []
	var res = await client.list_storage_objects_async(session, "saves", account_id, 10)
	if res.is_exception():
		return []
	var out: Array = []
	for o in res.objects:
		var j = JSON.parse_string(o.value)
		var key: String = o.key
		if j is Dictionary:
			j = SaveManager.unpack_cloud(j)
		if j is Dictionary and key.begins_with("slot_"):
			out.append({"slot": int(key.trim_prefix("slot_")), "meta": j.get("meta", {}), "payload": j})
	return out

func cloud_delete(slot: int) -> void:
	if not has_session():
		return
	await client.delete_storage_objects_async(session, [NakamaStorageObjectId.new("saves", "slot_%d" % slot)])

# --- Account profile (settings that follow the player) ------------------------------------------

func profile_load() -> Dictionary:
	if not has_session():
		return {"error": "Sign in first."}
	var res = await client.read_storage_objects_async(session, [NakamaStorageObjectId.new("profile", "settings", account_id)])
	if res.is_exception():
		return {"error": friendly_error(res.get_exception())}
	for o in res.objects:
		var j = JSON.parse_string(o.value)
		if j is Dictionary:
			return j
	return {}

func profile_save(data: Dictionary) -> bool:
	if not has_session():
		return false
	var obj := NakamaWriteStorageObject.new("profile", "settings", 1, 1, JSON.stringify(data), "")
	var res = await client.write_storage_objects_async(session, [obj])
	if res.is_exception():
		push_warning("Profile sync failed: %s" % friendly_error(res.get_exception()))
		return false
	return true

# --- Co-op ---------------------------------------------------------------------------------------

func _ensure_socket() -> bool:
	if not has_session():
		return false
	if socket and socket.is_connected_to_host():
		return true
	socket = Nakama.create_socket_from(client)
	var res = await socket.connect_async(session)
	if res.is_exception():
		EventBus.net_status.emit("Could not connect: %s" % res.get_exception().message)
		return false
	bridge = NakamaMultiplayerBridge.new(socket)
	bridge.match_join_error.connect(func(err): EventBus.net_status.emit("Join failed: %s" % err.message))
	bridge.match_joined.connect(_on_bridge_joined)
	multiplayer.multiplayer_peer = bridge.multiplayer_peer
	return true

func host_online() -> String:
	if not await _ensure_socket():
		return ""
	mode = "host"
	await bridge.create_match()
	var r := await call_rpc("create_coop_code", {"match_id": bridge.match_id})
	match_code = str(r.get("code", bridge.match_id))
	coop_started.emit(true)
	return match_code

## Accepts a 6-letter invite code (or a raw match id).
func join_online(code: String) -> bool:
	if not await _ensure_socket():
		return false
	var match_id := code.strip_edges()
	if match_id.length() <= 8:
		var r := await call_rpc("resolve_coop_code", {"code": match_id})
		if r.has("error"):
			EventBus.net_status.emit(str(r.error))
			return false
		match_id = str(r.match_id)
	mode = "client"
	match_code = code.strip_edges().to_upper()
	await bridge.join_match(match_id)
	return true

func host_lan(port: int = ENET_PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(port, 8) != OK:
		return false
	multiplayer.multiplayer_peer = peer
	mode = "host"
	match_code = "LAN:%d" % port
	coop_started.emit(true)
	return true

func join_lan(address: String, port: int = ENET_PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(address, port) != OK:
		return false
	multiplayer.multiplayer_peer = peer
	mode = "client"
	return true

func leave() -> void:
	if mode == "host" and match_code.length() == 6:
		call_rpc("close_coop_code", {"code": match_code})
	if bridge:
		await bridge.leave()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	peers.clear()
	var was := mode
	mode = "offline"
	match_code = ""
	if was != "offline":
		coop_ended.emit("left")

func _on_bridge_joined() -> void:
	if mode == "client":
		_on_connected_to_server()

func _on_connected_to_server() -> void:
	var nm := display_name if display_name != "" else GameState.local_player().name if GameState.local_player() else "Farmhand"
	Coop.rpc_id(1, "hello", local_id(), nm)

func _on_peer_connected(id: int) -> void:
	pass

func _on_peer_disconnected(id: int) -> void:
	if peers.has(id):
		var info: Dictionary = peers[id]
		peers.erase(id)
		peer_left.emit(info.pid)
		if mode == "host":
			EventBus.toast.emit("%s left the farm." % info.name, "coop")
			Coop.broadcast_roster()

func _on_server_disconnected() -> void:
	mode = "offline"
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	coop_ended.emit("The host closed the farm.")
