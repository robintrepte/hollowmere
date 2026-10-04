extends Node
## Music with crossfades and SFX. Uses files in res://assets/audio when present,
## otherwise soft synthesized fallbacks so the game is never silent.

const SFX_DIR := "res://assets/audio/sfx/"
const MUSIC_DIR := "res://assets/audio/music/"
const POOL := 10
const MIX_RATE := 22050

## name -> [[freq_start, freq_end, duration, wave, volume], ...] played in sequence.
## Melodies sit roughly an octave lower than a chiptune beep and use soft sines.
const SYNTH := {
	"ui": [[392, 466, 0.07, "sine", 0.22]],
	"ui_back": [[349, 262, 0.09, "sine", 0.2]],
	"hoe": [[140, 70, 0.12, "noise", 0.4]],
	"water": [[380, 160, 0.18, "noise", 0.18]],
	"refill": [[220, 440, 0.24, "sine", 0.24]],
	"plant": [[294, 370, 0.1, "sine", 0.28]],
	"harvest": [[330, 440, 0.1, "sine", 0.24], [440, 554, 0.16, "sine", 0.22]],
	"rock": [[150, 70, 0.13, "noise", 0.46]],
	"chop": [[190, 90, 0.12, "noise", 0.42]],
	"dig": [[110, 60, 0.1, "noise", 0.34]],
	"boom": [[90, 30, 0.45, "noise", 0.6], [60, 40, 0.3, "sine", 0.3]],
	"clink": [[880, 660, 0.07, "sine", 0.2], [150, 70, 0.1, "noise", 0.3]],
	"crystal": [[1046, 1318, 0.12, "sine", 0.16], [1318, 1046, 0.2, "sine", 0.12]],
	"scythe": [[420, 180, 0.12, "noise", 0.18]],
	"pickup": [[349, 440, 0.09, "sine", 0.24]],
	"place": [[220, 174, 0.11, "sine", 0.3]],
	"coin": [[523, 523, 0.08, "sine", 0.22], [659, 659, 0.18, "sine", 0.2]],
	"ship": [[262, 196, 0.12, "sine", 0.28], [392, 494, 0.18, "sine", 0.2]],
	"machine": [[130, 165, 0.24, "sine", 0.18]],
	"eat": [[220, 140, 0.08, "noise", 0.22], [200, 120, 0.09, "noise", 0.2]],
	"step": [[80, 55, 0.05, "noise", 0.09]],
	"hit": [[200, 55, 0.16, "noise", 0.46]],
	"super_hit": [[240, 45, 0.24, "noise", 0.5]],
	"miss": [[311, 220, 0.16, "sine", 0.2]],
	"faint": [[349, 87, 0.6, "sine", 0.28]],
	"levelup": [[262, 262, 0.11, "sine", 0.24], [330, 330, 0.11, "sine", 0.24], [392, 392, 0.11, "sine", 0.24], [523, 523, 0.28, "sine", 0.22]],
	"befriend": [[392, 392, 0.14, "sine", 0.28], [494, 494, 0.14, "sine", 0.28], [587, 587, 0.36, "sine", 0.26]],
	"charm_shake": [[220, 247, 0.12, "sine", 0.26]],
	"encounter": [[146, 330, 0.32, "sine", 0.22], [330, 196, 0.24, "sine", 0.2]],
	"door": [[165, 123, 0.14, "sine", 0.3]],
	"dialog": [[311, 311, 0.04, "sine", 0.07]],
	"error": [[165, 123, 0.2, "sine", 0.22]],
	"heart": [[440, 523, 0.16, "sine", 0.26], [523, 659, 0.24, "sine", 0.24]],
	"hatch": [[262, 440, 0.34, "sine", 0.26], [440, 587, 0.28, "sine", 0.24]],
	"sparkle": [[587, 740, 0.12, "sine", 0.16], [740, 880, 0.18, "sine", 0.14]],
	"blip": [[349, 349, 0.035, "sine", 0.06]],
	"tick": [[294, 294, 0.04, "sine", 0.08]],
	"open": [[262, 349, 0.09, "sine", 0.22]],
	"close": [[349, 247, 0.09, "sine", 0.22]],
	"chest": [[196, 262, 0.12, "sine", 0.28], [262, 330, 0.14, "sine", 0.22]],
	"swing": [[280, 110, 0.1, "noise", 0.14]],
	"gift": [[392, 494, 0.12, "sine", 0.24], [523, 622, 0.18, "sine", 0.22]],
	"heal": [[330, 392, 0.14, "sine", 0.24], [440, 523, 0.26, "sine", 0.22]],
	"trash": [[160, 60, 0.16, "noise", 0.3]],
	"thunder": [[60, 28, 0.95, "noise", 0.55]],
	"sleep": [[349, 262, 0.32, "sine", 0.24], [262, 175, 0.5, "sine", 0.22]],
	"farm_level": [[262, 330, 0.14, "sine", 0.24], [392, 494, 0.14, "sine", 0.24], [523, 659, 0.36, "sine", 0.22]],
	"cast": [[520, 180, 0.22, "noise", 0.14]],
	"splash": [[300, 120, 0.2, "noise", 0.22]],
	"bite": [[660, 880, 0.06, "sine", 0.26], [660, 880, 0.06, "sine", 0.26]],
	"reel": [[440, 470, 0.05, "sine", 0.08]],
	"catch": [[392, 494, 0.1, "sine", 0.24], [587, 740, 0.12, "sine", 0.24], [784, 784, 0.26, "sine", 0.22]],
	"equip": [[262, 392, 0.08, "sine", 0.22], [392, 392, 0.06, "noise", 0.08]],
	"chips": [[2400, 1800, 0.03, "noise", 0.16], [2200, 1600, 0.04, "noise", 0.13], [2600, 2000, 0.03, "noise", 0.1]],
	"deal": [[1800, 600, 0.06, "noise", 0.16]],
	"wheel": [[180, 220, 0.5, "noise", 0.08], [220, 160, 0.6, "noise", 0.06]],
	"ball": [[1400, 1400, 0.03, "noise", 0.14], [1200, 1200, 0.04, "noise", 0.1], [1000, 1000, 0.05, "noise", 0.08]],
	"reels": [[330, 330, 0.05, "sine", 0.1], [294, 294, 0.05, "sine", 0.1], [330, 330, 0.05, "sine", 0.1], [294, 294, 0.05, "sine", 0.1]],
	"reels_win": [[523, 523, 0.08, "sine", 0.22], [659, 659, 0.08, "sine", 0.22], [784, 784, 0.18, "sine", 0.2]],
	"jackpot": [[523, 523, 0.1, "sine", 0.24], [659, 659, 0.1, "sine", 0.24], [784, 784, 0.1, "sine", 0.24], [1046, 1046, 0.1, "sine", 0.24], [784, 784, 0.1, "sine", 0.22], [1046, 1046, 0.4, "sine", 0.24]],
	"race": [[392, 392, 0.18, "sine", 0.22], [392, 392, 0.18, "sine", 0.22], [784, 784, 0.4, "sine", 0.24]],
}

