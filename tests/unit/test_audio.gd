extends GutTest
## Acceptance tests for the synthesised audio layer.
##
## Every one of these runs headless with the dummy driver and no listener, which
## is the whole reason the cues are code rather than files: a PackedByteArray of
## samples can be decoded and measured in CI, where an AudioStreamGenerator or an
## imported WAV cannot be inspected at all.
##
## Nothing here waits on a frame or a signal. The sounds are built by a function
## call and the pool is exercised by two hundred more, so the file costs about a
## second of wall clock rather than the two hundred seconds of real time that
## playing the cues would.

const SFX := preload("res://src/audio/procedural_sfx.gd")
const DIRECTOR := preload("res://src/audio/audio_director.gd")
const CUES := preload("res://src/audio/audio_cues.gd")

## Small enough that two hundred plays exhaust it many times over, so the steal
## path is what is being measured rather than the free-voice path.
const POOL_SIZE := 6

## Plausible cue lengths. The floor catches a cue that rounded down to nothing;
## the ceiling catches one that ran away, which at 22 kHz costs real memory.
const MIN_SECONDS := 0.05
const MAX_SECONDS := 6.0

## A cue must reach at least this far up the scale to count as audible at all.
## Every peak in ProceduralSfx is 0.32 of full scale or louder, so this leaves
## room to spare while still failing a synthesiser that emits silence.
const SILENCE_FLOOR := 3000
## Samples at or past here are hard against the rails.
const CLIP_LEVEL := 32700
## And no cue may have more than this fraction of them. Nothing should be clipping
## at all — every cue is normalised to a peak below the rails — but a fraction
## rather than a count keeps a deliberate change of peak level from failing this
## while still catching a synth that has genuinely squared off its transients.
const CLIP_FRACTION := 0.005

## How far apart the two ends of the looping bed may be, in sample counts —
## roughly a tenth of full scale. Simulating this synthesiser over four seeds put
## the gap between 96 and 773, so this is generous on purpose: the step from the
## last sample to the first is one draw from the same distribution as every other
## sample-to-sample step in a noise bed, and those average around 600 counts here.
const SEAM_MAX := 3000
## Window at each end of the loop measured for level, and how far its RMS may
## stray from the whole bed's.
##
## This is the assertion with the teeth. A single-sample check cannot see the
## looping bugs that actually click, because filtered noise already jumps by
## hundreds of counts every sample: a bed that faded in from silence, or whose
## swell does not fit a whole number of cycles into the loop, pumps at the join
## while its end samples match perfectly. Simulated, the ends of this bed sit
## within 1.2x of the whole; the same bed with a quarter-second fade on each end
## comes out four times down, and fails this.
const SEAM_WINDOW_SECONDS := 0.08
const SEAM_LEVEL_FACTOR := 2.0

## The envelope the shape test measures, and the tolerance its hand-computed
## expectations are held to. A one-second note with these stage lengths leaves a
## sustain plateau from 0.3 s to 0.7 s, so every stage has at least one point on
## it that no other stage of the same envelope would produce.
const ENV_DURATION := 1.0
const ENV_ATTACK := 0.1
const ENV_DECAY := 0.2
const ENV_SUSTAIN := 0.5
const ENV_RELEASE := 0.3
const ENV_EPSILON := 0.0005

## The mind's thirteen actions, restated rather than read out of
## CreatureActionStates. This file is meant to fail when the audio map has a hole,
## not when the creature module grows a verb.
const CREATURE_ACTIONS: Array[StringName] = [
	&"eat", &"attack", &"pick_up", &"throw", &"give_to_village", &"water_field",
	&"heal", &"play_with", &"sleep", &"follow_player", &"imitate", &"defecate",
	&"dance",
]
const MIRACLE_IDS: Array[StringName] = [&"food", &"wood", &"water", &"heal", &"lightning"]
## The three signals village.gd emits, spelled exactly as the signals are.
const VILLAGE_EVENTS: Array[StringName] = [&"born", &"died", &"building_raised"]

