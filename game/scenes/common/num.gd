class_name Num
extends RefCounted
## Locale-aware number formatting: 1.234 in German, 1,234 in English; short forms for the HUD.

static func _sep() -> String:
	return "." if _german_style() else ","

static func _dec() -> String:
	return "," if _german_style() else "."

static func _german_style() -> bool:
	return TranslationServer.get_locale().substr(0, 2) in ["de", "fr", "es", "it", "pt", "nl", "da", "tr", "pl", "id"]

## 1234567 -> "1.234.567" (de) or "1,234,567" (en).
static func group(n: int) -> String:
	var neg := n < 0
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = _sep() + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if neg else "") + s + out

## 1.5 -> "1,5" (de) or "1.5" (en).
static func decimal(v: float, digits: int = 1) -> String:
	return String.num(v, digits).replace(".", _dec())

## A short date from a datetime dict: "24.12." (de) or "12/24" (en).
static func day_month(d: Dictionary) -> String:
	return "%02d.%02d." % [d.day, d.month] if _german_style() else "%d/%d" % [d.month, d.day]

## Compact form for tight spaces: 950, 12,3k, 1,2 Mio. (de) / 12.3k, 1.2M (en).
static func short(n: int) -> String:
	var a := absi(n)
	if a < 10000:
		return group(n)
	var v: float
	var unit: String
	if a >= 1000000:
		v = n / 1000000.0
		unit = str(TranslationServer.translate("M"))
	else:
		v = n / 1000.0
		unit = "k"
	var txt := String.num(v, 1 if absf(v) < 100.0 else 0).replace(".", _dec())
	if txt.ends_with(_dec() + "0"):
		txt = txt.substr(0, txt.length() - 2)
	return txt + ("\u202f" + unit if unit.length() > 1 else unit)
