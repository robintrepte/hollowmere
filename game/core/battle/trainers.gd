class_name Trainers
extends RefCounted
## Builds trainer teams (rivals, Wardens) that scale with the player's progress.

## Returns {} if `vid` isn't a trainer, else {name, kind, team: Array[Creature], reward, warden}.
static func team_for(vid: String, shrines_done: int, lead_level: int, rng: RandomNumberGenerator) -> Dictionary:
	var v: Dictionary = Data.villagers.get(vid, {})
	var tr: Dictionary = v.get("trainer", {})
	if tr.is_empty():
		return {}
	var team: Array = []
	var kind: String = tr.get("kind", "warden" if tr.has("warden") else "trainer")
	if tr.has("warden"):
		var order := int(Data.regions.get(tr.warden, {}).get("order", 1))
		var base := 8 + order * 7
		var roster: Array = tr.team
		for i in roster.size():
			var lvl := base + i
			team.append(_make(Data.form_at_level(roster[i], lvl), lvl, rng, 8))
	else:
		# Rivals grow with you: one Wildling per shrine restored (min 1, max 6), levelled near your lead.
		var n := clampi(1 + shrines_done, 1, 6)
		var lines: Array = tr.get("lines", [])
		var lvl2 := maxi(3, lead_level - 1 + shrines_done)
		for i in mini(n, lines.size()):
			var l := maxi(2, lvl2 - (n - 1 - i))
			team.append(_make(Data.form_at_level(lines[i], l), l, rng, 4))
	var items := {}
	if tr.has("warden"):
		items = {"super_potion": 2, "remedy": 1}
	elif shrines_done >= 2:
		items = {"potion": mini(3, shrines_done / 2)}
	return {
		"name": v.get("name", vid), "kind": kind, "team": team,
		"reward": int(tr.get("reward", 200)) * (1 + shrines_done if kind == "rival" else 1),
		"warden": tr.get("warden", ""), "items": items,
		"ai": 2 if tr.has("warden") else 1,
	}

static func _make(species: String, lvl: int, rng: RandomNumberGenerator, min_gene: int) -> Creature:
	var c := Creature.create(species, lvl, rng, {"min_gene": min_gene})
	c.owner = "npc"
	return c

## Wild level for a region, nudged by time of day and the player's progress.
static func wild_level(levels: Array, rng: RandomNumberGenerator, night: bool) -> int:
	var lo := int(levels[0]) if levels.size() > 0 else 2
	var hi := int(levels[1]) if levels.size() > 1 else lo + 4
	return rng.randi_range(lo, hi) + (1 if night else 0)
