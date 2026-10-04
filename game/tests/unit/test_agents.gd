extends GutTest
## Agent tools stay inside the same actions a human can take.

func test_status_and_look_do_not_need_a_scene() -> void:
	GameState.new_game({"seed": 3, "starter": "puddlop", "player_name": "Robin"})
	var st: Dictionary = AgentTools.status("local")
	assert_eq(st.name, "Robin")
	assert_eq(st.map, "farm")
	assert_true(st.has("money"))
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
