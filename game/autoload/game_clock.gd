extends Node
## Advances in-game time. In co-op only the host ticks; clients receive time from the host.

signal ten_minutes(minute: int)

var running: bool = false
var _accum: float = 0.0
var _pause_reasons: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE

func pause(reason: String) -> void:
	_pause_reasons[reason] = true

func resume(reason: String) -> void:
	_pause_reasons.erase(reason)

func is_paused() -> bool:
	return not _pause_reasons.is_empty() or not running

func clear_pauses() -> void:
	_pause_reasons.clear()

## Fractional progress through the current 10-minute block (for smooth lighting).
func fraction() -> float:
	return clampf(_accum / Settings.seconds_per_ten_minutes(), 0.0, 1.0)

func _process(delta: float) -> void:
	if is_paused() or not Net.is_authority():
		return
	_accum += delta
	var step := Settings.seconds_per_ten_minutes()
	while _accum >= step:
		_accum -= step
		GameState.advance_minutes(10)
		ten_minutes.emit(GameState.world.minute)
