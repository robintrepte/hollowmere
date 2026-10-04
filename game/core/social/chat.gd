class_name Chat
extends RefCounted
## Chat hygiene: length limit, an optional word filter, characters the fonts can't draw and a
## per-sender rate limit.

const MAX_LEN := 200
const RATE_COUNT := 5
const RATE_WINDOW := 8.0

## Whole words only, so "class" or "Schimpanse" stay readable. Kept short on purpose: a soft filter
## for a cozy game among friends, not moderation.
const BLOCKED := ["fuck", "fucking", "fucker", "shit", "bitch", "cunt", "asshole", "dick", "bastard", "whore", "slut", "nigger", "faggot", "retard",
	"scheiße", "scheisse", "fotze", "hure", "wichser", "arschloch", "schlampe", "missgeburt", "spast", "hurensohn", "ficken", "fick"]

static var _sent: Dictionary = {}   # sender -> [unix seconds of recent messages]

static func clean(text: String, filter: bool = true) -> String:
	text = text.strip_edges().replace("\n", " ").substr(0, MAX_LEN)
	if filter:
		text = filtered(text)
	return printable(text)

## Blocked words become asterisks of the same length.
static func filtered(text: String) -> String:
	var re := RegEx.create_from_string("(?i)\\b(" + "|".join(BLOCKED) + ")\\b")
	var out := text
	for m in re.search_all(text):
		out = out.substr(0, m.get_start()) + "*".repeat(m.get_end() - m.get_start()) + out.substr(m.get_end())
	return out

## Characters neither UI font nor the symbol fallback can draw (emoji, most scripts) become "?",
## because browsers have no system fonts and would show boxes.
static func printable(text: String) -> String:
	var faces: Array = [load("res://assets/fonts/Tiny5.ttf"), load("res://assets/fonts/Nunito.ttf")]
	var fallback := UITheme.symbols()
	var out := ""
	for i in text.length():
		var c := text.unicode_at(i)
		var ok := c < 127 or fallback.has_char(c)
		if not ok:
			ok = faces.all(func(f: Font): return f.has_char(c))
		out += String.chr(c) if ok else "?"
	return out

## True if this sender may post now; records the message when allowed.
static func allow(sender: String, now: float = -1.0) -> bool:
	if now < 0.0:
		now = Time.get_unix_time_from_system()
	var recent: Array = _sent.get(sender, []).filter(func(t: float): return now - t < RATE_WINDOW)
	if recent.size() >= RATE_COUNT:
		_sent[sender] = recent
		return false
	recent.append(now)
	_sent[sender] = recent
	return true

static func reset_rate() -> void:
	_sent.clear()

static func muted(pid: String) -> bool:
	return pid in Settings.profile.get("muted", [])

static func set_muted(pid: String, on: bool) -> void:
	var list: Array = Settings.profile.get("muted", []).duplicate()
	list.erase(pid)
	if on:
		list.append(pid)
	Settings.profile_set("muted", list)
