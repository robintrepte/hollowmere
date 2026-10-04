extends GutTest
## German UI uses the gaming terms players know (see res://i18n/GLOSSARY.md).

const PO := "res://i18n/de.po"
const EXPECTED := {
	"Co-op": "Koop",
	"Play together": "Koop",
	"Crafting": "Crafting",
	"Valley map": "Tal-Map",
	"Journal": "Journal",
	"Party": "Party",
}
## Translations that read like a dictionary instead of a game.
const FORBIDDEN := ["Zusammen spielen", "zusammen spielen", "Talkarte", "Tagebuch", "\\bHandwerk\\b", "Herstellen",
	"Gegenst[aä]nd", "Schnellleiste", "Schnellplatz", "Gastgeb", "Gruppenmitglied", "deine Gruppe"]

func _entries() -> Dictionary:
	var out := {}
	var id := ""
	for line in FileAccess.get_file_as_string(PO).split("\n"):
		if line.begins_with("msgid \""):
			id = line.substr(7, line.length() - 8)
		elif line.begins_with("msgstr \""):
			out[id] = line.substr(8, line.length() - 9)
	return out

func test_core_terms_use_gaming_words() -> void:
	var po := _entries()
	for en in EXPECTED:
		assert_eq(po.get(en, ""), EXPECTED[en], "%s → %s" % [en, EXPECTED[en]])

func test_no_dictionary_translations_left() -> void:
	var po := _entries()
	for pat in FORBIDDEN:
		var re := RegEx.create_from_string(pat)
		var hits: Array = []
		for en in po:
			if re.search(po[en]):
				hits.append(en)
		assert_eq(hits.size(), 0, "'%s' still used for: %s" % [pat, ", ".join(hits)])
