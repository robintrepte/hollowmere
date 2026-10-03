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
	## The web build talks to the server that served it (Caddy proxies /v2 and /ws to Nakama).
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
	var req := HTTPRequest.new()
	req.timeout = 4.0
	req.accept_gzip = false
	add_child(req)
	if req.request("%s://%s:%d/healthcheck" % [client.scheme, client.host, client.port]) != OK:
		req.queue_free()
		return false
	var r: Array = await req.request_completed
	req.queue_free()
	return int(r[0]) == HTTPRequest.RESULT_SUCCESS and int(r[1]) == 200

func call_rpc(id: String, payload: Dictionary = {}) -> Dictionary:
	if not has_session():
		return {"error": "Sign in first."}
	var res = await client.rpc_async(session, id, JSON.stringify(payload))
	if res.is_exception():
		return {"error": friendly_error(res.get_exception())}
	var j = JSON.parse_string(res.payload) if res.payload != "" else {}
	return j if j is Dictionary else {}

static func friendly_error(ex: NakamaException) -> String:
	var m: String = ex.message
	match ex.status_code:
		-1, 0, 503:
			return "Can't reach the Hollowmere server."
		401:
			if m.contains("password") or m.contains("credentials") or m.contains("Invalid"):
				return "Wrong email or password."
			return "Sign-in expired, please sign in again."
		404:
			return "No account with that email. Create one?"
		409:
			return "That name or email is already taken."
	if m.contains("Password must be"):
		return "Password needs at least 8 characters."
	if m.contains("Invalid email"):
		return "That email doesn't look right."
	if m.contains("Username"):
		return "Names can use letters, numbers and _ (up to 20)."
	return m if m != "" else "Something went wrong."

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

func login_email(email: String, password: String, create: bool, username: String = "") -> String:
	_make_client()
	var s: NakamaSession = await client.authenticate_email_async(email, password, username if username != "" else null, create)
	return await _finish_login(s)

func login_device(device_id: String = "") -> String:
	_make_client()
	var dev := device_id if device_id != "" else _device_id()
	var s: NakamaSession = await client.authenticate_device_async(dev, null, true)
	return await _finish_login(s)

## Google sign-in: on Web the page shell obtains an ID token via Google Identity Services.
func login_google(id_token: String) -> String:
	_make_client()
	var s: NakamaSession = await client.authenticate_google_async(id_token, null, true)
	return await _finish_login(s)

func login_apple(id_token: String) -> String:
	_make_client()
	var s: NakamaSession = await client.authenticate_apple_async(id_token, null, true)
	return await _finish_login(s)

## Discord: the server hook checks the access token and turns it into a custom id.
func login_discord(access_token: String) -> String:
	_make_client()
	var s: NakamaSession = await client.authenticate_custom_async("discord", null, true, {"discord_token": access_token})
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

func web_google_token() -> String:
	return web_oauth_token("google")

## Public OAuth client ids are baked into the web shell. Empty / leftover %PLACEHOLDER% means "not set up".
func web_meta(name: String) -> String:
	if OS.get_name() != "Web":
		return ""
	var v := str(JavaScriptBridge.eval(
		"(document.querySelector('meta[name=\"%s\"]')||{}).content||''" % name, true))
	return v.strip_edges()

func oauth_configured(meta_name: String) -> bool:
	var v := web_meta(meta_name)
	return v != "" and not v.begins_with("%")

func is_apple_device() -> bool:
	if OS.get_name() in ["iOS", "macOS"]:
		return true
	if OS.get_name() != "Web":
		return false
	var ua := str(JavaScriptBridge.eval("navigator.userAgent||''", true))
	var plat := str(JavaScriptBridge.eval("navigator.platform||''", true))
	var taps := int(JavaScriptBridge.eval("navigator.maxTouchPoints||0", true))
	return ua.contains("iPhone") or ua.contains("iPad") or ua.contains("Mac") \
		or (plat == "MacIntel" and taps > 1)

## Providers the account panel should show: configured in the page and usable on this device.
func social_providers() -> PackedStringArray:
	var out: PackedStringArray = []
	if OS.get_name() != "Web":
		return out
	if oauth_configured("google-client-id"):
		out.append("google")
	if oauth_configured("apple-client-id") and is_apple_device():
		out.append("apple")
	if oauth_configured("discord-client-id"):
		out.append("discord")
	return out

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
	return ""

var is_guest: bool = false

func _load_account() -> void:
	var acc = await client.get_account_async(session)
	if acc.is_exception():
		return
	is_guest = acc.email == "" and acc.user.google_id == "" and acc.user.apple_id == "" and acc.custom_id == ""
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

## Turns a guest account into an email account, keeping its cloud saves.
func link_email(email: String, password: String) -> String:
	if not has_session():
		return "Sign in first."
	var res = await client.link_email_async(session, email, password)
	if res.is_exception():
		return friendly_error(res.get_exception())
	is_guest = false
	session_changed.emit(true)
	return ""

func try_restore_session() -> bool:
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
	return true

func logout() -> void:
	if client and session:
		await client.session_logout_async(session)
	session = null
	account_id = ""
	display_name = ""
	is_guest = false
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
	var obj := NakamaWriteStorageObject.new("saves", "slot_%d" % slot, 1, 1, JSON.stringify(payload), "")
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
		if j is Dictionary and key.begins_with("slot_"):
			out.append({"slot": int(key.trim_prefix("slot_")), "meta": j.get("meta", {}), "payload": j})
	return out

func cloud_delete(slot: int) -> void:
	if not has_session():
		return
	await client.delete_storage_objects_async(session, [NakamaStorageObjectId.new("saves", "slot_%d" % slot)])

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