var _players: Array = []
var _next := 0
var _cache: Dictionary = {}
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_name := ""
var _beds: Dictionary = {}
var _bed_task := -1
var _bed_fade := 1.2
var _last_step := 0.0
var _away := false
var _page_cb = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_watch_page_visibility()
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		_use_stream(p)
		add_child(p)
		_players.append(p)
	_music_a = AudioStreamPlayer.new()
	_music_b = AudioStreamPlayer.new()
	for m in [_music_a, _music_b]:
		m.bus = "Music"
		_use_stream(m)
		add_child(m)

## Tabbing away, alt-tab, or backgrounding the app silences music. The stream keeps
## playing, so it continues from the same moment when the game is focused again.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_set_away(true)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_APPLICATION_RESUMED:
		_set_away(false)

func _set_away(away: bool) -> void:
	if _away == away:
		return
	_away = away
	apply_music_mute()

## Web exports default to Sample playback. That path disconnects Master from the
## speakers as soon as Music and SFX exist, so Chrome (and every other browser)
## stays silent. Stream uses Godot's mixer instead.
func _use_stream(player: AudioStreamPlayer) -> void:
	player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM

## Re-applies the Music bus mute from the volume slider, plus background mute.
func apply_music_mute() -> void:
	var idx := AudioServer.get_bus_index("Music")
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, _away or Settings.music_volume <= 0.001)

func _watch_page_visibility() -> void:
	if OS.get_name() != "Web":
		return
	_page_cb = JavaScriptBridge.create_callback(_on_page_visibility)
	JavaScriptBridge.get_interface("window").hollowmerePageHidden = _page_cb
	JavaScriptBridge.eval("""
		document.addEventListener('visibilitychange', function () {
			if (window.hollowmerePageHidden) window.hollowmerePageHidden(document.hidden ? 1 : 0);
		});
	""", true)
	if int(JavaScriptBridge.eval("document.hidden ? 1 : 0", true)) == 1:
		_set_away(true)

