extends Node
## "Mit Tretu-Konto anmelden": OpenID Connect sign-in at auth.tretu.de (public client, PKCE S256),
## then a Nakama custom login with the access token (the server checks it at the issuer).
## Also keeps the player's presence fresh on tretu.de and reports finished battles.
##
## Off unless the project settings tretu/auth_issuer and tretu/client_id are both set
## (the shipped project.godot leaves the issuer empty; see HOSTING.md "Tretu-Konto").
##   Desktop: system browser + loopback listener on http://127.0.0.1:<random port>/callback,
##            refresh token kept encrypted in user://tretu.cfg for silent sign-in.
##   Web:     popup (or full-page redirect) to the issuer, back to <origin>/auth/callback,
##            code exchange in the page shell (window.hollowmereTretuSignIn in web/shell.html).

signal status(text: String)

const SCOPES := "openid profile email offline_access tretu"
const TOKEN_FILE := "user://tretu.cfg"
const LOGIN_TIMEOUT_SEC := 300.0
const HTTP_TIMEOUT_SEC := 10.0
const HEARTBEAT_EVERY := 60.0
const CALLBACK_PATH := "/callback"

var _discovery: Dictionary = {}
var _cancelled := false
var _beat_t := 0.0
## Server answered enabled=false: platform features are off there, stop asking this session.
var _beats_off := false
## Shown in the account panel as the Tretu profile name (from the ID token).
var profile_username := ""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	EventBus.battle_finished.connect(_on_battle_finished)
	Net.session_changed.connect(func(_on: bool):
		_beats_off = false
		_beat_t = HEARTBEAT_EVERY - 3.0)
	if enabled() and OS.get_name() == "Web":
		_resume_web_redirect()

# --- Configuration -------------------------------------------------------------------------------

static func setting(key: String, fallback: String = "") -> String:
	return str(ProjectSettings.get_setting("tretu/" + key, fallback)).strip_edges()

static func issuer() -> String:
	return setting("auth_issuer").trim_suffix("/")

static func client_id() -> String:
	return setting("client_id")

## The feature flag: both values set (and not a leftover %PLACEHOLDER%).
static func enabled() -> bool:
	var iss := issuer()
	var cid := client_id()
	return iss.begins_with("http") and cid != "" and not cid.begins_with("%")

## "Mein Konto" on the identity provider.
static func account_url() -> String:
	return issuer() + "/konto"

static func legal_url() -> String:
	var u := setting("legal_url", "https://tretu.de").trim_suffix("/")
	return u if u.begins_with("http") else "https://tretu.de"

static func profile_url(username: String) -> String:
	var base := setting("platform_url", "https://tretu.de").trim_suffix("/")
	return "%s/u/%s" % [base, username.uri_encode()] if base.begins_with("http") and username != "" else ""

# --- PKCE and URL helpers (static, unit-tested) -----------------------------------------------------

static func base64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")

static func random_token(n_bytes: int = 32) -> String:
	return base64url(Crypto.new().generate_random_bytes(n_bytes))

