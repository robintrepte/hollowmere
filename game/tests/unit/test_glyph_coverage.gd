extends GutTest
## Every character the game can show must exist in both UI fonts or the bundled fallback.
## Browsers have no system fonts to fall back on and draw a hex box instead.

const SOURCES := ["res://scenes", "res://core", "res://autoload", "res://data", "res://i18n"]
const EXTENSIONS := ["gd", "json", "po"]

func _collect(dir_path: String, out: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect(dir_path.path_join(sub), out)
	for f in dir.get_files():
		if not f.get_extension() in EXTENSIONS:
			continue
		var txt := FileAccess.get_file_as_string(dir_path.path_join(f))
		for i in txt.length():
			var c := txt.unicode_at(i)
			if c > 126 and not out.has(c):
				out[c] = dir_path.path_join(f)

func _missing(face: String) -> Array:
	var base: FontFile = load("res://assets/fonts/%s.ttf" % face)
	var fallback := UITheme.symbols()
	var used := {}
	for s in SOURCES:
		_collect(s, used)
	var out: Array = []
	for c in used:
		if not base.has_char(c) and not fallback.has_char(c):
			out.append("%s U+%04X (%s)" % [String.chr(c), c, used[c]])
	return out

func test_pixel_font_covers_every_character() -> void:
	var miss := _missing("Tiny5")
	assert_eq(miss.size(), 0, "Missing in Tiny5 + fallback: %s" % ", ".join(miss))

func test_readable_font_covers_every_character() -> void:
	var miss := _missing("Nunito")
	assert_eq(miss.size(), 0, "Missing in Nunito + fallback: %s" % ", ".join(miss))
