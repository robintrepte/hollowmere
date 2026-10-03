extends Node
## Crash and error reports, plus opt-in play stats, sent to the Hollowmere Nakama server.
## Reports queue on disk and go out once the player has a server session. Release builds only
## (or with hollowmere/telemetry/force), so development errors stay in the console.

const QUEUE_PATH := "user://telemetry_queue.json"
const LOCK_PATH := "user://session.lock"
const MAX_REPORTS := 25          # distinct errors kept per session
const MAX_QUEUE := 60
const FLUSH_EVERY := 60.0
const HEARTBEAT_EVERY := 300.0

var enabled := false
var queue: Dictionary = {}       # sig -> report
var _mutex := Mutex.new()
var _logger: ErrorLogger
var _flush_t := 0.0
var _beat_t := 0.0
var _beat_minutes := 0.0
var _new_session := true
var _flushing := false

class ErrorLogger extends Logger:
	var sink: Callable

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var where := "%s:%d (%s)" % [file, line, function]
		for bt in script_backtraces:
			if bt.get_frame_count() > 0:
				where = "%s:%d (%s)" % [bt.get_frame_file(0), bt.get_frame_line(0), bt.get_frame_function(0)]
				break
		sink.call_deferred("script" if error_type == ERROR_TYPE_SCRIPT else "error", rationale if rationale != "" else code, where)

	func _log_message(_message: String, _error: bool) -> void:
		pass

func _ready() -> void:
	enabled = not OS.is_debug_build() or bool(ProjectSettings.get_setting("hollowmere/telemetry/force", false))
	_load_queue()
	if not enabled:
		return
	_logger = ErrorLogger.new()
	_logger.sink = record
	OS.add_logger(_logger)
	if not OS.has_feature("web"):
		if FileAccess.file_exists(LOCK_PATH):
			record("crash", "The game closed unexpectedly", "previous session", _previous_log_tail())
		var f := FileAccess.open(LOCK_PATH, FileAccess.WRITE)
		if f:
			f.store_string(str(Time.get_unix_time_from_system()))

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		shutdown()

## Clean exit: drop the crash marker, send the last play minutes, keep unsent reports for next time.
func shutdown() -> void:
	if FileAccess.file_exists(LOCK_PATH):
		DirAccess.remove_absolute(LOCK_PATH)
	_save_queue()

func record(kind: String, msg: String, where: String, log_tail: String = "") -> void:
	if not Settings.error_reports and kind != "crash":
		return
	var sig := "%s @ %s" % [msg.left(160), where.left(120)]
	_mutex.lock()
	if queue.has(sig):
		queue[sig].count += 1
	elif queue.size() < MAX_QUEUE and _session_reports() < MAX_REPORTS:
		queue[sig] = {"sig": sig, "msg": msg.left(600), "where": where, "kind": kind, "count": 1,
			"version": str(ProjectSettings.get_setting("application/config/version", "")), "platform": OS.get_name(),
			"log": log_tail, "session": true}
	_mutex.unlock()

func _session_reports() -> int:
	var n := 0
	for k in queue:
		if queue[k].get("session", false):
			n += 1
	return n

func _process(delta: float) -> void:
	if not enabled:
		return
	_flush_t += delta
	_beat_t += delta
	_beat_minutes += delta / 60.0
	if _flush_t >= FLUSH_EVERY:
		_flush_t = 0.0
		flush()
	if _beat_t >= HEARTBEAT_EVERY:
		_beat_t = 0.0
		heartbeat()

func flush() -> void:
	if _flushing or queue.is_empty() or not Net.has_session() or not Settings.error_reports:
		return
	_flushing = true
	_mutex.lock()
	var batch: Array = queue.values().slice(0, MAX_REPORTS)
	_mutex.unlock()
	var r: Dictionary = await Net.call_rpc("report_errors", {"reports": batch})
	if not r.has("error"):
		_mutex.lock()
		for rep in batch:
			queue.erase(rep.sig)
		_mutex.unlock()
		_save_queue()
	_flushing = false

## Opt-in only: minutes played since the last beat and how far the farm has come.
func heartbeat() -> void:
	if not Settings.analytics or not Net.has_session():
		return
	var mins := roundi(_beat_minutes)
	var r: Dictionary = await Net.call_rpc("track_session", {"minutes": mins, "new_session": _new_session,
		"version": str(ProjectSettings.get_setting("application/config/version", "")), "platform": OS.get_name(),
		"game_day": GameState.day() if GameState.started else 0})
	if not r.has("error"):
		_new_session = false
		_beat_minutes -= mins

func _previous_log_tail(lines: int = 60) -> String:
	var dir := "user://logs"
	var newest := ""
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("godot") and f.ends_with(".log") and f != "godot.log" and f > newest:
			newest = f
	if newest == "":
		return ""
	var all := FileAccess.get_file_as_string(dir.path_join(newest)).split("\n")
	return "\n".join(all.slice(maxi(0, all.size() - lines)))

func _load_queue() -> void:
	if not FileAccess.file_exists(QUEUE_PATH):
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(QUEUE_PATH))
	if d is Dictionary:
		queue = d

func _save_queue() -> void:
	_mutex.lock()
	var keep := {}
	for k in queue:
		var rep: Dictionary = queue[k].duplicate()
		rep.erase("session")
		keep[k] = rep
	_mutex.unlock()
	if keep.is_empty():
		if FileAccess.file_exists(QUEUE_PATH):
			DirAccess.remove_absolute(QUEUE_PATH)
		return
	var f := FileAccess.open(QUEUE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(keep))
