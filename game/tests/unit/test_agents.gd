extends GutTest
## Agent tools stay inside the same actions a human can take.

func after_each() -> void:
	TranslationServer.set_locale("en")

func test_status_and_look_do_not_need_a_scene() -> void:
	GameState.new_game({"seed": 3, "starter": "puddlop", "player_name": "Robin"})
	var st: Dictionary = AgentTools.status("local")
	assert_eq(st.name, "Robin")
	assert_eq(st.map, "farm")
	assert_true(st.has("money"))
	assert_true(st.has("held"))
	assert_true(st.has("energy"))
	var look: Dictionary = AgentTools.look_around("local", 3)
	assert_eq(look.map, "farm")
	assert_true(look.ascii.contains("@"))

func test_observe_scope_blocks_actions() -> void:
	GameState.new_game({"seed": 3, "starter": "puddlop"})
	var r := AgentTools.run("buy", {"shop": "general_store", "id": "parsnip_seeds"}, {"pid": "local", "scopes": ["observe"]})
	assert_false(r.ok)
	assert_true(str(r.error).contains("economy") or str(r.error).contains("scope"))

func test_unknown_tool_is_refused() -> void:
	assert_false(AgentTools.run("delete_save", {}, {"scopes": AgentTools.SCOPES}).ok)

func test_handbook_mentions_saves() -> void:
	assert_true(AgentTools.handbook().contains("save"))

func test_hourly_job_text_uses_real_rates() -> void:
	assert_true(FarmJobs.hourly_text("water", 1).contains("12"))
	assert_gt(FarmJobs.energy_per_hour(), 0.0)

func test_max_three_partners() -> void:
	assert_eq(AgentTools.MAX_AGENTS, 3)
	assert_eq(AgentBridge.MAX_AGENTS, 3)

func test_mcp_url_follows_the_server() -> void:
	assert_eq(AgentTools.mcp_url("127.0.0.1"), "http://127.0.0.1:8787/mcp")
	assert_eq(AgentTools.mcp_url("localhost"), "http://127.0.0.1:8787/mcp")
	assert_eq(AgentTools.mcp_url("hollowmere.tretu.de"), "https://mcp.hollowmere.tretu.de/mcp")
	assert_eq(AgentTools.mcp_url("mcp.example.com"), "https://mcp.example.com/mcp")

func test_chat_say_lands_in_the_log_and_needs_scope() -> void:
	GameState.new_game({"seed": 3, "starter": "puddlop", "player_name": "Robin"})
	Chat.reset_rate()
	Coop.chat_log.clear()
	var blocked := AgentTools.run("chat_say", {"text": "hello"}, {"pid": "local", "scopes": ["observe", "act"]})
	assert_false(blocked.ok)
	assert_eq(Coop.chat_log.size(), 0)
	var said := AgentTools.run("chat_say", {"text": "hello farm"}, {"pid": "local", "scopes": AgentTools.SCOPES})
	assert_true(said.ok, said.get("error", ""))
	assert_eq(Coop.chat_log.back().text, "hello farm")
	assert_eq(Coop.chat_log.back().name, "Robin")
	var empty := AgentTools.run("chat_say", {"text": "   "}, {"pid": "local", "scopes": AgentTools.SCOPES})
	assert_false(empty.ok)
	var events: Dictionary = AgentTools.run("wait_for_events", {}, {"pid": "local", "scopes": ["observe"]})
	assert_true(events.ok)
	assert_true(str(events.result).contains("hello farm"))

func test_farmhand_chat_uses_their_name() -> void:
	GameState.new_game({"seed": 3, "starter": "puddlop", "player_name": "Robin"})
	Chat.reset_rate()
	Coop.chat_log.clear()
	GameState.ensure_player("agent:1", "Pip")
	var said := AgentTools.run("chat_say", {"text": "seeds are in"}, {"pid": "agent:1", "scopes": AgentTools.SCOPES})
	assert_true(said.ok, said.get("error", ""))
	assert_eq(Coop.chat_log.back().pid, "agent:1")
	assert_eq(Coop.chat_log.back().name, "Pip")
	assert_eq(said.result.name, "Pip")

func test_select_item_holds_a_stack() -> void:
	GameState.new_game({"seed": 3, "starter": "puddlop"})
	var by_id: Dictionary = AgentTools.run("select_item", {"id": "parsnip_seeds"}, {"pid": "local", "scopes": AgentTools.SCOPES})
	assert_true(by_id.ok, by_id.get("error", ""))
	assert_eq(by_id.result.id, "parsnip_seeds")
	assert_eq(GameState.local_player().selected_id(), "parsnip_seeds")
	var by_slot: Dictionary = AgentTools.run("select_item", {"slot": 0}, {"pid": "local", "scopes": AgentTools.SCOPES})
	assert_true(by_slot.ok)
	assert_eq(GameState.local_player().selected, 0)
	assert_false(AgentTools.run("select_item", {"id": "not_a_real_item"}, {"pid": "local", "scopes": AgentTools.SCOPES}).ok)
	assert_false(AgentTools.run("select_item", {}, {"pid": "local", "scopes": AgentTools.SCOPES}).ok)

func test_helper_panel_stays_inside_the_viewport() -> void:
	var host := Control.new()
	host.size = Vector2(640, 360)
	add_child_autofree(host)
	var panel := AgentPanel.new()
	host.add_child(panel)
	await wait_process_frames(2)
	_assert_inside(panel, host.size)
	host.size = Vector2(320, 180)
	panel._fit()
	_assert_inside(panel, host.size)
	panel._secret = "hm_" + "a".repeat(40)
	panel._rebuild()
	panel._fit()
	await wait_process_frames(2)
	_assert_inside(panel, host.size)
	assert_true(_has_line(panel, AgentTools.mcp_url()), "the address is on screen and can be copied")
	TranslationServer.set_locale("de")
	panel._rebuild()
	await wait_process_frames(1)
	assert_true(_has_label(panel, "Adresse"), "German address label")
	assert_true(_has_label(panel, "Verbinden"), "German connect heading")
	panel._fit()
	await wait_process_frames(2)
	_assert_inside(panel, host.size)
	TranslationServer.set_locale("en")

func _assert_inside(panel: Control, box: Vector2) -> void:
	var r := panel.get_rect()
	assert_lte(r.size.x, box.x, "wider than the window")
	assert_lte(r.size.y, box.y, "taller than the window")
	assert_gte(r.position.x, -0.5)
	assert_gte(r.position.y, -0.5)
	assert_lte(r.end.x, box.x + 0.5)
	assert_lte(r.end.y, box.y + 0.5)

func _has_line(node: Node, want: String) -> bool:
	if node is LineEdit and (node as LineEdit).text == want:
		return true
	for c in node.get_children():
		if _has_line(c, want):
			return true
	return false

func _has_label(node: Node, want: String) -> bool:
	if node is Label and (node as Label).text == want:
		return true
	for c in node.get_children():
		if _has_label(c, want):
			return true
	return false

func test_dialogue_without_a_scene_is_refused() -> void:
	GameState.new_game({"seed": 3, "starter": "puddlop"})
	var r := AgentTools.run("dialogue_advance", {}, {"pid": "local", "scopes": AgentTools.SCOPES})
	assert_false(r.ok)
	assert_eq(AgentTools.run("get_dialogue", {}, {"pid": "local", "scopes": AgentTools.SCOPES}).result.open, false)
