class_name AudioDirector
extends Node
## The one thing the rest of the game talks to about sound.
##
## Give it a cue name and, if the sound belongs somewhere in the world, a
## position:
##
##     audio.play(AudioCues.for_creature_action(&"eat"), creature.global_position)
##     audio.play(AudioCues.for_miracle_refusal())
##     audio.start_ambient()
##
## Nothing else in the project should touch AudioServer, own an
## AudioStreamPlayer, or know that the cues are synthesised — see
## procedural_sfx.gd for why they are.
##
## Deliberately a plain Node rather than a Node3D. Its voices are positioned in
## world coordinates, and an ancestor transform silently offsetting every sound in
## the game is a bug nobody would think to look for.
##
## Every entry point is guarded so that the director is harmless rather than fatal
## when audio is not really there. Headless test runs get the dummy driver and no
## listener, and a director whose _ready never ran must still answer play() with a
## polite null instead of taking a test down with it.

## Bus 0 is always Master and always exists; the other two are created at runtime.
const BUS_MASTER := &"Master"
const BUS_SFX := &"SFX"
const BUS_AMBIENT := &"Ambient"

const RNG_STREAM := &"audio"

## Volume differences smaller than this are not audible, so voices within it of
## each other count as equally loud and their age decides which one is stolen.
const VOLUME_TIE_DB := 0.5

## Floor below which a bus is treated as silent. linear_to_db(0.0) is -INF, and an
## infinite bus volume is not a number the mixer should ever be handed.
const SILENT_LINEAR := 0.0005
const SILENT_DB := -80.0

@export_group("Voices")
## Hard cap on simultaneous sounds. Sixteen is more than a god game with one
## creature and one village ever needs at once, and the cap is what makes the
## worst case measurable rather than a function of how fast the player clicks.
@export var pool_size: int = 16
## Interchangeable takes built for the footstep. Four is enough that a walk cycle
## never repeats a sample twice running; the cost is four extra tenths of a second
## of audio.
@export var footstep_variants: int = 4

@export_group("Mix")
## Starting bus levels, LINEAR 0..1, as a settings slider would give them.
@export_range(0.0, 1.0, 0.01) var sfx_volume: float = 0.85
@export_range(0.0, 1.0, 0.01) var ambient_volume: float = 0.4

@export_group("Space")
## Beyond this a positional cue is not mixed at all. Roughly the island's radius:
## far enough that nothing audible is cut off, near enough that the far side of
## the map is not competing for voices.
@export var max_audible_distance: float = 70.0
## Distance over which a positional cue falls to roughly half. Higher carries
## further.
@export var voice_unit_size: float = 14.0

var _voices: Array[AudioStreamPlayer3D] = []
## Play order per voice, parallel to _voices. A monotonic counter rather than
## Time.get_ticks_msec: two hundred cues started inside one frame all share the
## same millisecond, and "oldest" then means nothing.
var _voice_serial := PackedInt64Array()
var _serial: int = 0
## Cue name -> Array[AudioStreamWAV] of interchangeable takes.
var _streams: Dictionary[StringName, Array] = {}
var _ambient: AudioStreamPlayer = null
## False when there is no audio system worth talking to. Everything no-ops.
var _available: bool = false


func _ready() -> void:
	# Bus 0 always exists when the server is up, so this is really "is there an
	# AudioServer at all", which is the one thing worth checking before building
	# seventeen nodes and ten seconds of synthesised samples.
	_available = AudioServer.bus_count > 0
	if not _available:
		push_warning("[audio] no audio buses; the director will stay silent")
		return
	ensure_buses()
	_build_streams()
	_build_pool()
	set_bus_volume(BUS_SFX, sfx_volume)
	set_bus_volume(BUS_AMBIENT, ambient_volume)


## Creates the SFX and Ambient buses, and does nothing at all if they are already
## there.
##
## Built at runtime rather than saved into project.godot because the audio layer
## owns its own mix and a bus list in the project file is a merge conflict waiting
## to happen. The existence check is the important half: without it, re-entering
## the game scene adds a second SFX bus, the first one keeps mixing, and the mix
## gets quietly louder every time the player restarts.
func ensure_buses() -> void:
	_ensure_bus(BUS_SFX)
	_ensure_bus(BUS_AMBIENT)


