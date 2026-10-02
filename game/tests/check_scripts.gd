extends Node
## Loads every project script so parse/type errors surface in CI:
##   godot --headless --path game res://tests/check_scripts.tscn

func _ready() -> void:
	var failed := 0
	var files: Array = []
	_collect("res://", files)
	for f in files:
		var s = load(f)
		if s == null or (s is GDScript and not s.can_instantiate() and not s.is_abstract()):
			print("FAILED: ", f)
			failed += 1
	print("Checked %d scripts, %d failed" % [files.size(), failed])
	get_tree().quit(1 if failed > 0 else 0)

func _collect(dir: String, out: Array) -> void:
	for d in DirAccess.get_directories_at(dir):
		if d.begins_with(".") or d == "addons":
			continue
		_collect(dir.path_join(d), out)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
