class_name Emotes
extends RefCounted
## The fixed emote set: which paper-doll poses an emote cycles through, how the body moves on top
## of that, and the bubble, particles and sound that go with it. Every player has the same ones.

## Paper-doll sheet columns (see tools/art_pipeline/character.py).
const COLS := {"idle": 0, "walk0": 1, "walk2": 3, "cheer": 7, "wave0": 8, "wave1": 9, "bow": 10, "sit": 11, "doze": 12, "clap": 13, "palm": 14}

## frames: sheet columns cycled at fps. loop: plays until the player moves, otherwise for time seconds.
## motion: hop | giggle | bow | spin. drift: an icon or text that floats up now and then.
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
}

const STARTER := ["wave", "bow", "cheer", "laugh", "thumbs_up", "heart", "sit", "sleep", "dance_jig", "dance_twirl", "facepalm"]

static func exists(id: String) -> bool:
	return LIST.has(id)

static func info(id: String) -> Dictionary:
	return LIST.get(id, {})

static func icon(id: String) -> Texture2D:
	return Art.item("emote_" + id)

static func knows(_p: PlayerData, id: String) -> bool:
	return id in STARTER

## The wheel is the fixed set, in catalogue order.
static func wheel(_p: PlayerData = null) -> Array:
	return STARTER.duplicate()

static func frame_col(id: String, t: float) -> int:
	var e := info(id)
	var frames: Array = e.get("frames", ["idle"])
	var i := int(t * float(e.get("fps", 1.0))) % frames.size()
	return int(COLS.get(frames[i], 0))

## How long a one-shot emote plays; loops return INF.
static func duration(id: String) -> float:
	var e := info(id)
	return INF if e.get("loop", false) else float(e.get("time", 2.0))