## Plays a cue. With a position it is mixed into the world; without one it is
## flat, for the sounds that come from the player rather than from anywhere.
##
## Vector3.ZERO is the sentinel for "not positional". The island's origin is its
## centre, under the sea in practice and never somewhere a cue is emitted from, so
## nothing real is lost — but a caller that genuinely means the origin should pass
## a position a millimetre off it.
##
## Returns the voice the cue went to, for tests and for a caller that wants to
## stop it early, or null when nothing was played.
func play(cue: StringName, at: Vector3 = Vector3.ZERO) -> AudioStreamPlayer3D:
	if not _available or _voices.is_empty() or not is_inside_tree():
		return null
	var stream: AudioStreamWAV = stream_for(cue)
	if stream == null:
		return null

	var index: int = _claim_voice()
	var voice: AudioStreamPlayer3D = _voices[index]
	_serial += 1
	_voice_serial[index] = _serial
	# Stop before re-assigning. A stolen voice is still mixing, and swapping the
	# stream out from under a live playback is how the tail of the old sound ends
	# up pitched into the new one.
	voice.stop()
	voice.stream = stream
	if at.is_zero_approx():
		# Attenuation off and panning centred is what makes a 3D player behave
		# like a flat one. Cheaper than keeping a second pool of
		# AudioStreamPlayers for the handful of cues — a refusal, a menu blip —
		# that have no place in the world.
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		voice.panning_strength = 0.0
		voice.max_distance = 0.0
		voice.position = Vector3.ZERO
	else:
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		voice.panning_strength = 1.0
		voice.max_distance = max_audible_distance
		voice.global_position = at
	voice.play()
	return voice


## Starts the looping wind bed if it is not already running.
func start_ambient() -> void:
	if not _available or _ambient == null or not is_inside_tree():
		return
	if _ambient.playing:
		return
	_ambient.play()


func stop_ambient() -> void:
	if _ambient == null:
		return
	_ambient.stop()


func is_ambient_playing() -> bool:
	return _ambient != null and _ambient.playing


## Sets a bus's level from a LINEAR 0..1 value.
##
## Linear because that is what a settings slider has, decibels because that is
## what the engine wants, and the conversion in one place because a caller that
## forgets it hands the mixer a volume of 0.5 dB and wonders why the slider does
## nothing.
func set_bus_volume(bus: StringName, linear: float) -> void:
	var index: int = AudioServer.get_bus_index(bus)
	if index < 0:
		return
	AudioServer.set_bus_volume_db(index, _to_db(clampf(linear, 0.0, 1.0)))


## A bus's level back as a linear 0..1, so a slider can initialise itself from
## the mix rather than from a duplicate default.
func bus_volume(bus: StringName) -> float:
	var index: int = AudioServer.get_bus_index(bus)
	if index < 0:
		return 0.0
	return clampf(db_to_linear(AudioServer.get_bus_volume_db(index)), 0.0, 1.0)


## The stream a cue will play next, or null for a cue that has none.
##
## Not a plain lookup, because cues with several interchangeable takes rotate
## through them. The rotation rides on the global play counter rather than a
## per-cue one: a second counter would have to be kept in step for no audible
## benefit.
func stream_for(cue: StringName) -> AudioStreamWAV:
	var takes: Array = _streams.get(cue, [])
	if takes.is_empty():
		return null
	return takes[_serial % takes.size()] as AudioStreamWAV


