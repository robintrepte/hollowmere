extends GutTest
## Tretu-Konto sign-in on the client (the only account sign-in): shipped config, PKCE, the loopback
## callback and helpers.
## (The server side is covered by server/nakama/tests/.)

var _saved := {}

func before_each() -> void:
	for k in ["auth_issuer", "client_id"]:
		_saved[k] = ProjectSettings.get_setting("tretu/" + k, "")

func after_each() -> void:
	for k in _saved:
		ProjectSettings.set_setting("tretu/" + k, _saved[k])

func test_on_in_the_shipped_config() -> void:
	assert_eq(str(ProjectSettings.get_setting("tretu/auth_issuer", "")), "https://auth.tretu.de", "shipped builds sign in at auth.tretu.de")
	assert_eq(str(ProjectSettings.get_setting("tretu/client_id", "")), "hollowmere")
	assert_true(Tretu.enabled())
	assert_eq(Tretu.account_url(), "https://auth.tretu.de/konto")

func test_flag_needs_issuer_and_client_id() -> void:
	ProjectSettings.set_setting("tretu/auth_issuer", "https://auth.tretu.de/")
	ProjectSettings.set_setting("tretu/client_id", "hollowmere")
	assert_true(Tretu.enabled())
	assert_eq(Tretu.issuer(), "https://auth.tretu.de", "trailing slash dropped")
	assert_eq(Tretu.account_url(), "https://auth.tretu.de/konto")
	ProjectSettings.set_setting("tretu/client_id", "")
	assert_false(Tretu.enabled(), "no client id, no button")
	ProjectSettings.set_setting("tretu/client_id", "%TRETU_CLIENT_ID%")
	assert_false(Tretu.enabled(), "a leftover placeholder is not a client id")

func test_pkce_matches_rfc7636() -> void:
	# RFC 7636 appendix B.
	assert_eq(Tretu.pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

func test_random_tokens_are_base64url() -> void:
	var v := Tretu.random_token(48)
	assert_eq(v.length(), 64)
	assert_false(v.contains("+") or v.contains("/") or v.contains("="))
	assert_ne(v, Tretu.random_token(48))

func test_authorize_url() -> void:
	var u := Tretu.authorize_url("https://auth.tretu.de/authorize", "hollowmere", "http://127.0.0.1:50123/callback", "st", "no", "ch")
	var q := Tretu.parse_query(u.split("?")[1])
	assert_eq(q.response_type, "code")
	assert_eq(q.client_id, "hollowmere")
	assert_eq(q.redirect_uri, "http://127.0.0.1:50123/callback")
	assert_eq(q.scope, "openid profile email offline_access tretu")
	assert_eq(q.code_challenge_method, "S256")
	assert_eq(q.state, "st")
	assert_true(Tretu.authorize_url("https://x/a?p=1", "c", "r", "s", "n", "h").begins_with("https://x/a?p=1&"))

func test_parse_request_line() -> void:
	var r := Tretu.parse_request_line("GET /callback?code=a%2Bb&state=x+y HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
	assert_eq(r.path, "/callback")
	assert_eq(r.query.code, "a+b")
	assert_eq(r.query.state, "x y")
	assert_eq(Tretu.parse_request_line("POST /callback HTTP/1.1\r\n\r\n"), {})
	assert_eq(Tretu.parse_request_line(""), {})

func test_jwt_claims() -> void:
	var payload := Marshalls.utf8_to_base64(JSON.stringify({"nonce": "n1", "preferred_username": "Jörg"})).replace("+", "-").replace("/", "_").replace("=", "")
	var c := Tretu.jwt_claims("eyJhbGciOiJub25lIn0." + payload + ".sig")
	assert_eq(c.get("nonce"), "n1")
	assert_eq(c.get("preferred_username"), "Jörg")
	assert_eq(Tretu.jwt_claims("not-a-jwt"), {})

func test_loopback_callback_answers_the_browser() -> void:
	var server := TCPServer.new()
	var port := 0
	for i in 20:
		var p := randi_range(49152, 65000)
		if server.listen(p, "127.0.0.1") == OK:
			port = p
			break
	assert_ne(port, 0)
	var browser := StreamPeerTCP.new()
	assert_eq(browser.connect_to_host("127.0.0.1", port), OK)
	var waiter := {"result": null}
	var wait := func(): waiter.result = await Tretu._await_callback(server)
	wait.call()
	for i in 50:
		browser.poll()
		if browser.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
		await get_tree().create_timer(0.02).timeout
	browser.put_data("GET /callback?code=the-code&state=the-state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_utf8_buffer())
	var answer := PackedByteArray()
	for i in 150:
		await get_tree().create_timer(0.02).timeout
		browser.poll()
		if browser.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			if waiter.result != null:
				break
			continue
		var n := browser.get_available_bytes()
		if n > 0:
			answer.append_array(browser.get_data(n)[1])
	server.stop()
	var text := answer.get_string_from_utf8()
	assert_true(text.begins_with("HTTP/1.1 200 OK"), text.left(80))
	assert_true(text.contains("Du kannst diesen Tab schließen"))
	assert_eq(waiter.result.get("code"), "the-code")
	assert_eq(waiter.result.get("state"), "the-state")

func test_legal_links_point_at_tretu() -> void:
	assert_eq(Tretu.legal_url(), "https://tretu.de")
	assert_eq(Tretu.profile_url("Mia"), "https://tretu.de/u/Mia")
	assert_eq(Tretu.profile_url(""), "")

func test_tretu_icon() -> void:
	var t := Art.social_icon("tretu")
	assert_not_null(t)
	assert_eq(t.get_width(), 16)

func test_battle_report_needs_a_tretu_session() -> void:
	assert_false(Net.is_tretu)
	# Offline / not a Tretu account: finishing a battle must not try to reach the server.
	Tretu._on_battle_finished({"result": "win", "kind": "wild"})
	assert_false(Net.has_session())
