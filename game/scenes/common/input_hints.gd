class_name InputHints
extends RefCounted
## Fills {move}, {use}, {interact}, {run}, {inventory}, {party}, {craft}, {map}, {journal}, {skills} and {menu}
## in hint texts with what the player actually presses: keys, gamepad buttons or touch buttons.

const TOKENS := ["move", "use", "interact", "run", "inventory", "party", "craft", "map", "journal", "skills", "menu"]
const ACTION := {"use": "use_tool", "move": "", "interact": "interact", "run": "run", "inventory": "inventory",
	"party": "party", "craft": "craft", "map": "map", "journal": "journal", "skills": "skills", "menu": "menu"}
const PAD_BUTTONS := {JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
	JOY_BUTTON_BACK: "Select", JOY_BUTTON_START: "Start", JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB"}

static func fill(text: String) -> String:
	if not "{" in text:
		return text
	for t in TOKENS:
		var tag := "{%s}" % t
		if tag in text:
			text = text.replace(tag, label(t))
	return text

static func device() -> String:
	if Settings.using_pad:
		return "pad"
	return "touch" if TouchControls.active else "keys"

static func label(token: String) -> String:
	match device():
		"touch":
			match token:
				"move": return TranslationServer.translate("the joystick")
				"use": return TranslationServer.translate("the tool button")
				"interact": return TranslationServer.translate("the hand button")
				"run": return TranslationServer.translate("the run button")
			return TranslationServer.translate("the menu button")
		"pad":
			if token == "move":
				return TranslationServer.translate("the left stick")
			if token == "run":
				return TranslationServer.translate("the left stick (push it all the way)")
			var b := _pad_button(str(ACTION.get(token, "")))
			return b if b != "" else str(TranslationServer.translate("Start, then the tab"))
	if token == "move":
		return "%s %s %s %s" % [Settings.key_name("move_up"), Settings.key_name("move_left"), Settings.key_name("move_down"), Settings.key_name("move_right")]
	if token == "use":
		return str(TranslationServer.translate("left click or %s")) % Settings.key_name("use_tool")
	if token == "interact":
		return str(TranslationServer.translate("right click or %s")) % Settings.key_name("interact")
	return Settings.key_name(str(ACTION.get(token, token)))

static func _pad_button(action: String) -> String:
	if action == "" or not InputMap.has_action(action):
		return ""
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton and PAD_BUTTONS.has(ev.button_index):
			return PAD_BUTTONS[ev.button_index]
	return ""
