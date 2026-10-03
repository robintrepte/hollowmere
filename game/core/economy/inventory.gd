class_name Inventory
extends RefCounted
## Tarkov-style grid inventory. Items occupy WxH cells (rotatable). Container items
## carry their own nested Inventory (often bigger inside than outside) with an
## optional category filter. New items auto-stack, then auto-sort into accepting
## containers, then take the first free spot in the main grid.
##
## Entry: {uid, id, n, q, meta, x, y, r, inv?}

signal changed

var w: int = 6
var h: int = 4
var filter: Array = []
var nested: bool = false
var sellable_only: bool = false
var entries: Array = []

static var _uid_counter: int = 0

func _init(width: int = 6, height: int = 4, filt: Array = [], is_nested: bool = false, only_sellable: bool = false) -> void:
	w = width
	h = height
	filter = filt
	nested = is_nested
	sellable_only = only_sellable

static func new_uid() -> String:
	_uid_counter += 1
	return "%x%04x" % [int(Time.get_unix_time_from_system() * 1000.0) % 0xffffffff, (_uid_counter + randi()) % 0xffff]

static func size_of(id: String, rotated: bool) -> Vector2i:
	var s: Vector2i = Data.item_size(id)
	return Vector2i(s.y, s.x) if rotated else s

static func entry_size(e: Dictionary) -> Vector2i:
	return size_of(e.id, bool(e.get("r", false)))

func resize(width: int, height: int) -> void:
	w = width
	h = height
	changed.emit()

func accepts(id: String) -> bool:
	if not Data.has_item(id):
		return false
	if nested and not Data.container_spec(id).is_empty():
		return false
	if sellable_only and Data.sell_price(id, 0) <= 0:
		return false
	if filter.is_empty():
		return true
	return Data.get_item(id).get("cat", "") in filter

func _overlaps(ax: int, ay: int, asz: Vector2i, bx: int, by: int, bsz: Vector2i) -> bool:
	return ax < bx + bsz.x and bx < ax + asz.x and ay < by + bsz.y and by < ay + asz.y

func can_place(sz: Vector2i, x: int, y: int, ignore_uid: String = "") -> bool:
	if x < 0 or y < 0 or x + sz.x > w or y + sz.y > h:
		return false
	for e in entries:
		if e.uid == ignore_uid:
			continue
		if _overlaps(x, y, sz, int(e.x), int(e.y), entry_size(e)):
			return false
	return true

func entry_at(x: int, y: int) -> Dictionary:
	for e in entries:
		var s := entry_size(e)
		if x >= int(e.x) and x < int(e.x) + s.x and y >= int(e.y) and y < int(e.y) + s.y:
			return e
	return {}

## Finds a free position for an item. Returns {x, y, r} or {}.
func find_space(id: String) -> Dictionary:
	var base: Vector2i = Data.item_size(id)
	var rots := [false] if base.x == base.y else [false, true]
	for r in rots:
		var sz := size_of(id, r)
		for y in h:
			for x in w:
				if can_place(sz, x, y):
					return {"x": x, "y": y, "r": r}
	return {}

func _make_entry(id: String, n: int, q: int, meta: Dictionary, pos: Dictionary) -> Dictionary:
	var e := {"uid": new_uid(), "id": id, "n": n, "q": q, "meta": meta.duplicate(true), "x": pos.x, "y": pos.y, "r": pos.r}
	var spec: Dictionary = Data.container_spec(id)
	if not spec.is_empty():
		var inv := Inventory.new(int(spec.w), int(spec.h), spec.get("filter", []), true)
		if meta.has("inv"):
			inv.from_dict(meta.inv)
			e.meta.erase("inv")
		inv.changed.connect(func(): changed.emit())
		e["inv"] = inv
	return e

func containers() -> Array:
	var out: Array = []
	for e in entries:
		if e.has("inv"):
			out.append(e)
	return out

