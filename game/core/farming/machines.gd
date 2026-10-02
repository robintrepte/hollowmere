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

static func apply_power(grids: Array, minutes: int) -> void:
	if minutes <= 0:
		return
	for g in grids:
		for k in g.objects:
			var o: Dictionary = g.objects[k]
			if o.kind == "machine" and is_busy(o):
				o.ready_at = int(o.ready_at) - minutes
