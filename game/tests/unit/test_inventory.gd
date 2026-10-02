extends GutTest

func test_add_and_stack() -> void:
	var inv := Inventory.new(4, 2)
	assert_eq(inv.add("parsnip_seeds", 10), 0)
	assert_eq(inv.add("parsnip_seeds", 5), 0)
	assert_eq(inv.entries.size(), 1)
	assert_eq(inv.count("parsnip_seeds"), 15)

func test_big_items_take_space() -> void:
	var inv := Inventory.new(3, 3)
	var sz := Data.item_size("storage_crate")
	assert_eq(sz, Vector2i(2, 2))
	assert_eq(inv.add("storage_crate", 1), 0)
	assert_eq(inv.add("storage_crate", 1), 1, "Second 2x2 crate does not fit in 3x3")

func test_rotation() -> void:
	var inv := Inventory.new(1, 2)
	assert_eq(inv.add("tool_belt", 1), 0, "2x1 belt fits rotated in a 1x2 grid")
	assert_true(bool(inv.entries[0].r))

func test_containers_absorb_matching_items() -> void:
	var inv := Inventory.new(4, 4)
	inv.add("seed_pouch", 1)
	inv.add("parsnip_seeds", 10)
	var pouch: Dictionary = inv.first_of("seed_pouch")
	assert_eq(pouch.inv.count("parsnip_seeds"), 10, "Seeds auto-sorted into pouch")
	assert_eq(inv.count("parsnip_seeds"), 10, "count() is recursive")
	assert_true(inv.remove("parsnip_seeds", 4))
	assert_eq(inv.count("parsnip_seeds"), 6)

func test_container_filter_and_no_nesting() -> void:
	var inv := Inventory.new(4, 4)
	inv.add("seed_pouch", 1)
	var pouch: Dictionary = inv.first_of("seed_pouch")
	assert_false(pouch.inv.accepts("copper_ore"))
	assert_false(pouch.inv.accepts("seed_pouch"))

func test_move_and_merge() -> void:
	var a := Inventory.new(4, 4)
	var b := Inventory.new(4, 4)
	a.add("wood", 10)
	b.add("wood", 5)
	var uid: String = a.entries[0].uid
	assert_true(b.move_from(a, uid, int(b.entries[0].x), int(b.entries[0].y), false))
	assert_eq(b.count("wood"), 15)
	assert_eq(a.count("wood"), 0)

func test_split() -> void:
	var inv := Inventory.new(4, 4)
	inv.add("wood", 10)
	assert_true(inv.split(inv.entries[0].uid, 4))
	assert_eq(inv.entries.size(), 2)
	assert_eq(inv.count("wood"), 10)

func test_serialization_roundtrip() -> void:
	var inv := Inventory.new(5, 5)
	inv.add("seed_pouch", 1)
	inv.add("parsnip_seeds", 12)
	inv.add("hoe", 1)
	inv.add("wildling_egg", 1, 0, {"egg": {"species": "sproutle"}})
	var d := inv.to_dict()
	var inv2 := Inventory.new(1, 1)
	inv2.from_dict(JSON.parse_string(JSON.stringify(d)))
	assert_eq(inv2.w, 5)
	assert_eq(inv2.count("parsnip_seeds"), 12)
	assert_eq(inv2.first_of("wildling_egg").meta.egg.species, "sproutle")

func test_auto_sort_keeps_everything() -> void:
	var inv := Inventory.new(6, 4)
	for id in ["hoe", "axe", "storage_crate", "wood", "stone", "tool_belt"]:
		inv.add(id, 1)
	var before := inv.used_cells()
	inv.auto_sort()
	assert_eq(inv.used_cells(), before)
	assert_eq(inv.all_entries().size(), 6)

func test_hotbar_rebinds_by_id() -> void:
	var p := PlayerData.new()
	p.give_starter_kit()
	var e := p.hotbar_entry(5)
	assert_eq(e.id, "parsnip_seeds")
	p.inventory.remove("parsnip_seeds", 15)
	assert_true(p.hotbar_entry(5).is_empty())
	p.inventory.add("parsnip_seeds", 3)
	assert_eq(p.hotbar_entry(5).id, "parsnip_seeds")