func _stack_here(id: String, n: int, q: int, meta: Dictionary) -> int:
	if not meta.is_empty() or n <= 0:
		return n
	var mx: int = Data.stack_max(id)
	var left := n
	for e in entries:
		if left <= 0:
			break
		if e.id == id and int(e.q) == q and e.meta.is_empty() and int(e.n) < mx:
			var take := mini(left, mx - int(e.n))
			e.n = int(e.n) + take
			left -= take
	return left

func _stack_into_existing(id: String, n: int, q: int, meta: Dictionary) -> int:
	var left := _stack_here(id, n, q, meta)
	for c in containers():
		if left <= 0:
			break
		if c.inv.accepts(id):
			left = c.inv._stack_into_existing(id, left, q, meta)
	return left

func _fill_filtered(id: String, n: int, q: int, meta: Dictionary) -> int:
	var left := n
	for c in containers():
		if left <= 0:
			break
		if c.inv.accepts(id) and not c.inv.filter.is_empty():
			left = c.inv._place_new(id, left, q, meta)
	return left

func _fill_open(id: String, n: int, q: int, meta: Dictionary) -> int:
	var left := n
	for c in containers():
		if left <= 0:
			break
		if c.inv.accepts(id) and c.inv.filter.is_empty():
			left = c.inv._place_new(id, left, q, meta)
	return left

func _place_new(id: String, n: int, q: int, meta: Dictionary) -> int:
	var mx: int = Data.stack_max(id) if meta.is_empty() else 1
	var left := n
	while left > 0:
		var pos := find_space(id)
		if pos.is_empty():
			break
		var take := mini(left, mx)
		if take <= 0:
			break
		entries.append(_make_entry(id, take, q, meta, pos))
		left -= take
	return left

## Adds items; returns the number that didn't fit.
## containers_first files new stacks into matching bags (seed pouch, treat tin, …)
## before the main grid. Purchases pass false so they show up in the pack.
func add(id: String, n: int = 1, q: int = 0, meta: Dictionary = {}, containers_first: bool = true) -> int:
	if n <= 0 or not accepts(id):
		return n
	var left := n
	if containers_first:
		left = _stack_into_existing(id, left, q, meta)
		left = _fill_filtered(id, left, q, meta)
		if left > 0:
			left = _place_new(id, left, q, meta)
	else:
		left = _stack_here(id, left, q, meta)
		if left > 0:
			left = _place_new(id, left, q, meta)
		if left > 0:
			for c in containers():
				if left <= 0:
					break
				if c.inv.accepts(id):
					left = c.inv._stack_into_existing(id, left, q, meta)
		left = _fill_filtered(id, left, q, meta)
	if left > 0:
		left = _fill_open(id, left, q, meta)
	if left != n:
		changed.emit()
	return left

## True if all n would fit (simulated on a copy).
func can_add(id: String, n: int = 1, q: int = 0, containers_first: bool = true) -> bool:
	var copy := Inventory.new(w, h, filter, nested, sellable_only)
	copy.from_dict(to_dict())
	return copy.add(id, n, q, {}, containers_first) == 0

## How many of id sit in this grid, and inside each container.
func homes_of(id: String) -> Dictionary:
	var top := 0
	for e in entries:
		if e.id == id:
			top += int(e.n)
	var bags: Array = []
	for c in containers():
		var have: int = c.inv.count(id)
		if have > 0:
			bags.append({"uid": c.uid, "name": Data.item_name(c.id), "n": have})
	return {"top": top, "bags": bags}

func all_entries() -> Array:
	var out: Array = []
	for e in entries:
		out.append(e)
		if e.has("inv"):
			out.append_array(e.inv.all_entries())
	return out

func count(id: String) -> int:
	var t := 0
	for e in all_entries():
		if e.id == id:
			t += int(e.n)
	return t

func has(id: String, n: int = 1) -> bool:
	return count(id) >= n