## Cues that draw on the generator. These must change when the seed changes; the
## rest are pure tones and must not.
const NOISE_CUES: Array[StringName] = [
	&"slap", &"eat", &"footstep", &"splash", &"thunder", &"ambient_wind",
]
const TONAL_CUES: Array[StringName] = [&"pet", &"miracle_cast", &"miracle_refused", &"birth"]

const SEED_A := 4711
const SEED_B := 4712


func test_every_cue_is_a_usable_stream() -> void:
	var names: Array[StringName] = SFX.cue_names()
	assert_gt(names.size(), 8, "the cue list should cover the game's events")
	gut.p("cue                seconds      bytes    frames")
	for cue: StringName in names:
		var stream: AudioStreamWAV = SFX.build(cue, _rng(SEED_A))
		assert_not_null(stream, "cue %s built nothing" % cue)
		if stream == null:
			continue
		var bytes: PackedByteArray = stream.data
		var frames: int = _frame_count(bytes)
		var seconds: float = float(frames) / float(stream.mix_rate)
		gut.p("%-18s %7.3f %10d %9d" % [cue, seconds, bytes.size(), frames])
		assert_eq(stream.format, AudioStreamWAV.FORMAT_16_BITS, "%s: wrong sample format" % cue)
		assert_eq(stream.mix_rate, SFX.MIX_RATE, "%s: wrong mix rate" % cue)
		assert_false(stream.stereo, "%s: cues are mono" % cue)
		assert_gt(bytes.size(), 0, "%s: empty sample data" % cue)
		assert_eq(bytes.size() % 2, 0, "%s: 16-bit data must be an even byte count" % cue)
		assert_between(seconds, MIN_SECONDS, MAX_SECONDS, "%s: implausible duration" % cue)


func test_sample_data_is_in_range_and_never_silent() -> void:
	# Headroom measured against the mix, not against the datatype. decode_s16
	# cannot return a value outside the 16-bit range whatever the input, so a bound
	# of -32768..32767 is true of any buffer at all and can never fail; this one
	# fails for a cue that normalised hotter than the mix table says anything
	# should. Thunder is the loudest entry in that table — if another cue is ever
	# authored above it, this is the line to update, and it will say so.
	var ceiling: int = roundi(SFX.PEAK_THUNDER * SFX.FULL_SCALE) + 1
	gut.p("cue                  peak   clipped  mean step")
	for cue: StringName in SFX.cue_names():
		var stream: AudioStreamWAV = SFX.build(cue, _rng(SEED_A))
		assert_not_null(stream, "cue %s built nothing" % cue)
		if stream == null:
			continue
		# Measured in one pass and asserted once. Asserting per sample would put a
		# quarter of a million assertions through GUT for no extra information.
		var stats: Dictionary = _measure(stream.data)
		var lowest: int = stats["lowest"]
		var highest: int = stats["highest"]
		var clipped: int = stats["clipped"]
		var frames: int = stats["frames"]
		var peak: int = maxi(absi(lowest), highest)
		gut.p("%-18s %7d %9d %10.1f" % [cue, peak, clipped, float(stats["mean_step"])])
		# Strict, and that is the whole point: a sample sitting exactly on a rail is
		# the signature of the failure worth catching. encode_s16 wraps 32768 to
		# -32768, so a transient that overshot the ceiling lands on the floor rather
		# than off the end of the range.
		assert_gt(lowest, SFX.SAMPLE_MIN, "%s: a sample wrapped through the 16-bit floor" % cue)
		assert_lt(highest, SFX.SAMPLE_MAX, "%s: a sample is pinned to the 16-bit ceiling" % cue)
		assert_lte(peak, ceiling, "%s: normalised louder than the mix table's loudest cue" % cue)
		assert_gt(peak, SILENCE_FLOOR, "%s: this cue is silence" % cue)
		assert_lt(
			float(clipped) / float(maxi(1, frames)), CLIP_FRACTION,
			"%s: samples are pinned against the rails, the synth is clipping" % cue
		)


