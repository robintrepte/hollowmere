extends Node
## Real-world clock for everything that grows, brews and hatches, including while the game is closed.
## Signed-in players use the server's clock so changing the device time does not fast-forward a farm.

signal tick

const TICK_SECONDS := 5.0
const OFFLINE_CAP := 14 * 86400
const RESYNC_SECONDS := 600.0

## Seconds to add to the device clock to get server time.
var offset := 0.0
## Tests and the balance sim drive the clock by hand. Negative = follow the real clock.
var fixed_now := -1.0
var _acc := 0.0
var _since_sync := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func now() -> float:
	if fixed_now >= 0.0:
		return fixed_now
	return Time.get_unix_time_from_system() + offset

## Seconds to add to a unix time to get the player's local wall clock.
func utc_offset() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60

## Seconds that really passed between two stamps: never negative, never more than the offline cap.
static func elapsed(from: float, to: float) -> float:
	return clampf(to - from, 0.0, OFFLINE_CAP)

## Asks the server for its clock (health RPC) and keeps the difference. Halves the round trip.
func sync_server() -> void:
	var net := get_node_or_null("/root/Net")
	if net == null or not net.has_session():
		return
	var sent := Time.get_unix_time_from_system()
	var r: Dictionary = await net.call_rpc("health")
	if r.has("time"):
		var back := Time.get_unix_time_from_system()
		offset = float(r.time) / 1000.0 - (sent + back) * 0.5
	_since_sync = 0.0

func _process(delta: float) -> void:
	if fixed_now >= 0.0:
		return
	_acc += delta
	_since_sync += delta
	if _acc >= TICK_SECONDS:
		_acc = 0.0
		tick.emit()
	if _since_sync >= RESYNC_SECONDS:
		_since_sync = 0.0
		sync_server()

## "2 h 5 min", "12 min", "45 s": how long until something is ready.
static func duration_text(seconds: float) -> String:
	var s := maxi(0, ceili(seconds))
	if s >= 86400:
		var d := s / 86400
		var h := (s % 86400) / 3600
		return TranslationServer.translate("%d d %d h") % [d, h] if h > 0 else TranslationServer.translate("%d d") % d
	if s >= 3600:
		var h2 := s / 3600
		var m := (s % 3600) / 60
		return TranslationServer.translate("%d h %d min") % [h2, m] if m > 0 else TranslationServer.translate("%d h") % h2
	if s >= 60:
		return TranslationServer.translate("%d min") % ceili(s / 60.0)
	return TranslationServer.translate("%d s") % s