func _on_page_visibility(args: Array) -> void:
	if args.is_empty():
		return
	_set_away(int(args[0]) != 0)

func sfx(name: String, pitch_var: float = 0.06) -> void:
	if name == "":
		return
	if name == "step":
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_step < 0.28:
			return
		_last_step = now
	var stream := _get_sfx(name)
	if stream == null:
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % POOL
	p.stream = stream
	p.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	p.play()

func _get_sfx(name: String) -> AudioStream:
	if _cache.has(name):
		return _cache[name]
	var s: AudioStream = null
	for ext in [".ogg", ".wav", ".mp3"]:
		if ResourceLoader.exists(SFX_DIR + name + ext):
			s = load(SFX_DIR + name + ext)
			break
	if s == null and SYNTH.has(name):
		s = synth(SYNTH[name])
	_cache[name] = s
	return s

static func synth(parts: Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	var phase := 0.0
	var noise_v := 0.0
	var noise_t := 0.0
	var lp := 0.0
	for part in parts:
		var f0: float = float(part[0])
		var f1: float = float(part[1])
		var dur: float = float(part[2])
		var wave: String = part[3]
		var vol: float = float(part[4])
		var n := maxi(2, int(dur * MIX_RATE))
		for i in n:
			var t := float(i) / float(n - 1)
			var f := lerpf(f0, f1, t)
			phase = fmod(phase + f / MIX_RATE, 1.0)
			var v := 0.0
			var cutoff := 0.4
			match wave:
				"sine":
					v = sin(phase * TAU)
					cutoff = 0.45
				"triangle":
					v = sin(phase * TAU) * 0.86 + sin(phase * TAU * 2.0) * 0.14
					cutoff = 0.28
				"square":
					v = tanh(sin(phase * TAU) * 1.35)
					cutoff = 0.16
				"noise":
					noise_t += f / MIX_RATE
					if noise_t >= 1.0:
						noise_t = fmod(noise_t, 1.0)
						noise_v = randf_range(-1.0, 1.0)
					v = noise_v
					cutoff = 0.11
			# Tones bloom and fade. Impacts ease in quickly, then fall off, so nothing clicks.
			var env := 0.5 - 0.5 * cos(t * TAU)
			if wave == "noise":
				var attack := 0.12
				if t < attack:
					env = 0.5 - 0.5 * cos(PI * t / attack)
				else:
					var u := (t - attack) / (1.0 - attack)
					env = cos(u * PI * 0.5)
			lp += (v - lp) * cutoff
			var sample := int(clampf(lp * vol * env, -1.0, 1.0) * 32767.0)
			data.append(sample & 0xff)
			data.append((sample >> 8) & 0xff)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = MIX_RATE
	w.stereo = false
	w.data = data
	return w

## Slow beds. root is Hz, scale and color are semitone offsets, step is seconds between notes.
## pulse adds a soft once-a-second swell for battles. Real files in MUSIC_DIR still win.
const BEDS := {
	"title": {"root": 174.61, "scale": [0, 3, 5, 7, 10], "color": 3, "step": 2.2, "pulse": false},
	"farm": {"root": 196.00, "scale": [0, 2, 4, 7, 9], "color": 9, "step": 1.75, "pulse": false},
	"town": {"root": 164.81, "scale": [0, 2, 4, 7, 9], "color": 9, "step": 1.4, "pulse": false},
	"route": {"root": 146.83, "scale": [0, 2, 4, 7, 9], "color": 9, "step": 1.55, "pulse": false},
	"forest": {"root": 130.81, "scale": [0, 3, 5, 7, 10], "color": 3, "step": 2.0, "pulse": false},
	"beach": {"root": 185.00, "scale": [0, 2, 4, 7, 9], "color": 9, "step": 1.9, "pulse": false},
	"volcano": {"root": 110.00, "scale": [0, 3, 5, 7, 10], "color": 3, "step": 1.85, "pulse": false},
	"canyon": {"root": 116.54, "scale": [0, 3, 5, 7, 10], "color": 3, "step": 1.9, "pulse": false},
	"peak": {"root": 155.56, "scale": [0, 2, 4, 7, 9], "color": 9, "step": 1.6, "pulse": false},
	"marsh": {"root": 123.47, "scale": [0, 3, 5, 7, 10], "color": 3, "step": 2.3, "pulse": false},
	"snow": {"root": 138.59, "scale": [0, 2, 7, 9], "color": 9, "step": 2.4, "pulse": false},
	"glade": {"root": 103.83, "scale": [0, 3, 5, 7, 10], "color": 3, "step": 2.1, "pulse": false},
	"cave": {"root": 98.00, "scale": [0, 5, 7, 10], "color": 5, "step": 2.6, "pulse": false},
	"mining_town": {"root": 146.83, "scale": [0, 2, 3, 7, 9], "color": 7, "step": 1.5, "pulse": false},
	"deep": {"root": 82.41, "scale": [0, 3, 7, 8], "color": 3, "step": 3.0, "pulse": false},
	"battle": {"root": 130.81, "scale": [0, 3, 5, 7, 10], "color": 3, "step": 1.05, "pulse": true},
	"trainer": {"root": 116.54, "scale": [0, 3, 5, 7, 10], "color": 3, "step": 0.95, "pulse": true},
	"promenade": {"root": 174.61, "scale": [0, 2, 4, 7, 9, 11], "color": 11, "step": 1.3, "pulse": false},
	"casino": {"root": 155.56, "scale": [0, 2, 3, 5, 7, 10], "color": 10, "step": 0.85, "pulse": false, "murmur": 0.05},
	"vip": {"root": 138.59, "scale": [0, 2, 3, 7, 9, 10], "color": 9, "step": 1.6, "pulse": false},
}
const BED_SECONDS := 16.0
const BED_RATE := 11025

func music(name: String, fade: float = 1.2) -> void:
	if name == _music_name:
		return
	_music_name = name
	_bed_fade = fade
	if name == "":
		_crossfade(null, fade)
		return
	var stream := _music_file(name)
	if stream == null and _beds.has(name):
		stream = _beds[name]
	if stream != null:
		_crossfade(stream, fade)
		return
	# Keep whatever is playing and fade the new bed in once it's ready.
	_ensure_bed_job()

func _ensure_bed_job() -> void:
	if _bed_task != -1 or _music_name == "" or _beds.has(_music_name):
		return
	if _music_file(_music_name) != null:
		return
	if not OS.has_feature("threads"):
		_beds[_music_name] = _wav(_mix_bed(_music_name))
		_crossfade(_beds[_music_name], _bed_fade)
		return
	_bed_task = WorkerThreadPool.add_task(_mix_job.bind(_music_name))

func _mix_job(name: String) -> void:
	var data := _mix_bed(name)
	call_deferred("_finish_bed", name, data)

func _finish_bed(name: String, data: PackedByteArray) -> void:
	if _bed_task != -1:
		WorkerThreadPool.wait_for_task_completion(_bed_task)
		_bed_task = -1
	if not _beds.has(name):
		_beds[name] = _wav(data)
	if _music_name == name:
		_crossfade(_beds[name], _bed_fade)
	_ensure_bed_job()

func _music_file(name: String) -> AudioStream:
	if name == "":
		return null
	for ext in [".ogg", ".mp3", ".wav"]:
		if ResourceLoader.exists(MUSIC_DIR + name + ext):
			return load(MUSIC_DIR + name + ext)
	return null

func _crossfade(stream: AudioStream, fade: float) -> void:
	var old := _music_a
	var new := _music_b
	_music_a = new
	_music_b = old
	if old.playing:
		var tw := create_tween()
		tw.tween_property(old, "volume_db", -40.0, fade)
		tw.tween_callback(old.stop)
	if stream:
		if stream is AudioStreamOggVorbis:
			stream.loop = true
		elif stream is AudioStreamMP3:
			stream.loop = true
		new.stream = stream
		new.volume_db = -40.0
		new.play()
		create_tween().tween_property(new, "volume_db", 0.0, fade)

func stop_music() -> void:
	music("")

func _wav(data: PackedByteArray) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = BED_RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = data.size() / 2
	return w

## A looping pad: low root, a fifth that gives way to a softer color tone, and a few slow notes.
## Frequencies are locked to the loop so the seam has no click.
func _mix_bed(name: String) -> PackedByteArray:
	var spec: Dictionary = BEDS[name] if BEDS.has(name) else BEDS["farm"]
	var n := int(BED_SECONDS * float(BED_RATE))
	var mix := PackedFloat32Array()
	mix.resize(n)
	var root := _snap(float(spec["root"]))
	var fifth := _snap(root * pow(2.0, 7.0 / 12.0))
	var color := _snap(root * pow(2.0, float(spec["color"]) / 12.0))
	var pulse: bool = spec["pulse"]
	_lay(mix, _snap(root * 0.5), 0.12, 3 if pulse else 0)
	_lay(mix, root, 0.09, 0)
	_lay(mix, _snap(root + 0.375), 0.045, 0)
	_lay(mix, fifth, 0.05, 1)
	_lay(mix, color, 0.045, 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(name) & 0x7fffffff
	var scale: Array = spec["scale"]
	var step := float(spec["step"])
	var idx := 0
	var t := step * 0.45
	var guard := 0
	while guard < 28:
		guard += 1
		var room := BED_SECONDS - t - 0.08
		if room < 0.7:
			break
		var semi := int(scale[idx])
		var f := _band(root * pow(2.0, float(semi) / 12.0))
		var dur := rng.randf_range(0.55, minf(room, minf(step * 0.9, 1.5)))
		_note(mix, f, t, dur, 0.05)
		var echo_t := t + dur * 0.62
		var echo_dur := dur * 0.85
		if rng.randf() < 0.35 and echo_t + echo_dur < BED_SECONDS - 0.08:
			_note(mix, f, echo_t, echo_dur, 0.026)
		var jump := rng.randi_range(-2, 2)
		if jump == 0:
			jump = 1 if rng.randf() < 0.5 else -1
		idx = posmod(idx + jump, scale.size())
		t += step * rng.randf_range(0.9, 1.25)
	var murmur := float(spec.get("murmur", 0.0))
	if murmur > 0.0:
		_murmur(mix, murmur, rng)
	var peak := 0.001
	for i in n:
		peak = maxf(peak, absf(mix[i]))
	var gain := 0.4 / peak
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var sample := int(clampf(mix[i] * gain, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample)
	return data

## Crowd murmur: band-limited noise that swells in slow waves. The swell periods divide the loop length.
func _murmur(mix: PackedFloat32Array, vol: float, rng: RandomNumberGenerator) -> void:
	var lo := 0.0
	var lo2 := 0.0
	var n := mix.size()
	for i in n:
		var x := rng.randf_range(-1.0, 1.0)
		lo += (x - lo) * 0.12
		lo2 += (lo - lo2) * 0.12
		var ph := float(i) / float(n) * TAU
		var swell := 0.6 + 0.25 * sin(ph * 3.0) + 0.15 * sin(ph * 7.0 + 1.3)
		mix[i] += lo2 * vol * swell * 6.0

func _snap(f: float) -> float:
	return float(maxi(1, roundi(f * BED_SECONDS))) / BED_SECONDS

## Fold a melody note into G3–G4 so it stays warm.
func _band(f: float) -> float:
	while f < 196.0:
		f *= 2.0
	while f >= 392.0:
		f *= 0.5
	return f

## shape: 0 steady breath, 1 loud at the loop ends, 2 loud in the middle, 3 soft battle pulse.
func _lay(mix: PackedFloat32Array, freq: float, amp: float, shape: int) -> void:
	var n := mix.size()
	var nf := float(n)
	var inc := freq / float(BED_RATE)
	var phase := 0.0
	var harm := 0.15 if freq * 2.0 <= 420.0 else 0.0
	var norm := 1.0 + harm
	for i in n:
		var u := float(i) / nf
		var env := 1.0
		if shape == 0:
			env = 0.9 + 0.1 * sin(TAU * 2.0 * u)
		elif shape == 1:
			env = 0.5 + 0.5 * cos(TAU * u)
		elif shape == 2:
			env = 0.5 - 0.5 * cos(TAU * u)
		else:
			env = 0.7 + 0.3 * (0.5 - 0.5 * cos(TAU * BED_SECONDS * u))
		var s := sin(phase * TAU)
		if harm > 0.0:
			s += harm * sin(phase * 2.0 * TAU)
		mix[i] = mix[i] + (s / norm) * amp * env
		phase += inc
		if phase >= 1.0:
			phase -= 1.0

func _note(mix: PackedFloat32Array, freq: float, start: float, dur: float, amp: float) -> void:
	var rate := float(BED_RATE)
	var i0 := int(start * rate)
	var length := int(dur * rate)
	if i0 < 0 or length < 2 or i0 + length > mix.size():
		return
	var phase := 0.0
	var inc := freq / rate
	var last := float(length - 1)
	for k in length:
		var u := float(k) / last
		var env: float
		if u < 0.42:
			env = 0.5 - 0.5 * cos(PI * u / 0.42)
		else:
			env = cos((u - 0.42) / 0.58 * PI * 0.5)
		mix[i0 + k] = mix[i0 + k] + sin(phase * TAU) * amp * env
		phase += inc
		if phase >= 1.0:
			phase -= 1.0