func test_the_envelope_rises_holds_and_falls_to_zero() -> void:
	# Tested directly because no cue-level assertion can reach it. _encode
	# peak-normalises every buffer, so an envelope stuck at 1.0 would measure the
	# same peak as the real one and pass every other assertion in this file. Every
	# expectation below is worked out from the ADSR definition on paper rather than
	# read back off the implementation.
	var shape: Callable = func(t: float) -> float:
		return SFX.envelope(t, ENV_DURATION, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE)

	# Attack: a straight line from silence at t=0 to full level at t=attack.
	assert_almost_eq(shape.call(0.0), 0.0, ENV_EPSILON, "the attack must start from silence")
	assert_almost_eq(shape.call(0.05), 0.5, ENV_EPSILON, "half way up the attack is half level")
	assert_almost_eq(shape.call(ENV_ATTACK), 1.0, ENV_EPSILON, "the attack should reach full level")

	# Decay: full level down to the sustain level over `decay`, so half way from
	# 1.0 to 0.5 is 0.75.
	assert_almost_eq(shape.call(0.2), 0.75, ENV_EPSILON, "the decay should fall towards sustain")

	# Sustain: a plateau, not a slope. Three points across it, because a decay that
	# overran or a release that began early would still land on one of them.
	assert_almost_eq(
		shape.call(0.3), ENV_SUSTAIN, ENV_EPSILON, "the plateau starts where the decay ends"
	)
	assert_almost_eq(shape.call(0.5), ENV_SUSTAIN, ENV_EPSILON, "the plateau must hold, not drift")
	assert_almost_eq(shape.call(0.65), ENV_SUSTAIN, ENV_EPSILON, "...right up to the release")

	# Release: from where the note had got to, down to exactly zero at the end. A
	# tail that stops short of zero is a click, which is the whole reason the
	# release is computed rather than truncated.
	assert_almost_eq(
		shape.call(0.7), ENV_SUSTAIN, ENV_EPSILON, "the release starts at the sustain level"
	)
	assert_almost_eq(shape.call(0.85), 0.25, ENV_EPSILON, "half way down the release is half sustain")
	assert_almost_eq(shape.call(ENV_DURATION), 0.0, ENV_EPSILON, "the release must reach zero")
	assert_eq(shape.call(-0.01), 0.0, "before the note there is silence")
	assert_eq(shape.call(ENV_DURATION + 0.01), 0.0, "after the note there is silence")

	# `curve` raises the whole shape to a power, so the attack's midpoint of 0.5
	# becomes 0.25 while both ends stay where they were.
	assert_almost_eq(
		SFX.envelope(0.05, ENV_DURATION, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE, 2.0),
		0.25, ENV_EPSILON, "curve 2 should square the linear value"
	)
	assert_almost_eq(
		SFX.envelope(
			ENV_DURATION, ENV_DURATION, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE, 2.0
		),
		0.0, ENV_EPSILON, "a curved envelope must still land on zero"
	)

	# Zero-length stages, which is where a divide by a stage length turns into NaN
	# or INF. A slap is attack and release only: no decay, no sustain, and a
	# release as long as the note, so release_start is the end of the attack and at
	# 0.08 s the release has run (0.08 - 0.0015) / (0.16 - 0.0015) of its way down.
	var percussive: float = SFX.envelope(0.08, 0.16, 0.0015, 0.0, 0.0, 0.16)
	assert_true(is_finite(percussive), "an envelope with no decay or sustain must stay a number")
	assert_almost_eq(
		percussive, 0.5047, 0.001, "the release should fall linearly from the attack peak"
	)
	assert_almost_eq(
		SFX.envelope(0.5, 1.0, 0.0, 0.0, 0.7, 0.0), 0.7, ENV_EPSILON,
		"with no attack, decay or release the level is the sustain throughout"
	)
	assert_true(
		is_finite(SFX.envelope(1.0, 1.0, 0.0, 0.0, 0.7, 0.0)),
		"the last sample of a zero-length release must not divide by zero"
	)
	assert_eq(SFX.envelope(0.0, 0.0, 0.0, 0.0, 1.0, 0.0), 0.0, "a note of no length is silent")


