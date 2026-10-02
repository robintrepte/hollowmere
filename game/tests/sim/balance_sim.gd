extends Node
## CI entry point: `godot --headless --path game res://tests/sim/balance_sim.tscn -- --rounds=2 --level=40`
## Exits 1 when the battle sim finds a broken type or too many stalemates.

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var t0 := Time.get_ticks_msec()
	var rep := BalanceSim.run(int(args.get("level", "40")), int(args.get("rounds", "2")), int(args.get("seed", "1")))
	print(BalanceSim.format_report(rep))
	var ok: bool = rep.ok
	if args.has("days"):
		var eco := EconomySim.run(int(args.days), int(args.get("seed", "1")))
		print("")
		print(EconomySim.format_report(eco))
		ok = ok and eco.ok
	print("\nSim finished in %.1fs: %s" % [(Time.get_ticks_msec() - t0) / 1000.0, "OK" if ok else "FAILED"])
	get_tree().quit(0 if ok else 1)