## Finds an entry by uid anywhere (including inside containers). Returns {inv, entry} or {}.
func find(uid: String) -> Dictionary:
	for e in entries:
		if e.uid == uid:
			return {"inv": self, "entry": e}
		if e.has("inv"):
			var r: Dictionary = e.inv.find(uid)
			if not r.is_empty():
				return r
	return {}

func first_of(id: String) -> Dictionary:
	for e in all_entries():
		if e.id == id:
			return e
	return {}

func _remove_entry(e: Dictionary) -> void:
	entries.erase(e)

## Removes n of an item, lowest quality first, searching nested containers too.
func remove(id: String, n: int = 1) -> bool:
	if count(id) < n:
		return false
	var left := n
	for q in [0, 1, 2, 3]:
		left = _remove_q(id, left, q)
		if left <= 0:
			break
	changed.emit()
	return true

func _remove_q(id: String, n: int, q: int) -> int:
	var left := n
	for e in entries.duplicate():
		if left <= 0:
			return 0
		if e.has("inv"):
			left = e.inv._remove_q(id, left, q)
		if left > 0 and e.id == id and int(e.q) == q:
			var take := mini(left, int(e.n))
			e.n = int(e.n) - take
			left -= take
			if int(e.n) <= 0:
				_remove_entry(e)
	return left

## Removes n from a specific entry. Returns the removed portion as an item dict.
func take(uid: String, n: int = 1) -> Dictionary:
	var f := find(uid)
	if f.is_empty():
		return {}
	var e: Dictionary = f.entry
	var amt := mini(n, int(e.n))
	var out := {"id": e.id, "n": amt, "q": e.q, "meta": e.meta.duplicate(true)}
	if e.has("inv"):
		out.meta["inv"] = e.inv.to_dict()
	e.n = int(e.n) - amt
	if int(e.n) <= 0:
		f.inv._remove_entry(e)
	f.inv.changed.emit()
	changed.emit()
	return out

## Moves an entry (by uid) from `src` into this grid at x,y (rotated r).
## Merges with a matching stack at the target cell; drops into a container if
## the target cell holds an accepting container. Returns true on success.
func move_from(src: Inventory, uid: String, x: int, y: int, r: bool) -> bool:
	var f := src.find(uid)
	if f.is_empty():
		return false
	var e: Dictionary = f.entry
	var owner: Inventory = f.inv
	if not accepts(e.id):
		return false
	# A bag can move around the grid it already sits in. Block only a drop into
	# that bag, or into something packed inside it.
	if e.has("inv") and e.inv._contains_inv(self):
		return false
	var target := entry_at(x, y)
	if not target.is_empty() and target.uid != uid:
		if target.id == e.id and int(target.q) == int(e.q) and target.meta.is_empty() and e.meta.is_empty():
			var mx: int = Data.stack_max(e.id)
			var take_n := mini(int(e.n), mx - int(target.n))
			if take_n <= 0:
				return false
			target.n = int(target.n) + take_n
			e.n = int(e.n) - take_n
			if int(e.n) <= 0:
				owner._remove_entry(e)
			owner.changed.emit()
			changed.emit()
			return true
		if target.has("inv") and target.inv.accepts(e.id) and not e.has("inv"):
			var pos: Dictionary = target.inv.find_space(e.id)
			var left: int = target.inv._stack_into_existing(e.id, int(e.n), int(e.q), e.meta)
			if left > 0:
				if pos.is_empty():
					if left == int(e.n):
						return false
				else:
					target.inv.entries.append(target.inv._make_entry(e.id, left, int(e.q), e.meta, pos))
					left = 0
			e.n = left
			if left <= 0:
				owner._remove_entry(e)
			target.inv.changed.emit()
			owner.changed.emit()
			changed.emit()
			return true
	var sz := size_of(e.id, r)
	var ignore: String = uid if owner == self else ""
	if not can_place(sz, x, y, ignore):
		return false
	owner._remove_entry(e)
	e.x = x
	e.y = y
	e.r = r
	entries.append(e)
	owner.changed.emit()
	changed.emit()
	return true