func test_the_ambient_bed_loops_without_a_click() -> void:
	var wind: AudioStreamWAV = SFX.ambient_wind(_rng(SEED_A))
	assert_not_null(wind, "the wind bed failed to build")
	assert_eq(wind.loop_mode, AudioStreamWAV.LOOP_FORWARD, "the bed must be marked as looping")
	assert_eq(wind.loop_begin, 0, "the bed loops from its start")

	var bytes: PackedByteArray = wind.data
	var frames: int = _frame_count(bytes)
	assert_gt(wind.loop_end, 0, "loop_end must be set")
	assert_lte(wind.loop_end, frames, "loop_end must stay inside the sample data")

	var first: int = bytes.decode_s16(0)
	var last: int = bytes.decode_s16((frames - 1) * 2)
	var at_loop_end: int = bytes.decode_s16((wind.loop_end - 1) * 2)
	var stats: Dictionary = _measure(bytes)
	var mean_step: float = stats["mean_step"]

	var window: int = mini(roundi(SEAM_WINDOW_SECONDS * float(wind.mix_rate)), frames)
	var overall: float = _window_rms(bytes, 0, frames)
	var head: float = _window_rms(bytes, 0, window)
	var tail: float = _window_rms(bytes, frames - window, window)
	gut.p("wind loop: frames=%d first=%d last=%d loop_end-1=%d seam=%d mean step=%.1f" % [
		frames, first, last, at_loop_end, absi(first - last), mean_step
	])
	gut.p("wind level: whole rms=%.0f head rms=%.0f tail rms=%.0f (window %d frames)" % [
		overall, head, tail, window
	])

	assert_lt(absi(first - last), SEAM_MAX, "the two ends of the loop are far apart")
	assert_gt(overall, 0.0, "the bed has no level at all")
	assert_between(
		head, overall / SEAM_LEVEL_FACTOR, overall * SEAM_LEVEL_FACTOR,
		"the loop starts at a different level from the bed it loops: that pumps"
	)
	assert_between(
		tail, overall / SEAM_LEVEL_FACTOR, overall * SEAM_LEVEL_FACTOR,
		"the loop ends at a different level from the bed it loops: that pumps"
	)


func test_synthesis_is_deterministic_for_one_seed() -> void:
	for cue: StringName in SFX.cue_names():
		var first: PackedByteArray = SFX.build(cue, _rng(SEED_A)).data
		var second: PackedByteArray = SFX.build(cue, _rng(SEED_A)).data
		assert_eq(first.size(), second.size(), "%s: two builds differ in length" % cue)
		# assert_true rather than assert_eq: a failing assert_eq would print two
		# hundred thousand bytes of both buffers into the run log.
		assert_true(first == second, "%s: one seed must give byte-identical audio" % cue)


func test_noise_cues_come_from_the_seeded_generator() -> void:
	for cue: StringName in NOISE_CUES:
		var from_a: PackedByteArray = SFX.build(cue, _rng(SEED_A)).data
		var from_b: PackedByteArray = SFX.build(cue, _rng(SEED_B)).data
		assert_true(
			from_a != from_b,
			"%s: a different seed must change the noise, not return a fixed table" % cue
		)


