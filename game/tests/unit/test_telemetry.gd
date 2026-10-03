extends GutTest
## Error capture and queueing (delivery is covered by tests/net/server_test against a real server).

var _saved: Dictionary

func before_each() -> void:
	_saved = Telemetry.queue.duplicate(true)
	Telemetry.queue.clear()

func after_each() -> void:
	Telemetry.queue = _saved
	Settings.error_reports = true

func test_logger_turns_engine_errors_into_reports() -> void:
	var lg := Telemetry.ErrorLogger.new()
	lg.sink = Telemetry.record
	var no_bt: Array[ScriptBacktrace] = []
	lg._log_error("_ready", "core/variant.cpp", 88, "", "Invalid call. Nonexistent function 'foo'", false, Logger.ERROR_TYPE_SCRIPT, no_bt)
	lg._log_error("_ready", "core/variant.cpp", 88, "", "Invalid call. Nonexistent function 'foo'", false, Logger.ERROR_TYPE_SCRIPT, no_bt)
	lg._log_error("f", "x.cpp", 1, "", "just a warning", false, Logger.ERROR_TYPE_WARNING, no_bt)
	await get_tree().process_frame
	assert_eq(Telemetry.queue.size(), 1, "one report per distinct error, warnings ignored")
	var rep: Dictionary = Telemetry.queue.values()[0]
	assert_eq(rep.count, 2)
	assert_eq(rep.kind, "script")
	assert_string_contains(rep.where, "core/variant.cpp:88")

func test_reports_are_capped_and_respect_the_setting() -> void:
	for i in 40:
		Telemetry.record("error", "error number %d" % i, "x.gd:%d" % i)
	assert_eq(Telemetry.queue.size(), Telemetry.MAX_REPORTS, "a runaway error loop can't flood the server")
	Telemetry.queue.clear()
	Settings.error_reports = false
	Telemetry.record("error", "nope", "x.gd:1")
	assert_true(Telemetry.queue.is_empty(), "turned off in Settings")
