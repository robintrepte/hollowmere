extends Node
## Music with crossfades and SFX. Uses files in res://assets/audio when present,
## otherwise falls back to small synthesized sounds so the game is never silent.

const SFX_DIR := "res://assets/audio/sfx/"
const MUSIC_DIR := "res://assets/audio/music/"
const POOL := 10
const MIX_RATE := 22050

## name -> [[freq_start, freq_end, duration, wave, volume], ...] played in sequence
const SYNTH := {
	"ui": [[880, 990, 0.04, "square", 0.25]],
	"ui_back": [[660, 520, 0.05, "square", 0.25]],
	"hoe": [[180, 90, 0.08, "noise", 0.5]],
	"water": [[1200, 600, 0.12, "noise", 0.25]],
	"refill": [[300, 900, 0.18, "sine", 0.3]],
	"plant": [[500, 700, 0.06, "triangle", 0.4]],
	"harvest": [[600, 900, 0.06, "square", 0.3], [900, 1300, 0.08, "square", 0.3]],
	"rock": [[220, 120, 0.09, "noise", 0.6]],
	"chop": [[300, 160, 0.08, "noise", 0.55]],
	"scythe": [[2000, 900, 0.07, "noise", 0.25]],
	"pickup": [[700, 1100, 0.05, "triangle", 0.35]],
	"place": [[300, 250, 0.07, "triangle", 0.45]],
	"coin": [[988, 988, 0.05, "square", 0.3], [1319, 1319, 0.12, "square", 0.3]],
	"ship": [[400, 300, 0.08, "triangle", 0.4], [988, 1319, 0.1, "square", 0.25]],
	"machine": [[200, 260, 0.15, "square", 0.25]],
	"eat": [[400, 300, 0.05, "noise", 0.3], [400, 300, 0.05, "noise", 0.3]],
	"step": [[120, 90, 0.03, "noise", 0.12]],
	"hit": [[300, 80, 0.12, "noise", 0.6]],
	"super_hit": [[500, 60, 0.18, "noise", 0.7]],
	"miss": [[500, 400, 0.1, "sine", 0.3]],
	"faint": [[600, 100, 0.5, "triangle", 0.4]],
	"levelup": [[523, 523, 0.08, "square", 0.3], [659, 659, 0.08, "square", 0.3], [784, 784, 0.08, "square", 0.3], [1047, 1047, 0.2, "square", 0.3]],
	"befriend": [[784, 784, 0.1, "triangle", 0.4], [988, 988, 0.1, "triangle", 0.4], [1175, 1175, 0.3, "triangle", 0.4]],
	"charm_shake": [[300, 340, 0.08, "triangle", 0.4]],
	"encounter": [[200, 800, 0.25, "square", 0.3], [800, 400, 0.15, "square", 0.3]],
	"door": [[200, 150, 0.1, "triangle", 0.4]],
	"dialog": [[600, 600, 0.02, "square", 0.12]],
	"error": [[200, 150, 0.15, "square", 0.3]],
	"heart": [[880, 1175, 0.12, "sine", 0.35], [1175, 1568, 0.18, "sine", 0.35]],
	"hatch": [[400, 1200, 0.3, "triangle", 0.35], [1200, 1600, 0.2, "sine", 0.35]],
	"sparkle": [[1568, 2093, 0.08, "sine", 0.25], [2093, 2637, 0.12, "sine", 0.25]],
	"blip": [[740, 740, 0.015, "square", 0.08]],
	"tick": [[1200, 1200, 0.02, "square", 0.15]],
	"open": [[400, 600, 0.06, "triangle", 0.3]],
	"close": [[600, 400, 0.06, "triangle", 0.3]],
	"chest": [[220, 330, 0.08, "triangle", 0.4], [330, 440, 0.06, "triangle", 0.3]],
	"swing": [[900, 300, 0.06, "noise", 0.18]],
	"gift": [[659, 784, 0.08, "triangle", 0.35], [988, 1175, 0.12, "triangle", 0.35]],
	"heal": [[523, 659, 0.1, "sine", 0.3], [784, 1047, 0.2, "sine", 0.3]],
	"trash": [[300, 100, 0.12, "noise", 0.4]],
	"thunder": [[90, 40, 0.8, "noise", 0.7]],
	"sleep": [[523, 392, 0.25, "sine", 0.3], [392, 262, 0.4, "sine", 0.3]],
	"farm_level": [[523, 659, 0.1, "square", 0.3], [784, 1047, 0.1, "square", 0.3], [1047, 1568, 0.3, "triangle", 0.35]],
}

var _players: Array = []
var _next := 0
var _cache: Dictionary = {}
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_name := ""
var _last_step := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_players.append(p)
	_music_a = AudioStreamPlayer.new()
	_music_b = AudioStreamPlayer.new()
	for m in [_music_a, _music_b]:
		m.bus = "Music"
		add_child(m)

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
	for part in parts:
		var f0: float = float(part[0])
		var f1: float = float(part[1])
		var dur: float = float(part[2])
		var wave: String = part[3]
		var vol: float = float(part[4])
		var n := int(dur * MIX_RATE)
		for i in n:
			var t := float(i) / float(n)
			var f := lerpf(f0, f1, t)
			phase = fmod(phase + f / MIX_RATE, 1.0)
			var v := 0.0
			match wave:
				"square": v = 1.0 if phase < 0.5 else -1.0
				"triangle": v = 4.0 * absf(phase - 0.5) - 1.0
				"sine": v = sin(phase * TAU)
				"noise":
					noise_t += f / MIX_RATE
					if noise_t >= 1.0:
						noise_t = 0.0
						noise_v = randf_range(-1.0, 1.0)
					v = noise_v
			var env := minf(1.0, t * 20.0) * (1.0 - t)
			var sample := int(clampf(v * vol * env, -1.0, 1.0) * 32767.0)
			data.append(sample & 0xff)
			data.append((sample >> 8) & 0xff)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = MIX_RATE
	w.stereo = false
	w.data = data
	return w

func music(name: String, fade: float = 1.2) -> void:
	if name == _music_name:
		return
	_music_name = name
	var stream: AudioStream = null
	for ext in [".ogg", ".mp3", ".wav"]:
		if ResourceLoader.exists(MUSIC_DIR + name + ext):
			stream = load(MUSIC_DIR + name + ext)
			break
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