func test_tonal_cues_do_not_depend_on_the_seed() -> void:
	# The other half of the contract, and the reason the cues that need no noise
	# take no generator: nothing about a chime should shift because something
	# else drew a random number first.
	for cue: StringName in TONAL_CUES:
		var from_a: PackedByteArray = SFX.build(cue, _rng(SEED_A)).data
		var from_b: PackedByteArray = SFX.build(cue, _rng(SEED_B)).data
		assert_true(from_a == from_b, "%s: a pure tone must not vary with the seed" % cue)


func test_every_cue_sounds_different_from_every_other() -> void:
	# Guards the copy-paste that returns the wrong buffer, which is invisible in
	# any test that only checks one cue at a time.
	var names: Array[StringName] = SFX.cue_names()
	var built: Dictionary = {}
	for cue: StringName in names:
		built[cue] = SFX.build(cue, _rng(SEED_A)).data
	for i in names.size():
		for j in range(i + 1, names.size()):
			var left: PackedByteArray = built[names[i]]
			var right: PackedByteArray = built[names[j]]
			assert_true(
				left != right,
				"%s and %s produced identical samples" % [names[i], names[j]]
			)


func test_the_voice_pool_never_grows_and_never_drops_a_sound() -> void:
	var director: AudioDirector = _make_director()
	var children_before: int = director.get_child_count()
	assert_eq(
		children_before, POOL_SIZE + 1,
		"the director should own exactly its pool plus the one ambient player"
	)

	var dropped: int = 0
	var foreign: int = 0
	# Plays per distinct voice. Counting them is what separates "the pool was
	# spread across and the oldest voice stolen" from "one voice was reused two
	# hundred times" — both of which return a non-null voice from the pool and so
	# look identical to every other assertion here.
	var plays_per_voice: Dictionary[int, int] = {}
	for i in 200:
		# Positions spread about so the voices are not all stacked on the origin,
		# which would take the non-positional branch instead.
		var voice: AudioStreamPlayer3D = director.play(
			&"footstep", Vector3(float(i % 7) + 1.0, 0.0, 2.0)
		)
		if voice == null:
			dropped += 1
			continue
		if voice.get_parent() != director:
			foreign += 1
		var id: int = voice.get_instance_id()
		plays_per_voice[id] = plays_per_voice.get(id, 0) + 1

	var busiest: int = 0
	for count: int in plays_per_voice.values():
		busiest = maxi(busiest, count)
	gut.p("200 plays through a pool of %d: dropped=%d, children %d -> %d" % [
		POOL_SIZE, dropped, children_before, director.get_child_count()
	])
	gut.p("voices touched: %d of %d, busiest took %d plays" % [
		plays_per_voice.size(), POOL_SIZE, busiest
	])
	assert_eq(dropped, 0, "no play may be dropped; an exhausted pool must steal a voice")
	assert_eq(foreign, 0, "every voice must come out of the pool")
	assert_eq(
		plays_per_voice.size(), POOL_SIZE,
		"the whole pool must be used before anything is stolen: a director that keeps"
			+ " taking one voice cuts each sound off with the next instead of stealing"
	)
	assert_eq(
		director.get_child_count(), children_before,
		"the pool grew: voices are being allocated per sound and leaked"
	)