## RFC 7636 S256: BASE64URL(SHA256(ASCII(verifier))).
static func pkce_challenge(verifier: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(verifier.to_ascii_buffer())
	return base64url(ctx.finish())

static func query_string(params: Dictionary) -> String:
	var parts: PackedStringArray = []
	for k in params:
		parts.append("%s=%s" % [str(k).uri_encode(), str(params[k]).uri_encode()])
	return "&".join(parts)

static func parse_query(q: String) -> Dictionary:
	var out := {}
	for pair in q.split("&", false):
		var kv := pair.split("=", true, 1)
		out[kv[0].uri_decode()] = (kv[1].replace("+", " ").uri_decode() if kv.size() > 1 else "")
	return out

static func authorize_url(endpoint: String, cid: String, redirect_uri: String, state: String, nonce: String, challenge: String) -> String:
	return endpoint + ("&" if endpoint.contains("?") else "?") + query_string({
		"response_type": "code", "client_id": cid, "redirect_uri": redirect_uri, "scope": SCOPES,
		"state": state, "nonce": nonce, "code_challenge": challenge, "code_challenge_method": "S256",
	})

## First line of a loopback HTTP request -> {path, query} ({} if it is not a GET).
static func parse_request_line(raw: String) -> Dictionary:
	var line := raw.split("\r\n", false, 1)[0] if raw != "" else ""
	var parts := line.split(" ")
	if parts.size() < 2 or parts[0] != "GET":
		return {}
	var target := parts[1]
	var q := ""
	var i := target.find("?")
	if i >= 0:
		q = target.substr(i + 1)
		target = target.substr(0, i)
	return {"path": target, "query": parse_query(q)}

## Claims of a JWT without checking its signature (the server verifies the access token at
## the issuer; the client only reads the nonce and the display name).
static func jwt_claims(jwt: String) -> Dictionary:
	var parts := jwt.split(".")
	if parts.size() < 2:
		return {}
	var b64 := parts[1].replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	var j = JSON.parse_string(Marshalls.base64_to_raw(b64).get_string_from_utf8())
	return j if j is Dictionary else {}

# --- HTTP ----------------------------------------------------------------------------------------------

## -> {code: int, body: Dictionary} (code 0 = no connection)
func _http(url: String, method := HTTPClient.METHOD_GET, form: Dictionary = {}) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = HTTP_TIMEOUT_SEC
	req.accept_gzip = OS.get_name() != "Web"
	add_child(req)
	var headers := PackedStringArray(["Accept: application/json"])
	var body := ""
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Type: application/x-www-form-urlencoded")
		body = query_string(form)
	if req.request(url, headers, method, body) != OK:
		req.queue_free()
		return {"code": 0, "body": {}}
	var r: Array = await req.request_completed
	req.queue_free()
	var j = JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8()) if int(r[0]) == HTTPRequest.RESULT_SUCCESS else null
	return {"code": int(r[1]) if int(r[0]) == HTTPRequest.RESULT_SUCCESS else 0, "body": j if j is Dictionary else {}}

func discover() -> Dictionary:
	if not _discovery.is_empty():
		return _discovery
	var r := await _http(issuer() + "/.well-known/openid-configuration")
	var d: Dictionary = r.body
	if int(r.code) != 200 or str(d.get("issuer", "")).trim_suffix("/") != issuer() \
			or str(d.get("authorization_endpoint", "")) == "" or str(d.get("token_endpoint", "")) == "":
		return {}
	_discovery = d
	return d

# --- Sign-in -------------------------------------------------------------------------------------------

## Full interactive sign-in. Returns "" on success or a message for the player.
func sign_in() -> String:
	if not enabled():
		return tr("Tretu sign-in is not set up for this build.")
	_cancelled = false
	if OS.get_name() == "Web":
		return await _sign_in_web()
	return await _sign_in_desktop()

func cancel() -> void:
	_cancelled = true

func _sign_in_desktop() -> String:
	var disc := await discover()
	if disc.is_empty():
		return tr("Can't reach the Tretu sign-in right now.")
	var server := TCPServer.new()
	var port := 0
	for i in 20:
		var p := randi_range(49152, 65000)
		if server.listen(p, "127.0.0.1") == OK:
			port = p
			break
	if port == 0:
		return tr("Could not open a local port for the sign-in.")
	var redirect := "http://127.0.0.1:%d%s" % [port, CALLBACK_PATH]
	var verifier := random_token(48)
	var state := random_token(16)
	var nonce := random_token(16)
	OS.shell_open(authorize_url(str(disc.authorization_endpoint), client_id(), redirect, state, nonce, pkce_challenge(verifier)))
	status.emit(tr("Finish signing in with Tretu in your browser..."))
	var cb := await _await_callback(server)
	server.stop()
	if cb.is_empty():
		return "" if _cancelled else tr("Tretu sign-in timed out.")
	if cb.has("error"):
		return tr("Tretu sign-in was cancelled.") if str(cb.error) == "access_denied" else tr("Tretu sign-in failed.")
	if str(cb.get("state", "")) != state or str(cb.get("code", "")) == "":
		return tr("Tretu sign-in failed.")
	DisplayServer.window_move_to_foreground()
	var tok := await _http(str(disc.token_endpoint), HTTPClient.METHOD_POST, {
		"grant_type": "authorization_code", "code": str(cb.code), "redirect_uri": redirect,
		"client_id": client_id(), "code_verifier": verifier,
	})
	return await _finish(tok, nonce)

