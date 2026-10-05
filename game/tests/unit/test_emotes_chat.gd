extends GutTest
## Emotes, chat hygiene and speech bubbles.

func after_each() -> void:
	Chat.reset_rate()
	Settings.profile_set("muted", [])

func test_starter_emotes_are_known() -> void:
	GameState.new_game({"seed": 2, "starter": "puddlop"})
	assert_true(Emotes.knows(GameState.local_player(), "wave"))
	assert_true(Emotes.knows(GameState.local_player(), "dance_jig"))
	assert_false(Emotes.knows(GameState.local_player(), "lucky"))

func test_wheel_is_the_fixed_set() -> void:
	GameState.new_game({"seed": 2, "starter": "puddlop"})
	assert_eq(Emotes.wheel(GameState.local_player()), Emotes.STARTER)

func test_chat_filters_rude_words_and_unknown_glyphs() -> void:
	assert_eq(Chat.clean("hello fuck there"), "hello **** there")
	assert_eq(Chat.clean("Schimpanse"), "Schimpanse")
	assert_true(Chat.clean("hi 😀").contains("?"))
	assert_eq(Chat.clean("ok", false), "ok")

func test_chat_rate_limit() -> void:
	Chat.reset_rate()
	var now := 1000.0
	for i in Chat.RATE_COUNT:
		assert_true(Chat.allow("a", now + i * 0.1), "message %d" % i)
	assert_false(Chat.allow("a", now + 0.5), "the fifth extra is too fast")
	assert_true(Chat.allow("a", now + Chat.RATE_WINDOW + 0.1), "after the window it is fine")

func test_mute_is_stored_on_the_profile() -> void:
	Chat.set_muted("p2", true)
	assert_true(Chat.muted("p2"))
	Chat.set_muted("p2", false)
	assert_false(Chat.muted("p2"))

func test_speech_bubble_queues_and_drops_old_lines() -> void:
	var b := SpeechBubble.new()
	add_child_autofree(b)
	await wait_frames(1)
	for i in 6:
		b.say("line %d" % i)
	assert_lte(b._queue.size() + (1 if b.busy() else 0), SpeechBubble.MAX_QUEUE + 1)