func test_a_cue_with_no_position_is_played_flat() -> void:
	# The path a UI sound takes. Every other test in this file hands play() a
	# position, so without this the branch that makes a 3D voice behave like a flat
	# one never runs at all.
	var director: AudioDirector = _make_director()
	var flat: AudioStreamPlayer3D = director.play(&"miracle_refused")
	assert_not_null(flat, "a cue with no position should still get a voice")
	if flat == null:
		return
	assert_eq(
		flat.attenuation_model, AudioStreamPlayer3D.ATTENUATION_DISABLED,
		"a flat cue must not fall off with distance"
	)
	assert_almost_eq(flat.panning_strength, 0.0, 0.001, "a flat cue must sit centred")
	assert_almost_eq(flat.max_distance, 0.0, 0.001, "a flat cue has no distance cutoff")
	assert_eq(flat.position, Vector3.ZERO, "a flat cue sits on the listener")

	# The positional branch is the exact opposite, so a director that set the flat
	# properties unconditionally would pass above and fail here.
	var placed: AudioStreamPlayer3D = director.play(&"thunder", Vector3(5.0, 0.0, -3.0))
	assert_not_null(placed, "a positional cue should get a voice")
	if placed == null:
		return
	assert_eq(
		placed.attenuation_model, AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE,
		"a positional cue falls off with distance"
	)
	assert_almost_eq(placed.panning_strength, 1.0, 0.001, "a positional cue is panned")
	assert_almost_eq(
		placed.max_distance, director.max_audible_distance, 0.001,
		"a positional cue is cut off at the island's radius"
	)
	assert_eq(placed.position, Vector3(5.0, 0.0, -3.0), "the cue should sit where it happened")


func test_the_stolen_voice_is_the_quietest_then_the_oldest() -> void:
	var serials := PackedInt64Array([7, 3, 9, 1])
	var one_quiet := PackedFloat32Array([0.0, 0.0, -12.0, 0.0])
	assert_eq(
		DIRECTOR.stealable_voice(one_quiet, serials), 2,
		"the quietest voice should be taken first, whatever its age"
	)
	var all_equal := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	assert_eq(
		DIRECTOR.stealable_voice(all_equal, serials), 3,
		"with nothing to choose on volume, the oldest voice should go"
	)
	# Differences under the tie window are inaudible and must not outvote age.
	var nearly_equal := PackedFloat32Array([0.0, -0.2, 0.0, 0.0])
	assert_eq(
		DIRECTOR.stealable_voice(nearly_equal, serials), 3,
		"a fifth of a decibel is not a reason to steal a newer voice"
	)


func test_bus_setup_is_idempotent() -> void:
	var director: AudioDirector = _make_director()
	var count_before: int = AudioServer.bus_count
	director.ensure_buses()
	director.ensure_buses()
	assert_eq(
		AudioServer.bus_count, count_before,
		"re-entering the scene must not stack duplicate buses"
	)

	var sfx_buses: int = 0
	var ambient_buses: int = 0
	for i in AudioServer.bus_count:
		if AudioServer.get_bus_name(i) == "SFX":
			sfx_buses += 1
		elif AudioServer.get_bus_name(i) == "Ambient":
			ambient_buses += 1
	assert_eq(sfx_buses, 1, "there should be exactly one SFX bus")
	assert_eq(ambient_buses, 1, "there should be exactly one Ambient bus")

	var sfx_index: int = AudioServer.get_bus_index(&"SFX")
	assert_gte(sfx_index, 0, "the SFX bus should exist")
	assert_eq(AudioServer.get_bus_send(sfx_index), &"Master", "SFX should send to Master")
	var ambient_index: int = AudioServer.get_bus_index(&"Ambient")
	assert_gte(ambient_index, 0, "the Ambient bus should exist")
	assert_eq(AudioServer.get_bus_send(ambient_index), &"Master", "Ambient should send to Master")


func test_bus_volume_is_set_from_a_linear_value() -> void:
	var director: AudioDirector = _make_director()
	director.set_bus_volume(&"SFX", 0.5)
	var index: int = AudioServer.get_bus_index(&"SFX")
	assert_almost_eq(
		AudioServer.get_bus_volume_db(index), -6.0206, 0.01,
		"half loudness is about -6 dB; a linear value went straight through as dB"
	)
	assert_almost_eq(director.bus_volume(&"SFX"), 0.5, 0.001, "the level should read back linear")

	director.set_bus_volume(&"SFX", 1.0)
	assert_almost_eq(AudioServer.get_bus_volume_db(index), 0.0, 0.001, "full scale is 0 dB")

	director.set_bus_volume(&"SFX", 0.0)
	assert_true(
		is_finite(AudioServer.get_bus_volume_db(index)),
		"silence must not become an infinite dB value"
	)
	assert_lt(director.bus_volume(&"SFX"), 0.01, "zero linear should read back as good as zero")
	gut.p("SFX bus at linear 0.0 -> %.1f dB" % AudioServer.get_bus_volume_db(index))

	assert_eq(director.bus_volume(&"NoSuchBus"), 0.0, "an unknown bus should not fail")


