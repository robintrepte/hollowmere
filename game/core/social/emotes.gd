class_name Emotes
extends RefCounted
## The emote catalogue: which paper-doll poses an emote cycles through, how the body moves on top
## of that, and the bubble, particles and sound that go with it. Players know the starter set and
## unlock the rest from quests, the summer festival and the casino boutique.

## Paper-doll sheet columns (see tools/art_pipeline/character.py).
const COLS := {"idle": 0, "walk0": 1, "walk2": 3, "cheer": 7, "wave0": 8, "wave1": 9, "bow": 10, "sit": 11, "doze": 12, "clap": 13, "palm": 14}

## frames: sheet columns cycled at fps. loop: plays until the player moves, otherwise for time seconds.
## motion: hop | giggle | bow | spin | tip | shiver. drift: an icon or text that floats up now and then.
const LIST := {
	"wave": {"name": "Wave", "frames": ["wave0", "wave1"], "fps": 5.0, "time": 1.8},
	"bow": {"name": "Bow", "frames": ["bow"], "fps": 1.0, "time": 1.6, "motion": "bow"},
	"cheer": {"name": "Cheer", "frames": ["cheer", "idle"], "fps": 4.0, "time": 2.0, "motion": "hop", "fx": "levelup", "sfx": "sparkle"},
	"laugh": {"name": "Laugh", "frames": ["idle"], "fps": 1.0, "time": 2.0, "motion": "giggle", "sfx": "laugh"},
	"thumbs_up": {"name": "Thumbs up", "frames": ["wave0"], "fps": 1.0, "time": 1.6},
	"heart": {"name": "Heart", "frames": ["idle"], "fps": 1.0, "time": 2.0, "fx": "befriend", "sfx": "heart"},
	"sit": {"name": "Sit", "frames": ["sit"], "fps": 1.0, "loop": true},
	"sleep": {"name": "Sleep", "frames": ["doze"], "fps": 1.0, "loop": true, "drift": "z"},
	"dance_jig": {"name": "Jig", "frames": ["cheer", "walk0", "cheer", "walk2"], "fps": 4.0, "loop": true, "motion": "hop", "sfx": "dance_jig", "drift": "emote_dance_jig", "dance": true},
	"dance_twirl": {"name": "Twirl", "frames": ["wave0", "wave1"], "fps": 4.0, "loop": true, "motion": "spin", "sfx": "dance_twirl", "drift": "emote_dance_twirl", "dance": true},
	"facepalm": {"name": "Facepalm", "frames": ["palm"], "fps": 1.0, "time": 2.0, "sfx": "miss"},
	"think": {"name": "Think", "frames": ["idle"], "fps": 1.0, "time": 2.2, "unlock": "Cora's quest \"Overdue\""},
	"applause": {"name": "Applause", "frames": ["clap", "idle"], "fps": 8.0, "time": 2.4, "sfx": "applause", "unlock": "The summer festival"},
	"tip_hat": {"name": "Tip hat", "frames": ["bow"], "fps": 1.0, "time": 1.8, "motion": "tip", "unlock": "Grand Casino Boutique"},
	"lucky": {"name": "Lucky!", "frames": ["cheer"], "fps": 1.0, "time": 2.0, "motion": "hop", "fx": "coin", "sfx": "coin", "unlock": "Grand Casino Boutique"},
}

const STARTER := ["wave", "bow", "cheer", "laugh", "thumbs_up", "heart", "sit", "sleep", "dance_jig", "dance_twirl", "facepalm"]
const WHEEL_SLOTS := 8
const DEFAULT_WHEEL := ["wave", "cheer", "laugh", "heart", "dance_jig", "sit", "thumbs_up", "dance_twirl"]

static func exists(id: String) -> bool:
	return LIST.has(id)

static func info(id: String) -> Dictionary:
	return LIST.get(id, {})

static func icon(id: String) -> Texture2D:
	return Art.item("emote_" + id)

static func knows(p: PlayerData, id: String) -> bool:
	return id in STARTER or (p != null and id in p.emotes)

## Every emote in catalogue order, known ones first.
static func ordered(p: PlayerData) -> Array:
	var known: Array = LIST.keys().filter(func(id): return knows(p, id))
	var locked: Array = LIST.keys().filter(func(id): return not knows(p, id))
	return known + locked

## The eight wheel slots from the profile; slots holding an unknown emote come back empty.
static func wheel(p: PlayerData) -> Array:
	var saved: Array = Settings.profile.get("emote_wheel", DEFAULT_WHEEL)
	var out: Array = []
	for i in WHEEL_SLOTS:
		var id := str(saved[i]) if i < saved.size() else ""
		out.append(id if exists(id) and knows(p, id) else "")
	return out

static func set_slot(slot: int, id: String) -> void:
	var w: Array = Settings.profile.get("emote_wheel", DEFAULT_WHEEL).duplicate()
	w.resize(WHEEL_SLOTS)
	for i in WHEEL_SLOTS:
		if w[i] == null:
			w[i] = ""
		elif w[i] == id and i != slot:
			w[i] = ""
	w[slot] = id
	Settings.profile_set("emote_wheel", w)

static func frame_col(id: String, t: float) -> int:
	var e := info(id)
	var frames: Array = e.get("frames", ["idle"])
	var i := int(t * float(e.get("fps", 1.0))) % frames.size()
	return int(COLS.get(frames[i], 0))

## How long a one-shot emote plays; loops return INF.
static func duration(id: String) -> float:
	var e := info(id)
	return INF if e.get("loop", false) else float(e.get("time", 2.0))
