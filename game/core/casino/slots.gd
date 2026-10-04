class_name Slots
extends CasinoGame
## Five reels, three rows, ten paylines. Every theme shares one strip and paytable, so one simulation
## verifies all of them. Wilds stand in for line symbols, scatters pay anywhere on the total bet, five
## jackpot symbols on a line win the progressive pot, scaled by the line bet.

const LINES := 10

func _init(st: Dictionary = {}, seed_base: int = 0) -> void:
	super("slots", st, seed_base)

static func cfg() -> Dictionary:
	return Casino.cfg().get("slots", {})

static func strip() -> String:
	return str(cfg().get("strip", "A"))

## Symbol letters seen in each row: grid[row][reel].
static func grid_for(stops: Array) -> Array:
	var s := strip()
	var g: Array = [[], [], []]
	for reel in 5:
		for row in 3:
			g[row].append(s[(int(stops[reel]) + row) % s.length()])
	return g

## Line wins in line-bet multiples for one line: [symbol, count, multiple].
static func line_win(syms: Array) -> Array:
	var pays: Dictionary = cfg().get("pays", {})
	var base := ""
	for s in syms:
		if s != "W":
			base = s
			break
	var wilds := 0
	for s in syms:
		if s != "W":
			break
		wilds += 1
	var wild_pay := int(pays.W[wilds - 3]) if wilds >= 3 else 0
	if base == "S":
		return ["", 0, 0]
	if base == "":
		return ["W", wilds, wild_pay]
	var n := 0
	for s in syms:
		if s == base or (s == "W" and base != "J"):
			n += 1
		else:
			break
	var pay := int(pays[base][n - 3]) if n >= 3 and pays.has(base) else 0
	if base == "J" and n == 5:
		return ["J", 5, -1]
	if wild_pay > pay:
		return ["W", wilds, wild_pay]
	return [base, n, pay] if pay > 0 else ["", 0, 0]

## Evaluates a spin. Returns {stops, grid, lines: [[line, sym, n, chips]], scatter, jackpot, won}.
static func evaluate(stops: Array, line_bet: int, pot: int) -> Dictionary:
	var g := grid_for(stops)
	var lines: Array = cfg().get("lines", [])
	var won := 0
	var hits: Array = []
	var jackpot := 0
	for li in lines.size():
		var syms: Array = []
		for reel in 5:
			syms.append(g[int(lines[li][reel])][reel])
		var w := line_win(syms)
		if w[0] == "":
			continue
		if int(w[2]) < 0:
			jackpot = pot * line_bet / int(Casino.cfg().tables.slots.max)
			hits.append([li, "J", 5, jackpot])
			won += jackpot
			continue
		var chips := int(w[2]) * line_bet
		hits.append([li, w[0], int(w[1]), chips])
		won += chips
	var sc := 0
	for row in g:
		for s in row:
			if s == "S":
				sc += 1
	var scatter := 0
	if sc >= 3:
		scatter = int(cfg().scatter[mini(sc, 5) - 3]) * line_bet * LINES
		won += scatter
	return {"stops": stops, "grid": g, "lines": hits, "scatter": scatter, "scatters": sc, "jackpot": jackpot, "won": won}

func spin(line_bet: int, pot: int) -> Dictionary:
	var r := next_rng()
	var stops: Array = []
	for i in 5:
		stops.append(r.randi_range(0, strip().length() - 1))
	return evaluate(stops, line_bet, pot)