func test_footsteps_do_not_repeat_the_same_sample() -> void:
	var director: AudioDirector = _make_director()
	var first: PackedByteArray = _played_data(director, &"footstep")
	var second: PackedByteArray = _played_data(director, &"footstep")
	assert_gt(first.size(), 0, "the first footstep played nothing")
	assert_gt(second.size(), 0, "the second footstep played nothing")
	assert_true(
		first != second,
		"consecutive footsteps must not be the identical sample, or a walk is a metronome"
	)


func test_streams_are_built_once_and_reused() -> void:
	var director: AudioDirector = _make_director()
	# The same object, not merely equal data: re-synthesising a cue per play would
	# cost milliseconds in the middle of a frame.
	assert_eq(
		director.stream_for(&"slap"), director.stream_for(&"slap"),
		"a single-take cue should come back from the cache"
	)
	assert_not_null(director.stream_for(&"thunder"), "thunder should be in the table")


func test_an_unmapped_cue_is_silent_rather_than_fatal() -> void:
	var director: AudioDirector = _make_director()
	assert_null(director.play(&"no_such_cue"), "an unknown cue must not play")
	assert_null(director.play(&""), "the silent cue must not play")
	assert_eq(
		director.get_child_count(), POOL_SIZE + 1,
		"a cue with no stream must not allocate anything"
	)


func test_the_ambient_bed_starts_and_stops() -> void:
	var director: AudioDirector = _make_director()
	var bed: AudioStreamPlayer = director.get_node_or_null(^"Ambient") as AudioStreamPlayer
	assert_not_null(bed, "the director should own one flat player for the bed")
	if bed == null:
		return
	assert_not_null(bed.stream, "the bed needs its stream before it can play")
	assert_eq(bed.bus, &"Ambient", "the bed belongs on the Ambient bus")

	assert_false(director.is_ambient_playing(), "the bed should not start on its own")
	director.start_ambient()
	assert_true(director.is_ambient_playing(), "start_ambient should start the wind")
	director.start_ambient()
	assert_true(director.is_ambient_playing(), "starting twice should leave it running")
	director.stop_ambient()
	assert_false(director.is_ambient_playing(), "stop_ambient should stop the wind")


func test_a_director_outside_the_tree_is_silent_rather_than_fatal() -> void:
	# The guard that keeps a headless run alive. A director whose _ready never
	# fired has no pool, no streams and no tree to position anything in.
	var lone: AudioDirector = DIRECTOR.new()
	autofree(lone)
	assert_null(lone.play(&"slap"), "an unparented director must refuse quietly")
	assert_null(lone.play(&"thunder", Vector3(4.0, 0.0, 0.0)), "including positional cues")
	assert_false(lone.is_ambient_playing(), "there is no bed to be playing")
	lone.start_ambient()
	lone.stop_ambient()
	assert_false(lone.is_ambient_playing(), "starting a bed that does not exist is a no-op")
	pass_test("an unparented director survived play, start_ambient and stop_ambient")


func test_every_creature_action_maps_to_a_cue_that_exists() -> void:
	var known: Array[StringName] = SFX.cue_names()
	var silent: Array[StringName] = []
	for action: StringName in CREATURE_ACTIONS:
		assert_true(
			CUES.FOR_CREATURE_ACTION.has(action),
			"action %s has no entry in the cue map" % action
		)
		var cue: StringName = CUES.for_creature_action(action)
		if cue == CUES.NONE:
			silent.append(action)
			continue
		assert_true(known.has(cue), "action %s maps to unknown cue %s" % [action, cue])
	gut.p("deliberately silent actions: %s" % str(silent))
	assert_eq(
		CUES.for_creature_action(&"invent_writing"), CUES.NONE,
		"an unmapped action must fall back to silence, not to a wrong sound"
	)