## Which busy voice a new sound should take over: the quietest, and the oldest of
## those where several are equally quiet.
##
## Static and pure because this is the only interesting decision the pool makes
## and it has to be provable in a headless run, where the dummy driver never
## actually finishes a playback and so a live pool tells you nothing.
##
## Today every voice sits at 0 dB — relative loudness is baked into the samples,
## see ProceduralSfx's peak table — so the volume key is dormant and the policy
## reduces to oldest-first. It is read from the live voices anyway so that a
## future per-cue trim participates without this having to be rewritten.
static func stealable_voice(volumes_db: PackedFloat32Array, serials: PackedInt64Array) -> int:
	var best: int = 0
	for i in range(1, mini(volumes_db.size(), serials.size())):
		if volumes_db[i] < volumes_db[best] - VOLUME_TIE_DB:
			best = i
		elif volumes_db[i] < volumes_db[best] + VOLUME_TIE_DB and serials[i] < serials[best]:
			best = i
	return best


## A free voice, or the one worth sacrificing when every voice is busy.
##
## Stealing rather than dropping the newest sound, because the newest sound is the
## one the player just caused: a slap that makes no noise reads as a broken game,
## while a rumble losing the last tenth of a second of its tail underneath it is
## not something anyone can hear.
func _claim_voice() -> int:
	for i in _voices.size():
		if not _voices[i].playing:
			return i
	var volumes := PackedFloat32Array()
	volumes.resize(_voices.size())
	for i in _voices.size():
		volumes[i] = _voices[i].volume_db
	return stealable_voice(volumes, _voice_serial)


func _ensure_bus(bus_name: StringName) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	# add_bus() with no argument appends, so the new bus is the last one. Reading
	# the index back afterwards rather than passing one avoids depending on how
	# add_bus interprets a position argument.
	AudioServer.add_bus()
	var index: int = AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, String(bus_name))
	AudioServer.set_bus_send(index, BUS_MASTER)


## Synthesises every cue up front.
##
## All of it at load, none of it during play. The wind bed alone is four seconds
## of filtered noise; synthesising that the first time the player walks into a
## breeze would be a visible hitch. The whole table is about ten seconds of audio
## — a little over four hundred kilobytes at 22 kHz mono — and costs a fraction of
## a second to build.
func _build_streams() -> void:
	var rng: RandomNumberGenerator = _generator()
	for cue: StringName in ProceduralSfx.cue_names():
		var takes: Array[AudioStreamWAV] = ProceduralSfx.variants(cue, rng, footstep_variants)
		if not takes.is_empty():
			_streams[cue] = takes


func _build_pool() -> void:
	for i in maxi(1, pool_size):
		var voice := AudioStreamPlayer3D.new()
		voice.name = "Voice%02d" % i
		voice.bus = BUS_SFX
		voice.unit_size = voice_unit_size
		voice.max_distance = max_audible_distance
		add_child(voice)
		_voices.append(voice)
	_voice_serial.resize(_voices.size())

	# One flat player for the bed. A looping AudioStreamWAV on a positional voice
	# would occupy a pooled voice for the rest of the session, and wind has no
	# location anyway.
	_ambient = AudioStreamPlayer.new()
	_ambient.name = "Ambient"
	_ambient.bus = BUS_AMBIENT
	_ambient.stream = stream_for(ProceduralSfx.CUE_AMBIENT_WIND)
	add_child(_ambient)


## The generator every cue is synthesised from.
##
## Seeded from the Rng service's derived seed rather than by drawing from its
## `audio` stream, so the cue table is byte-identical whenever it is built —
## rebuilding it after a scene reload must not change what the wind sounds like.
##
## The autoload is fetched by path and never by its global identifier: a script
## that names `Rng` directly fails to compile wherever the autoload is not
## registered, which includes every headless test run.
func _generator() -> RandomNumberGenerator:
	var generator := RandomNumberGenerator.new()
	generator.seed = _seed()
	return generator


func _seed() -> int:
	if is_inside_tree():
		var rng_service: Node = get_node_or_null(^"/root/Rng")
		if rng_service != null:
			return rng_service.derive_seed(RNG_STREAM)
	# Tests and tool scripts run without the autoload; the cue table still has to
	# come out the same every time, so this falls back to a fixed seed rather than
	# to randomize().
	return hash("numen:audio")


static func _to_db(linear: float) -> float:
	return SILENT_DB if linear <= SILENT_LINEAR else linear_to_db(linear)
