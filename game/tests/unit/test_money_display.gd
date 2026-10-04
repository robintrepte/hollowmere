extends GutTest
## Money is shown with a coin icon (CoinLabel) or as "1.234 Gold" text, never as a bare "123g".

func _scripts(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("_"):
			_scripts(dir.path_join(d), out)

func test_no_raw_gold_suffix_left() -> void:
	var files: Array = []
	for root in ["res://scenes", "res://core", "res://autoload"]:
		_scripts(root, files)
	var re := RegEx.create_from_string("%d ?g\\b|\\+ ?\"g\"")
	var hits: Array = []
	for path in files:
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			if re.search(lines[i]) != null:
				hits.append("%s:%d" % [path, i + 1])
	assert_eq(hits, [], "use CoinLabel / CoinLabel.text for money")

func test_coin_text_groups_digits() -> void:
	var t := CoinLabel.text(1234567)
	assert_true(t.contains("1") and t.contains("234") and t.contains("567"))
	assert_false(t.contains("1234567"))