func _contains_inv(inv: Inventory) -> bool:
	if inv == self:
		return true
	for e in entries:
		if e.has("inv") and e.inv._contains_inv(inv):
			return true
	return false

## Splits n off a stack into a free spot in the same grid.
func split(uid: String, n: int) -> bool:
	var f := find(uid)
	if f.is_empty():
		return false
	var e: Dictionary = f.entry
	if n <= 0 or n >= int(e.n):
		return false
	var inv: Inventory = f.inv
	var pos := inv.find_space(e.id)
	if pos.is_empty():
		return false
	e.n = int(e.n) - n
	inv.entries.append(inv._make_entry(e.id, n, int(e.q), e.meta, pos))
	inv.changed.emit()
	changed.emit()
	return true

func rotate(uid: String) -> bool:
	var f := find(uid)
	if f.is_empty():
		return false
	var e: Dictionary = f.entry
	var nr := not bool(e.r)
	if not f.inv.can_place(size_of(e.id, nr), int(e.x), int(e.y), uid):
		return false
	e.r = nr
	f.inv.changed.emit()
	changed.emit()
	return true

func entries_of_cat(cats: Array) -> Array:
	var out: Array = []
	for e in all_entries():
		if Data.get_item(e.id).get("cat", "") in cats:
			out.append(e)
	return out

func is_empty() -> bool:
	return entries.is_empty()

func used_cells() -> int:
	var t := 0
	for e in entries:
		var s := entry_size(e)
		t += s.x * s.y
	return t

func clear() -> void:
	entries.clear()
	changed.emit()

## Re-packs everything (largest first) to defragment the grid.
func auto_sort() -> void:
	var items: Array = entries.duplicate()
	items.sort_custom(func(a, b):
		var sa := Data.item_size(a.id)
		var sb := Data.item_size(b.id)
		if sa.x * sa.y != sb.x * sb.y:
			return sa.x * sa.y > sb.x * sb.y
		var ca: String = Data.get_item(a.id).get("cat", "")
		var cb: String = Data.get_item(b.id).get("cat", "")
		if ca != cb:
			return ca < cb
		return str(a.id) < str(b.id))
	entries.clear()
	var overflow: Array = []
	for e in items:
		var pos := find_space(e.id)
		if pos.is_empty():
			overflow.append(e)
			continue
		e.x = pos.x
		e.y = pos.y
		e.r = pos.r
		entries.append(e)
	for e in overflow:
		var pos2 := find_space(e.id)
		if not pos2.is_empty():
			e.x = pos2.x
			e.y = pos2.y
			e.r = pos2.r
		entries.append(e)
	changed.emit()

func to_dict() -> Dictionary:
	var arr: Array = []
	for e in entries:
		var d := {"uid": e.uid, "id": e.id, "n": e.n, "q": e.q, "meta": e.meta.duplicate(true), "x": e.x, "y": e.y, "r": e.r}
		if e.has("inv"):
			d["inv"] = e.inv.to_dict()
		arr.append(d)
	return {"w": w, "h": h, "entries": arr}

func from_dict(d: Dictionary) -> void:
	entries.clear()
	if d.has("w") and not nested:
		w = int(d.w)
		h = int(d.h)
	for raw in d.get("entries", []):
		if not Data.has_item(raw.get("id", "")):
			continue
		var meta: Dictionary = raw.get("meta", {}).duplicate(true)
		if raw.has("inv"):
			meta["inv"] = raw.inv
		var e := _make_entry(raw.id, int(raw.get("n", 1)), int(raw.get("q", 0)), meta, {"x": int(raw.get("x", 0)), "y": int(raw.get("y", 0)), "r": bool(raw.get("r", false))})
		e.uid = raw.get("uid", e.uid)
		entries.append(e)
	changed.emit()