func test_miracle_and_village_events_map_to_cues_that_exist() -> void:
	var known: Array[StringName] = SFX.cue_names()
	for miracle_id: StringName in MIRACLE_IDS:
		var cue: StringName = CUES.for_miracle(miracle_id)
		assert_true(known.has(cue), "miracle %s maps to unknown cue %s" % [miracle_id, cue])
	assert_eq(
		CUES.for_miracle(&"lightning"), SFX.CUE_THUNDER,
		"lightning is the one miracle that does not use the generic sweep"
	)
	assert_eq(
		CUES.for_miracle(&"unheard_of"), SFX.CUE_MIRACLE_CAST,
		"an unmapped miracle should still sound like a miracle"
	)
	assert_true(
		known.has(CUES.for_miracle_refusal()), "the refusal cue must be a real cue"
	)
	for event: StringName in VILLAGE_EVENTS:
		assert_true(
			known.has(CUES.for_village_event(event)),
			"village event %s maps to unknown cue" % event
		)
	assert_eq(CUES.for_village_event(&"tax_revolt"), CUES.NONE, "unknown events are silent")


## A director in the tree with a small pool, freed when the test ends.
func _make_director() -> AudioDirector:
	var director: AudioDirector = DIRECTOR.new()
	director.pool_size = POOL_SIZE
	add_child_autofree(director)
	return director


## Plays a cue and returns the samples that went out, copied straight away — the
## voice it went to may be stolen by the very next call.
func _played_data(director: AudioDirector, cue: StringName) -> PackedByteArray:
	var voice: AudioStreamPlayer3D = director.play(cue, Vector3(3.0, 0.0, 0.0))
	if voice == null:
		return PackedByteArray()
	var wav: AudioStreamWAV = voice.stream as AudioStreamWAV
	return PackedByteArray() if wav == null else wav.data


## Peak, clip count and average sample-to-sample step, in one pass over the data.
func _measure(bytes: PackedByteArray) -> Dictionary:
	var frames: int = _frame_count(bytes)
	var lowest: int = 0
	var highest: int = 0
	var clipped: int = 0
	var step_total: float = 0.0
	var previous: int = 0
	for f in frames:
		var sample: int = bytes.decode_s16(f * 2)
		lowest = mini(lowest, sample)
		highest = maxi(highest, sample)
		if absi(sample) >= CLIP_LEVEL:
			clipped += 1
		if f > 0:
			step_total += float(absi(sample - previous))
		previous = sample
	return {
		"frames": frames,
		"lowest": lowest,
		"highest": highest,
		"clipped": clipped,
		"mean_step": step_total / float(maxi(1, frames - 1)),
	}


## RMS of `count` frames starting at `from_frame`.
func _window_rms(bytes: PackedByteArray, from_frame: int, count: int) -> float:
	if count <= 0:
		return 0.0
	var total: float = 0.0
	for f in count:
		var sample: float = float(bytes.decode_s16((from_frame + f) * 2))
		total += sample * sample
	return sqrt(total / float(count))


## Frames in a 16-bit mono buffer. Written as a multiplication rather than a
## division by two so the run log stays free of GDScript's integer-division
## warning; the byte count of a 16-bit stream is always even.
func _frame_count(bytes: PackedByteArray) -> int:
	return roundi(float(bytes.size()) * 0.5)


func _rng(seed_value: int) -> RandomNumberGenerator:
	var generator := RandomNumberGenerator.new()
	generator.seed = seed_value
	return generator
