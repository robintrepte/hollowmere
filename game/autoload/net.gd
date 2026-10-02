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
	var scheme := "https" if Settings.server_ssl else "http"
	client = Nakama.create_client(Settings.server_key, Settings.server_host, Settings.server_port, scheme)
	client.timeout = 10

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
	return _finish_login(s)

func login_device() -> String:
	_make_client()
	var dev := _device_id()
	var s: NakamaSession = await client.authenticate_device_async(dev, null, true)
	return _finish_login(s)

## Google sign-in: on Web the page shell obtains an ID token via Google Identity Services.
func login_google(id_token: String) -> String:
	_make_client()
	var s: NakamaSession = await client.authenticate_google_async(id_token, null, true)
	return _finish_login(s)

func web_google_token() -> String:
	if OS.get_name() != "Web":
		return ""
	var tok = JavaScriptBridge.eval("window.hollowmereGoogleToken || ''", true)
	return str(tok)

func _finish_login(s: NakamaSession) -> String:
	if s == null or s.is_exception():
		var msg: String = s.get_exception().message if s else "No response"
		return msg if msg != "" else "Could not reach the server."
	session = s
	account_id = s.user_id
	display_name = s.username
	_save_refresh(s)
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
	var s: NakamaSession = NakamaClient.restore_session(tok)
	if s.is_expired() and ref != "":
		s = await client.session_refresh_async(NakamaClient.restore_session(ref))
	if s == null or s.is_exception() or s.is_expired():
		return false
	session = s
	account_id = s.user_id
	display_name = s.username
	session_changed.emit(true)
	return true

func logout() -> void:
	if client and session:
		await client.session_logout_async(session)
	session = null
	account_id = ""
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

func cloud_save(slot: int, payload: Dictionary) -> void:
	if not has_session():
		return
	var obj := NakamaWriteStorageObject.new("saves", "slot_%d" % slot, 1, 1, JSON.stringify(payload), "")
	var res = await client.write_storage_objects_async(session, [obj])
	if res.is_exception():
		push_warning("Cloud save failed: %s" % res.get_exception().message)

func cloud_list() -> Array:
	if not has_session():
		return []
	var res = await client.list_storage_objects_async(session, "saves", account_id, 10)
	if res.is_exception():
		return []
	var out: Array = []
	for o in res.objects:
		var j = JSON.parse_string(o.value)
		if j is Dictionary:
			out.append({"key": o.key, "meta": j.get("meta", {}), "payload": j})
	return out

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
	match_code = bridge.match_id
	coop_started.emit(true)
	return match_code

func join_online(code: String) -> bool:
	if not await _ensure_socket():
		return false
	mode = "client"
	await bridge.join_match(code)
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