## Waits for the browser to hit the loopback callback. -> query dict, or {} on timeout/cancel.
func _await_callback(server: TCPServer) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(LOGIN_TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline and not _cancelled:
		await get_tree().create_timer(0.1).timeout
		if not server.is_connection_available():
			continue
		var peer := server.take_connection()
		var raw := await _read_request(peer)
		var req := parse_request_line(raw)
		if req.is_empty() or str(req.path) != CALLBACK_PATH:
			_respond(peer, 404, "Not found")
			continue
		var q: Dictionary = req.query
		_respond(peer, 200, _callback_page(not q.has("error")))
		return q
	return {}

func _read_request(peer: StreamPeerTCP) -> String:
	var buf := PackedByteArray()
	for i in 50:
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			var got: Array = peer.get_data(n)
			if int(got[0]) == OK:
				buf.append_array(got[1])
			if buf.get_string_from_utf8().contains("\r\n\r\n") or buf.size() > 16384:
				break
		await get_tree().create_timer(0.02).timeout
	return buf.get_string_from_utf8()

func _respond(peer: StreamPeerTCP, code: int, body: String) -> void:
	var bytes := body.to_utf8_buffer()
	var status_line := "HTTP/1.1 200 OK" if code == 200 else "HTTP/1.1 404 Not Found"
	var head := status_line + "\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n" \
		+ "Content-Length: " + str(bytes.size()) + "\r\n\r\n"
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(bytes)
	peer.disconnect_from_host()

static func _callback_page(ok: bool) -> String:
	var de := "Du bist angemeldet. Du kannst diesen Tab schließen und zu Hollowmere zurückkehren." if ok \
		else "Die Anmeldung wurde abgebrochen. Du kannst diesen Tab schließen."
	var en := "You're signed in. You can close this tab and return to Hollowmere." if ok \
		else "Sign-in was cancelled. You can close this tab."
	return """<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Hollowmere</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#1c2120;color:#f3ead8;font:17px/1.55 "Trebuchet MS",sans-serif;text-align:center}h1{color:#ffd36b;letter-spacing:.04em;font-size:1.9rem;margin:0 0 .6rem}p{max-width:26rem;margin:.4rem auto}.en{color:#b9c8a8;font-size:.92rem}</style></head>
<body><main><h1>Hollowmere</h1><p>%s</p><p class="en">%s</p></main><script>setTimeout(function(){window.close()},1500)</script></body></html>""" % [de, en]

func _sign_in_web() -> String:
	JavaScriptBridge.eval("window.hollowmereTretuToken=''; window.hollowmereTretuError=''; window.hollowmereTretuSignIn(%s, %s)" \
		% [JSON.stringify(issuer()), JSON.stringify(client_id())], true)
	status.emit(tr("Finish signing in with Tretu in the popup..."))
	for i in int(LOGIN_TIMEOUT_SEC * 2.0):
		await get_tree().create_timer(0.5).timeout
		if _cancelled:
			return ""
		var err := Net.web_oauth_error("tretu")
		if err != "":
			return err
		var tok := Net.web_oauth_token("tretu")
		if tok != "":
			JavaScriptBridge.eval("window.hollowmereTretuToken=''", true)
			profile_username = str(JavaScriptBridge.eval("window.hollowmereTretuName || ''", true))
			return await Net.login_tretu(tok)
	return tr("Tretu sign-in timed out.")

## The popup was blocked, so the page went to the issuer and came back: finish that sign-in.
func _resume_web_redirect() -> void:
	if not bool(JavaScriptBridge.eval("!!window.hollowmereTretuResume", true)):
		return
	for i in 60:
		await get_tree().create_timer(0.5).timeout
		var tok := Net.web_oauth_token("tretu")
		if tok != "":
			JavaScriptBridge.eval("window.hollowmereTretuToken=''; window.hollowmereTretuResume=false", true)
			profile_username = str(JavaScriptBridge.eval("window.hollowmereTretuName || ''", true))
			var err: String = await Net.login_tretu(tok)
			if err != "":
				EventBus.toast.emit(err, "")
			return
		if Net.web_oauth_error("tretu") != "":
			EventBus.toast.emit(Net.web_oauth_error("tretu"), "")
			return

## Token response -> Nakama login. Keeps the refresh token (desktop) for the next start.
func _finish(tok: Dictionary, nonce: String) -> String:
	var body: Dictionary = tok.body
	var access := str(body.get("access_token", ""))
	if int(tok.code) != 200 or access == "":
		return tr("Tretu sign-in failed.")
	var claims := jwt_claims(str(body.get("id_token", "")))
	if not claims.is_empty() and claims.has("nonce") and str(claims.nonce) != nonce:
		return tr("Tretu sign-in failed.")
	profile_username = str(claims.get("preferred_username", ""))
	var err: String = await Net.login_tretu(access)
	if err == "" and str(body.get("refresh_token", "")) != "":
		_store_refresh(str(body.refresh_token))
	return err

## Next start, no Nakama session left: trade the stored refresh token for a new login.
func silent_sign_in() -> bool:
	if not enabled() or OS.get_name() == "Web":
		return false
	var rt := _load_refresh()
	if rt == "":
		return false
	var disc := await discover()
	if disc.is_empty():
		return false
	var tok := await _http(str(disc.token_endpoint), HTTPClient.METHOD_POST, {
		"grant_type": "refresh_token", "refresh_token": rt, "client_id": client_id(),
	})
	if int(tok.code) == 400 or int(tok.code) == 401:
		forget_tokens()
		return false
	var body: Dictionary = tok.body
	if int(tok.code) != 200 or str(body.get("access_token", "")) == "":
		return false
	var claims := jwt_claims(str(body.get("id_token", "")))
	profile_username = str(claims.get("preferred_username", profile_username))
	if str(body.get("refresh_token", "")) != "":
		_store_refresh(str(body.refresh_token))
	return await Net.login_tretu(str(body.access_token)) == ""

## Sign-out: drop (and revoke, best effort) the stored refresh token.
func forget_tokens() -> void:
	var rt := _load_refresh()
	if FileAccess.file_exists(TOKEN_FILE):
		DirAccess.remove_absolute(TOKEN_FILE)
	profile_username = ""
	if rt != "" and not _discovery.is_empty() and str(_discovery.get("revocation_endpoint", "")) != "":
		_http(str(_discovery.revocation_endpoint), HTTPClient.METHOD_POST,
			{"token": rt, "token_type_hint": "refresh_token", "client_id": client_id()})

## Encrypted with a key bound to this device, so a copied user:// folder is not a login.
static func _token_key() -> String:
	var dev := OS.get_unique_id() if OS.get_name() != "Web" else ""
	return "hollowmere-tretu:" + (dev if dev != "" else ProjectSettings.globalize_path("user://"))

func _store_refresh(rt: String) -> void:
	if OS.get_name() == "Web":
		return
	var cfg := ConfigFile.new()
	cfg.set_value("t", "refresh", rt)
	cfg.set_value("t", "issuer", issuer())
	cfg.set_value("t", "name", profile_username)
	cfg.save_encrypted_pass(TOKEN_FILE, _token_key())

func _load_refresh() -> String:
	if not FileAccess.file_exists(TOKEN_FILE):
		return ""
	var cfg := ConfigFile.new()
	if cfg.load_encrypted_pass(TOKEN_FILE, _token_key()) != OK or str(cfg.get_value("t", "issuer", "")) != issuer():
		return ""
	if profile_username == "":
		profile_username = str(cfg.get_value("t", "name", ""))
	return str(cfg.get_value("t", "refresh", ""))

# --- Platform: presence and battles -------------------------------------------------------------------

func _process(delta: float) -> void:
	if _beats_off or not Net.is_tretu or not Net.has_session():
		return
	_beat_t += delta
	if _beat_t >= HEARTBEAT_EVERY:
		_beat_t = 0.0
		heartbeat()

func heartbeat() -> void:
	var payload := {}
	if Net.mode == "host" and Net.match_code.length() == 6:
		payload["code"] = Net.match_code
	var r: Dictionary = await Net.call_rpc("tretu_heartbeat", payload)
	if not r.has("error") and r.get("enabled", true) == false:
		_beats_off = true

func _on_battle_finished(res: Dictionary) -> void:
	if not Net.is_tretu or not Net.has_session() or _beats_off:
		return
	var result: String = {"win": "win", "befriend": "win", "lose": "loss", "draw": "draw"}.get(str(res.get("result", "")), "")
	if result == "":
		return
	Net.call_rpc("tretu_report_battle", {"result": result, "kind": str(res.get("kind", ""))})
