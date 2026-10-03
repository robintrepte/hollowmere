class_name Machines
extends RefCounted
## Artisan machine rules: furnace, keg, preserves jar, seed maker.
## Machine object state: {id, kind:"machine", input, output:{id,n,q}, ready_at}

## Returns {ok, consume:{id:n}, output:{id,n,q}, time, reason}
static func can_load(machine_id: String, item_id: String, q: int, inv: Inventory) -> Dictionary:
	var spec: Dictionary = Data.machines.get(machine_id, {})
	if spec.is_empty():
		return {"ok": false, "reason": "That's not a machine."}
	var it: Dictionary = Data.get_item(item_id)
	if spec.has("recipes"):
		for rec in spec.recipes:
			if rec.in == item_id:
				if inv.count(item_id) < int(rec.n):
					return {"ok": false, "reason": "You need %d %s." % [int(rec.n), Data.item_name(item_id)]}
				var consume := {item_id: int(rec.n)}
				if rec.fuel != "":
					if inv.count(rec.fuel) < 1:
						return {"ok": false, "reason": "The furnace needs Coal."}
					consume[rec.fuel] = 1
				return {"ok": true, "consume": consume, "output": {"id": rec.out, "n": 1, "q": 0}, "time": int(rec.time)}
		return {"ok": false, "reason": "The furnace only accepts ore."}
	if spec.get("any", "") == "crop":
		if not it.get("cat", "") in ["crop", "fruit"]:
			return {"ok": false, "reason": "Put a crop or fruit in."}
		if spec.has("seeds"):
			if not Data.has_item(item_id + "_seeds"):
				return {"ok": false, "reason": "That can't be turned into seeds."}
			return {"ok": true, "consume": {item_id: 1}, "output": {"id": item_id + "_seeds", "n": int(spec.seeds), "q": 0}, "time": int(spec.time)}
		var out_id: String = "%s:%s" % [spec.prefix, item_id]
		if Data.get_item(out_id).is_empty():
			return {"ok": false, "reason": "That won't work."}
		return {"ok": true, "consume": {item_id: 1}, "output": {"id": out_id, "n": 1, "q": q}, "time": int(spec.time)}
	return {"ok": false, "reason": ""}

static func is_ready(obj: Dictionary, now_abs: int) -> bool:
	return not obj.get("output", {}).is_empty() and now_abs >= int(obj.get("ready_at", 0))

static func is_busy(obj: Dictionary) -> bool:
	return not obj.get("output", {}).is_empty()

static func remaining(obj: Dictionary, now_abs: int) -> int:
	return maxi(0, int(obj.get("ready_at", 0)) - now_abs)

## Spark workers run the machine line overnight: finished goods go into the farm chest, then idle
## machines are refilled from it with whatever earns the most. Seed makers are left to the player
## because they eat crops at a loss. `slots` = machines the workers can service.
static func automate(grids: Array, chest: Inventory, now_abs: int, slots: int, rep: Dictionary) -> void:
	for g in grids:
		for k in g.objects:
			if slots <= 0:
				return
			var o: Dictionary = g.objects[k]
			if o.kind != "machine" or o.id == "seed_maker":
				continue
			var served := false
			if is_ready(o, now_abs):
				var out: Dictionary = o.output
				if chest.add(out.id, int(out.n), int(out.q)) > 0:
					continue
				rep.items[out.id] = int(rep.items.get(out.id, 0)) + int(out.n)
				rep.machines_collected = int(rep.get("machines_collected", 0)) + 1
				o.output = {}
				o.input = ""
				served = true
			if not is_busy(o):
				var pick := best_input(o.id, chest)
				if not pick.is_empty():
					var need := int(pick.consume[pick.id])
					if int(chest.find(pick.uid).entry.n) >= need:
						chest.take(pick.uid, need)
					else:
						chest.remove(pick.id, need)
					for c in pick.consume:
						if c != pick.id:
							chest.remove(c, int(pick.consume[c]))
					o.input = pick.id
					o.output = pick.output
					o.ready_at = now_abs + int(pick.time)
					rep.machines_loaded = int(rep.get("machines_loaded", 0)) + 1
					served = true
			if served:
				slots -= 1

## The chest entry that gains the most value in this machine, with can_load's result merged in.
static func best_input(machine_id: String, chest: Inventory) -> Dictionary:
	var best := {}
	var best_gain := 0
	for e in chest.all_entries():
		var chk := can_load(machine_id, e.id, int(e.q), chest)
		if not chk.ok:
			continue
		var gain := Data.sell_price(chk.output.id, int(chk.output.q)) * int(chk.output.n)
		for c in chk.consume:
			gain -= Data.sell_price(c, int(e.q) if c == e.id else 0) * int(chk.consume[c])
		if gain > best_gain:
			best_gain = gain
			chk.uid = e.uid
			chk.id = e.id
			best = chk
	return best

static func apply_power(grids: Array, minutes: int) -> void:
	if minutes <= 0:
		return
	for g in grids:
		for k in g.objects:
			var o: Dictionary = g.objects[k]
			if o.kind == "machine" and is_busy(o):
				o.ready_at = int(o.ready_at) - minutes
