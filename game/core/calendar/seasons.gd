class_name Seasons
extends RefCounted
## Seasons follow the real calendar (meteorological: 1 Mar, 1 Jun, 1 Sep, 1 Dec), flipped in the south.

const ORDER := ["spring", "summer", "fall", "winter"]
## Country codes south of the equator for most of their people.
const SOUTH := ["AR", "AU", "BO", "BR", "BW", "CL", "FJ", "LS", "MG", "MU", "MW", "MZ", "NA", "NZ", "PE",
	"PY", "SZ", "UY", "ZA", "ZM", "ZW"]

## Tests, screenshots and `--season=winter` pin the season. "" = follow the calendar.
static var override := ""

static func for_month(month: int, hemisphere: String = "north") -> String:
	var i := int(((month % 12) / 3))
	if hemisphere == "south":
		i = (i + 2) % 4
	return ["winter", "spring", "summer", "fall"][i]

static func for_unix(unix: float, hemisphere: String = "north") -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(unix))
	return for_month(int(d.month), hemisphere)

static func hemisphere_for_locale(locale: String) -> String:
	var parts := locale.replace("-", "_").split("_")
	if parts.size() >= 2 and parts[1].to_upper() in SOUTH:
		return "south"
	return "north"

static func hemisphere(setting: String, locale: String) -> String:
	if setting in ["north", "south"]:
		return setting
	return hemisphere_for_locale(locale)

static func cmdline_override() -> String:
	for a in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if a.begins_with("--season="):
			var s := a.trim_prefix("--season=")
			if s in ORDER:
				return s
	return ""

## The season right now on this device, honouring overrides and the hemisphere setting.
static func current(unix: float, hemisphere_setting: String = "auto") -> String:
	if override != "":
		return override
	var cl := cmdline_override()
	if cl != "":
		return cl
	return for_unix(unix, hemisphere(hemisphere_setting, OS.get_locale()))

## Unix time when the season after `unix` starts (the next meteorological boundary).
static func next_change(unix: float) -> float:
	var d := Time.get_datetime_dict_from_unix_time(int(unix))
	var m := int(d.month)
	var y := int(d.year)
	var next_m := 3
	for b in [3, 6, 9, 12]:
		if b > m:
			next_m = b
			break
	if m == 12:
		y += 1
	return float(Time.get_unix_time_from_datetime_dict({"year": y, "month": next_m, "day": 1, "hour": 0, "minute": 0, "second": 0}))
