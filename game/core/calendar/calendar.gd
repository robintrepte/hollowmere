class_name Calendar
extends RefCounted
## Date math and deterministic weather. day_index 0 = Spring 1, Year 1.

const DAYS_PER_SEASON := 28
const SEASONS := ["spring", "summer", "fall", "winter"]
const WEEKDAYS := ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
const DAY_START := 360   # 6:00
const DAY_END := 1560    # 2:00 (next day)
const NIGHT_START := 1200 # 20:00
## Without sleeping, the game day rolls over at 6:00 the next morning.
const NIGHT_ROLLOVER := 1800

static func day_of_season(day_index: int) -> int:
	return (day_index % DAYS_PER_SEASON) + 1

static func season_index(day_index: int) -> int:
	return int(day_index / DAYS_PER_SEASON) % 4

static func season(day_index: int) -> String:
	return SEASONS[season_index(day_index)]

static func year(day_index: int) -> int:
	return int(day_index / (DAYS_PER_SEASON * 4)) + 1

static func weekday(day_index: int) -> int:
	return day_index % 7

static func week_number(day_index: int) -> int:
	return int(day_index / 7)

static func weekday_name(day_index: int) -> String:
	match weekday(day_index):
		0:
			return str(TranslationServer.translate("Mon"))
		1:
			return str(TranslationServer.translate("Tue"))
		2:
			return str(TranslationServer.translate("Wed"))
		3:
			return str(TranslationServer.translate("Thu"))
		4:
			return str(TranslationServer.translate("Fri"))
		5:
			return str(TranslationServer.translate("Sat"))
		6:
			return str(TranslationServer.translate("Sun"))
	return WEEKDAYS[weekday(day_index)]

## Seasons follow the real calendar; the day number is the farm's own 28-day cycle.
static func date_string(day_index: int, season_id: String = "") -> String:
	if season_id == "":
		season_id = current_season()
	return "%s, %s %d" % [weekday_name(day_index), Data.season_name(season_id), day_of_season(day_index)]

static func current_season() -> String:
	if GameState.started:
		return GameState.season()
	return Seasons.current(TimeService.now(), Settings.hemisphere)

static func time_string(minutes: int, twelve_hour: bool = true) -> String:
	var m := minutes % 1440
	var h := int(m / 60)
	var mm := m % 60
	if not twelve_hour:
		return "%02d:%02d" % [h, mm]
	var suffix := "am" if h < 12 else "pm"
	var h12 := h % 12
	if h12 == 0:
		h12 = 12
	return "%d:%02d%s" % [h12, mm, suffix]

## Data files write clock times as HHMM (e.g. 1730); converts to minutes since midnight.
static func hhmm(v: int) -> int:
	return int(v / 100) * 60 + v % 100

static func is_night(minutes: int) -> bool:
	return minutes >= NIGHT_START or minutes < DAY_START

## Festivals fall on a day of the farm's 28-day cycle within the real season.
static func festival_on(day_index: int, season_id: String = "") -> String:
	var s := season_id if season_id != "" else current_season()
	var d := day_of_season(day_index)
	var fests: Dictionary = Data.progression.get("festivals", {})
	for id in fests:
		if fests[id].season == s and int(fests[id].day) == d:
			return id
	return ""

static func roll_weather(world_seed: int, day_index: int, season_id: String = "") -> String:
	if season_id == "":
		season_id = season(day_index)
	if festival_on(day_index, season_id) != "" or day_of_season(day_index) == 1 or day_index < 2:
		return "sun"
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, day_index, "weather"])
	var r := rng.randf()
	match season_id:
		"spring":
			if r < 0.05: return "storm"
			if r < 0.25: return "rain"
		"summer":
			if r < 0.12: return "storm"
			if r < 0.20: return "rain"
		"fall":
			if r < 0.18: return "rain"
			if r < 0.26: return "fog"
		"winter":
			if r < 0.40: return "snow"
			if r < 0.50: return "fog"
	return "sun"

static func weather_waters(w: String) -> bool:
	return w == "rain" or w == "storm"

static func weather_name(w: String) -> String:
	match w:
		"sun":
			return TranslationServer.translate("Sunny")
		"rain":
			return TranslationServer.translate("Rain")
		"storm":
			return TranslationServer.translate("Storm")
		"snow":
			return TranslationServer.translate("Snow")
		"fog":
			return TranslationServer.translate("Fog")
	return TranslationServer.translate(w.capitalize())
