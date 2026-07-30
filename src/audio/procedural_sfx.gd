class_name ProceduralSfx
extends RefCounted
## Every sound in NUMEN, synthesised from maths into an AudioStreamWAV at runtime.
##
## There is no audio file anywhere in this repository and there is not meant to
## be one. That is a licensing decision before it is a technical one: a cue
## computed from a sine and a seeded noise generator has no author to credit, no
## licence to honour, nothing for tools/check_licenses.sh to police and no import
## step to go wrong. It is also the only shape of audio layer this project could
## actually test — AudioStreamGenerator needs a live mixing thread and a real
## driver, so it cannot be exercised headless, whereas a PackedByteArray of
## samples can be decoded and measured in CI.
##
## Every function here is static and pure. Cues that need noise take the
## RandomNumberGenerator to draw it from; cues that are pure tones take none,
## which is precisely why they are byte-identical run to run. Nothing here ever
## touches global randf().
##
## Everything is 16-bit signed mono little-endian, which is what
## AudioStreamWAV.FORMAT_16_BITS means: two bytes per frame, written with
## PackedByteArray.encode_s16.

## Sample rate every cue is built at. 22050 rather than 44100 because nothing
## here carries meaningful content above 11 kHz — chimes, thuds, rumbles and
## filtered noise — and it halves both the synthesis cost at load and the bytes
## the streams hold for the rest of the session.
const MIX_RATE := 22050

## Bounds of a FORMAT_16_BITS sample. Encoding clamps to these; see _encode.
const SAMPLE_MIN := -32768
const SAMPLE_MAX := 32767
const FULL_SCALE := 32767.0

const CUE_PET := &"pet"
const CUE_SLAP := &"slap"
const CUE_EAT := &"eat"
const CUE_FOOTSTEP := &"footstep"
const CUE_SPLASH := &"splash"
const CUE_MIRACLE_CAST := &"miracle_cast"
const CUE_MIRACLE_REFUSED := &"miracle_refused"
const CUE_BIRTH := &"birth"
const CUE_THUNDER := &"thunder"
const CUE_AMBIENT_WIND := &"ambient_wind"

## Every cue, in the order they are listed above.
const CUE_NAMES: Array[StringName] = [
	CUE_PET, CUE_SLAP, CUE_EAT, CUE_FOOTSTEP, CUE_SPLASH,
	CUE_MIRACLE_CAST, CUE_MIRACLE_REFUSED, CUE_BIRTH, CUE_THUNDER,
	CUE_AMBIENT_WIND,
]

# --- Mix -----------------------------------------------------------------------
# Peak level each cue is normalised to, as a fraction of full scale. This is the
# game's mix, in one place: how loud a slap is *relative to* a footstep is
# decided here and nowhere else.
#
# Normalising to a target peak rather than trusting the synthesis to land in
# range is deliberate. A buffer that happens to sum to 1.4 and is then clamped
# has its transients flattened into square waves, which is exactly what makes
# procedural audio sound like a broken radio. Nothing is authored above 0.95, so
# no cue ever touches the rails.
const PEAK_PET := 0.55
const PEAK_SLAP := 0.85
const PEAK_EAT := 0.50
const PEAK_FOOTSTEP := 0.40
const PEAK_SPLASH := 0.52
const PEAK_MIRACLE_CAST := 0.62
const PEAK_MIRACLE_REFUSED := 0.58
const PEAK_BIRTH := 0.52
const PEAK_THUNDER := 0.95
const PEAK_AMBIENT_WIND := 0.32

# --- Chimes (pet, birth) -------------------------------------------------------
# Envelope shape shared by every struck note, as fractions of the note's own
# length so one shape serves notes of any duration. Attack, decay and release
# together come to less than one, which is what leaves a sustain plateau in the
# middle; raise them past 1.0 and the note becomes attack and release only.
const CHIME_ATTACK_FRACTION := 0.04
const CHIME_DECAY_FRACTION := 0.22
const CHIME_SUSTAIN := 0.38
const CHIME_RELEASE_FRACTION := 0.55
const CHIME_CURVE := 1.5
## Two quiet partials above the fundamental. This is the whole difference between
## a chime and a hearing test: a bare sine reads as equipment, not as a bell.
const CHIME_HARMONIC_2 := 0.32
const CHIME_HARMONIC_3 := 0.11

const PET_SECONDS := 0.6
const PET_NOTE_SECONDS := 0.34
## C5 then G5. A rising fifth, which is about as unambiguously warm and
## approving as two notes get.
const PET_LOW_HZ := 523.25
const PET_HIGH_HZ := 783.99
const PET_SECOND_NOTE_AT := 0.22
const PET_HIGH_LEVEL := 0.85

const BIRTH_SECONDS := 0.5
const BIRTH_NOTE_SECONDS := 0.2
## E5, G#5, B5, E6 — a major triad closed off with the octave. The minor third
## (G5, 783.99) would read as a warning rather than as good news, and the octave
## on the end is what makes the phrase sound finished instead of interrupted.
const BIRTH_NOTES: Array[float] = [659.25, 830.61, 987.77, 1318.51]
const BIRTH_NOTE_GAP := 0.09
const BIRTH_NOTE_LEVEL := 0.8

# --- Slap ----------------------------------------------------------------------
const SLAP_SECONDS := 0.16
## Split point between the crack and the hand. The sting is everything above
## this; a little of the low half is mixed back in for the weight of the palm.
const SLAP_SPLIT_HZ := 900.0
const SLAP_LOW_MIX := 0.55
const SLAP_ATTACK := 0.0015
## Higher curve, faster collapse. Three-ish is where the tail stops sounding
## like a hiss and starts sounding like a hit.
const SLAP_CURVE := 3.2

# --- Eat -----------------------------------------------------------------------
const EAT_SECONDS := 0.34
## Band edges. Kept low on purpose: a crunch is a chest-height sound, and taking
## the top off is what stops it reading as static.
const EAT_BAND_LOW_HZ := 130.0
const EAT_BAND_HIGH_HZ := 900.0
## Chewing is not one burst, it is several. The amplitude is multiplied by a
## sample-and-hold gate re-rolled this often; without it a band-limited noise
## burst is a featureless "shhh".
const EAT_GRAIN_SECONDS := 0.035
const EAT_GRAIN_MIN := 0.25
const EAT_ATTACK := 0.012
const EAT_DECAY := 0.06
const EAT_SUSTAIN := 0.7
const EAT_RELEASE := 0.2
const EAT_CURVE := 1.4

# --- Footstep ------------------------------------------------------------------
const FOOTSTEP_SECONDS := 0.13
## A thud is a pitch that falls as fast as its amplitude. Held level, the same
## sine reads as a beep.
const FOOTSTEP_HZ := 105.0
const FOOTSTEP_HZ_FALL := 0.55
const FOOTSTEP_ATTACK := 0.002
const FOOTSTEP_CURVE := 2.6
## Scuff of grit under the foot: a short, quiet, lowpassed noise burst on top.
const FOOTSTEP_SCUFF_SECONDS := 0.05
const FOOTSTEP_SCUFF_HZ := 1800.0
const FOOTSTEP_SCUFF_LEVEL := 0.3
const FOOTSTEP_SCUFF_ATTACK := 0.001
const FOOTSTEP_SCUFF_CURVE := 3.0
## Range the director's interchangeable takes are spread across. Under about a
## tone the takes are indistinguishable and the walk cycle turns into a
## metronome; much over a fifth and the creature sounds like it has four
## different feet.
const FOOTSTEP_PITCH_LOW := 0.88
const FOOTSTEP_PITCH_HIGH := 1.16

# --- Splash --------------------------------------------------------------------
const SPLASH_SECONDS := 0.4
## Water is bright noise whose brightness collapses. The sweeping cutoff is the
## whole sound; a fixed filter gives you a hiss.
const SPLASH_CUTOFF_FROM_HZ := 5200.0
const SPLASH_CUTOFF_TO_HZ := 520.0
const SPLASH_BLOOP_FROM_HZ := 240.0
const SPLASH_BLOOP_TO_HZ := 150.0
const SPLASH_BLOOP_LEVEL := 0.35
const SPLASH_ATTACK := 0.004
const SPLASH_DECAY := 0.05
const SPLASH_SUSTAIN := 0.5
const SPLASH_RELEASE := 0.3
const SPLASH_CURVE := 1.8

# --- Miracle cast --------------------------------------------------------------
const MIRACLE_CAST_SECONDS := 0.85
const MIRACLE_CAST_FROM_HZ := 180.0
const MIRACLE_CAST_TO_HZ := 1400.0
## Partials riding above the sweep. A fifth and an octave, quiet, so the sweep
## keeps its shape but gains some shimmer.
const MIRACLE_CAST_FIFTH_LEVEL := 0.38
const MIRACLE_CAST_OCTAVE_LEVEL := 0.2
const MIRACLE_CAST_ATTACK := 0.06
const MIRACLE_CAST_RELEASE := 0.22

# --- Miracle refused -----------------------------------------------------------
const MIRACLE_REFUSED_SECONDS := 0.5
const MIRACLE_REFUSED_FROM_HZ := 190.0
const MIRACLE_REFUSED_TO_HZ := 62.0
## Harmonics summed at 1/n. Five of them at 190 Hz top out at 950 Hz, well
## inside Nyquist — a naive sawtooth would alias into a whistle instead.
const MIRACLE_REFUSED_PARTIALS := 5
## Amplitude modulation is what makes this a buzz rather than a hum.
const MIRACLE_REFUSED_BUZZ_HZ := 28.0
const MIRACLE_REFUSED_BUZZ_DEPTH := 0.45
const MIRACLE_REFUSED_ATTACK := 0.02
const MIRACLE_REFUSED_DECAY := 0.1
const MIRACLE_REFUSED_SUSTAIN := 0.75
const MIRACLE_REFUSED_RELEASE := 0.28
const MIRACLE_REFUSED_CURVE := 1.2

# --- Thunder -------------------------------------------------------------------
const THUNDER_SECONDS := 2.4
const THUNDER_RUMBLE_HZ := 90.0
## The crack is a wider band, and it only exists at the front of the sound.
const THUNDER_CRACK_LOW_HZ := 600.0
const THUNDER_CRACK_HIGH_HZ := 2400.0
const THUNDER_CRACK_SECONDS := 0.25
const THUNDER_CRACK_LEVEL := 0.55
const THUNDER_CRACK_ATTACK := 0.001
const THUNDER_CRACK_CURVE := 2.2
const THUNDER_ATTACK := 0.015
const THUNDER_DECAY := 0.5
const THUNDER_SUSTAIN := 0.5
const THUNDER_RELEASE := 1.7
const THUNDER_CURVE := 1.8
## Two slow tremolos beating against each other, at rates drawn from the seed.
## Rolling thunder is not a smooth decay, it comes in waves.
const THUNDER_SWELL_DEPTH := 0.45
const THUNDER_SWELL_SLOW_HZ := Vector2(0.45, 0.9)
const THUNDER_SWELL_FAST_HZ := Vector2(1.5, 2.4)

# --- Ambient wind --------------------------------------------------------------
## Loop length. Long enough that the ear does not learn it, short enough that
## synthesising it at load costs tens of milliseconds rather than hundreds.
const WIND_SECONDS := 4.0
## Head and tail are crossfaded over this long to make the loop seamless. See
## ambient_wind() for why a crossfade is the only way to get there.
const WIND_CROSSFADE_SECONDS := 0.35
const WIND_RUMBLE_HZ := 140.0
const WIND_HISS_LOW_HZ := 420.0
## Deliberately not brighter. The top of this band is what the loop seam has to
## get through unnoticed: the higher it goes, the larger a single sample step at
## the join can be.
const WIND_HISS_HIGH_HZ := 700.0
const WIND_HISS_LEVEL := 0.55
## Swell rates, in whole cycles per loop. Whole cycles are not optional — a
## fractional one leaves the amplitude somewhere else at the end of the buffer
## than it was at the start, and no amount of crossfading hides that.
const WIND_SWELL_CYCLES := 3
const WIND_HISS_SWELL_CYCLES := 5
const WIND_SWELL_FLOOR := 0.55


## Every cue name. A copy, because a const Array in GDScript is only shallowly
## constant: a caller that sorted the returned array in place would rearrange
## this table for the rest of the session.
static func cue_names() -> Array[StringName]:
	var names: Array[StringName] = []
	names.assign(CUE_NAMES)
	return names


## Builds one cue by name, or null for a name that is not a cue.
##
## Null rather than a fallback beep: a caller asking for a cue that does not
## exist has a bug, and a director that plays something anyway hides it. Silence
## is the honest answer and AudioDirector.play treats it as one.
static func build(cue: StringName, rng: RandomNumberGenerator) -> AudioStreamWAV:
	match cue:
		CUE_PET:
			return pet()
		CUE_SLAP:
			return slap(rng)
		CUE_EAT:
			return eat(rng)
		CUE_FOOTSTEP:
			return footstep(rng)
		CUE_SPLASH:
			return splash(rng)
		CUE_MIRACLE_CAST:
			return miracle_cast()
		CUE_MIRACLE_REFUSED:
			return miracle_refused()
		CUE_BIRTH:
			return birth()
		CUE_THUNDER:
			return thunder(rng)
		CUE_AMBIENT_WIND:
			return ambient_wind(rng)
	return null


## `count` interchangeable takes of one cue, for the cues where hearing the
## identical sample twice running is itself the problem.
##
## Only the footstep varies today. Every other cue comes back as a single-entry
## array, so the caller needs no special case for the difference — which is the
## point of putting the knowledge of which cues vary here rather than in the
## director.
static func variants(cue: StringName, rng: RandomNumberGenerator, count: int) -> Array[AudioStreamWAV]:
	var takes: Array[AudioStreamWAV] = []
	if cue == CUE_FOOTSTEP and count > 1:
		for i in count:
			# Spread evenly rather than drawn at random, so no two takes land on
			# the same pitch and the set is identical every run.
			var pitch: float = lerpf(
				FOOTSTEP_PITCH_LOW, FOOTSTEP_PITCH_HIGH, float(i) / float(count - 1)
			)
			takes.append(footstep(rng, pitch))
		return takes
	var single: AudioStreamWAV = build(cue, rng)
	if single != null:
		takes.append(single)
	return takes


## A warm rising two-note chime: the creature has been praised.
static func pet() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(_frames(PET_SECONDS))
	samples = _add_chime(samples, 0.0, PET_NOTE_SECONDS, PET_LOW_HZ, 1.0)
	samples = _add_chime(
		samples, PET_SECOND_NOTE_AT, PET_NOTE_SECONDS, PET_HIGH_HZ, PET_HIGH_LEVEL
	)
	return _stream(samples, PEAK_PET)


## A short sharp noise transient with a fast decay: the creature has been slapped.
static func slap(rng: RandomNumberGenerator) -> AudioStreamWAV:
	var count: int = _frames(SLAP_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(count)
	var alpha: float = _one_pole_alpha(SLAP_SPLIT_HZ)
	var low: float = 0.0
	for i in count:
		var noise: float = rng.randf_range(-1.0, 1.0)
		low += alpha * (noise - low)
		# Input minus the lowpass is the high half of the same noise, which is
		# the crack. Reaching for a proper high-pass here buys nothing audible.
		var crack: float = noise - low
		var env: float = envelope(
			float(i) / float(MIX_RATE), SLAP_SECONDS,
			SLAP_ATTACK, 0.0, 0.0, SLAP_SECONDS, SLAP_CURVE
		)
		samples[i] = env * (crack + SLAP_LOW_MIX * low)
	return _stream(samples, PEAK_SLAP)


## A low crunch: band-limited noise chopped into grains. The creature is eating.
static func eat(rng: RandomNumberGenerator) -> AudioStreamWAV:
	var count: int = _frames(EAT_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(count)
	var alpha_high: float = _one_pole_alpha(EAT_BAND_HIGH_HZ)
	var alpha_low: float = _one_pole_alpha(EAT_BAND_LOW_HZ)
	var high: float = 0.0
	var low: float = 0.0
	var grain_frames: int = _frames(EAT_GRAIN_SECONDS)
	var gate: float = 1.0
	for i in count:
		if i % grain_frames == 0:
			gate = rng.randf_range(EAT_GRAIN_MIN, 1.0)
		var noise: float = rng.randf_range(-1.0, 1.0)
		high += alpha_high * (noise - high)
		low += alpha_low * (noise - low)
		var env: float = envelope(
			float(i) / float(MIX_RATE), EAT_SECONDS,
			EAT_ATTACK, EAT_DECAY, EAT_SUSTAIN, EAT_RELEASE, EAT_CURVE
		)
		# Two lowpasses subtracted from one another make the band. Six decibels
		# an octave on each side is not much of a filter, but it is enough to
		# place the sound, and a biquad with coefficient tables is a great deal
		# of machinery for a third of a second of chewing.
		samples[i] = env * gate * (high - low)
	return _stream(samples, PEAK_EAT)


## A very short soft thud. `pitch` scales the whole sound, which is what keeps a
## walk cycle from turning into a metronome — see variants().
static func footstep(rng: RandomNumberGenerator, pitch: float = 1.0) -> AudioStreamWAV:
	var count: int = _frames(FOOTSTEP_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(count)
	var alpha: float = _one_pole_alpha(FOOTSTEP_SCUFF_HZ)
	var scuff: float = 0.0
	var phase: float = 0.0
	var from_hz: float = FOOTSTEP_HZ * pitch
	var to_hz: float = from_hz * FOOTSTEP_HZ_FALL
	for i in count:
		var t: float = float(i) / float(MIX_RATE)
		phase += TAU * _sweep_hz(from_hz, to_hz, t / FOOTSTEP_SECONDS) / float(MIX_RATE)
		var body: float = envelope(
			t, FOOTSTEP_SECONDS, FOOTSTEP_ATTACK, 0.0, 0.0, FOOTSTEP_SECONDS, FOOTSTEP_CURVE
		)
		scuff += alpha * (rng.randf_range(-1.0, 1.0) - scuff)
		var grit: float = envelope(
			t, FOOTSTEP_SCUFF_SECONDS, FOOTSTEP_SCUFF_ATTACK, 0.0, 0.0,
			FOOTSTEP_SCUFF_SECONDS, FOOTSTEP_SCUFF_CURVE
		)
		samples[i] = body * sin(phase) + grit * FOOTSTEP_SCUFF_LEVEL * scuff
	return _stream(samples, PEAK_FOOTSTEP)


## Water: a bright noise burst whose brightness collapses, over a small bloop.
static func splash(rng: RandomNumberGenerator) -> AudioStreamWAV:
	var count: int = _frames(SPLASH_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(count)
	var filtered: float = 0.0
	var phase: float = 0.0
	for i in count:
		var t: float = float(i) / float(MIX_RATE)
		var progress: float = t / SPLASH_SECONDS
		# Recomputing the coefficient every sample costs one exp() per sample and
		# is what makes this a sweeping filter rather than a static one.
		var alpha: float = _one_pole_alpha(
			_sweep_hz(SPLASH_CUTOFF_FROM_HZ, SPLASH_CUTOFF_TO_HZ, progress)
		)
		filtered += alpha * (rng.randf_range(-1.0, 1.0) - filtered)
		phase += TAU * _sweep_hz(SPLASH_BLOOP_FROM_HZ, SPLASH_BLOOP_TO_HZ, progress) / float(MIX_RATE)
		var env: float = envelope(
			t, SPLASH_SECONDS,
			SPLASH_ATTACK, SPLASH_DECAY, SPLASH_SUSTAIN, SPLASH_RELEASE, SPLASH_CURVE
		)
		samples[i] = env * (filtered + SPLASH_BLOOP_LEVEL * sin(phase))
	return _stream(samples, PEAK_SPLASH)


## A rising sweep: a miracle has been cast.
static func miracle_cast() -> AudioStreamWAV:
	var count: int = _frames(MIRACLE_CAST_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(count)
	var phase: float = 0.0
	for i in count:
		var t: float = float(i) / float(MIX_RATE)
		var hz: float = _sweep_hz(
			MIRACLE_CAST_FROM_HZ, MIRACLE_CAST_TO_HZ, t / MIRACLE_CAST_SECONDS
		)
		phase += TAU * hz / float(MIX_RATE)
		var env: float = envelope(
			t, MIRACLE_CAST_SECONDS, MIRACLE_CAST_ATTACK, 0.0, 1.0, MIRACLE_CAST_RELEASE
		)
		var partials: float = sin(phase) \
			+ MIRACLE_CAST_FIFTH_LEVEL * sin(phase * 1.5) \
			+ MIRACLE_CAST_OCTAVE_LEVEL * sin(phase * 2.0)
		samples[i] = env * partials
	return _stream(samples, PEAK_MIRACLE_CAST)


## A low descending buzz: the cast was refused.
static func miracle_refused() -> AudioStreamWAV:
	var count: int = _frames(MIRACLE_REFUSED_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(count)
	var phase: float = 0.0
	for i in count:
		var t: float = float(i) / float(MIX_RATE)
		var hz: float = _sweep_hz(
			MIRACLE_REFUSED_FROM_HZ, MIRACLE_REFUSED_TO_HZ, t / MIRACLE_REFUSED_SECONDS
		)
		phase += TAU * hz / float(MIX_RATE)
		var tone: float = 0.0
		for partial in range(1, MIRACLE_REFUSED_PARTIALS + 1):
			tone += sin(phase * float(partial)) / float(partial)
		var buzz: float = 1.0 - MIRACLE_REFUSED_BUZZ_DEPTH \
			* (0.5 - 0.5 * cos(TAU * MIRACLE_REFUSED_BUZZ_HZ * t))
		var env: float = envelope(
			t, MIRACLE_REFUSED_SECONDS,
			MIRACLE_REFUSED_ATTACK, MIRACLE_REFUSED_DECAY, MIRACLE_REFUSED_SUSTAIN,
			MIRACLE_REFUSED_RELEASE, MIRACLE_REFUSED_CURVE
		)
		samples[i] = env * buzz * tone
	return _stream(samples, PEAK_MIRACLE_REFUSED)


## A bright little arpeggio: something has been born.
static func birth() -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	samples.resize(_frames(BIRTH_SECONDS))
	for i in BIRTH_NOTES.size():
		samples = _add_chime(
			samples, float(i) * BIRTH_NOTE_GAP, BIRTH_NOTE_SECONDS,
			BIRTH_NOTES[i], BIRTH_NOTE_LEVEL
		)
	return _stream(samples, PEAK_BIRTH)


## A long noise rumble with a slow decay, for lightning.
static func thunder(rng: RandomNumberGenerator) -> AudioStreamWAV:
	var count: int = _frames(THUNDER_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(count)
	var alpha_rumble: float = _one_pole_alpha(THUNDER_RUMBLE_HZ)
	var alpha_crack_high: float = _one_pole_alpha(THUNDER_CRACK_HIGH_HZ)
	var alpha_crack_low: float = _one_pole_alpha(THUNDER_CRACK_LOW_HZ)
	var rumble: float = 0.0
	var crack_high: float = 0.0
	var crack_low: float = 0.0
	# Drawn before the loop so the swell rates are part of what the seed decides.
	# Two nearby rates beating against each other is what makes thunder roll
	# instead of simply fading.
	var slow_hz: float = rng.randf_range(THUNDER_SWELL_SLOW_HZ.x, THUNDER_SWELL_SLOW_HZ.y)
	var fast_hz: float = rng.randf_range(THUNDER_SWELL_FAST_HZ.x, THUNDER_SWELL_FAST_HZ.y)
	for i in count:
		var t: float = float(i) / float(MIX_RATE)
		var noise: float = rng.randf_range(-1.0, 1.0)
		rumble += alpha_rumble * (noise - rumble)
		crack_high += alpha_crack_high * (noise - crack_high)
		crack_low += alpha_crack_low * (noise - crack_low)
		var crack_env: float = envelope(
			t, THUNDER_CRACK_SECONDS, THUNDER_CRACK_ATTACK, 0.0, 0.0,
			THUNDER_CRACK_SECONDS, THUNDER_CRACK_CURVE
		)
		var swell: float = 1.0 + THUNDER_SWELL_DEPTH * sin(TAU * slow_hz * t) * sin(TAU * fast_hz * t)
		var env: float = envelope(
			t, THUNDER_SECONDS,
			THUNDER_ATTACK, THUNDER_DECAY, THUNDER_SUSTAIN, THUNDER_RELEASE, THUNDER_CURVE
		)
		var body: float = rumble + THUNDER_CRACK_LEVEL * crack_env * (crack_high - crack_low)
		samples[i] = env * swell * body
	return _stream(samples, PEAK_THUNDER)


## The looping wind bed. Loop points are set on the returned stream.
##
## The seam is the whole difficulty. Filtered noise generated straight into a
## buffer of the loop length starts from a silent filter and ends mid-swing, so
## the join clicks every four seconds — which the ear picks out immediately and
## then cannot stop hearing. The fix is to synthesise a crossfade's worth of
## extra material and fade the head of the loop against the tail of that extra:
## the first sample of the result is then the sample that *followed* the last one
## in a single continuous signal, so the join is not a join at all.
static func ambient_wind(rng: RandomNumberGenerator) -> AudioStreamWAV:
	var loop_frames: int = _frames(WIND_SECONDS)
	# Half the loop is the hard ceiling on the crossfade: any longer and the head
	# would be fading against material it has already faded into.
	var fade: int = mini(_frames(WIND_CROSSFADE_SECONDS), _frames(WIND_SECONDS * 0.5))
	var raw := PackedFloat32Array()
	raw.resize(loop_frames + fade)
	var alpha_rumble: float = _one_pole_alpha(WIND_RUMBLE_HZ)
	var alpha_hiss_high: float = _one_pole_alpha(WIND_HISS_HIGH_HZ)
	var alpha_hiss_low: float = _one_pole_alpha(WIND_HISS_LOW_HZ)
	var rumble: float = 0.0
	var hiss_high: float = 0.0
	var hiss_low: float = 0.0
	for i in raw.size():
		# Swell phase is taken over the loop length, not the generated length, so
		# frame `loop_frames` sits at exactly the phase frame 0 does. That is what
		# lets the crossfade below splice the two together.
		var turn: float = float(i) / float(loop_frames)
		var noise: float = rng.randf_range(-1.0, 1.0)
		rumble += alpha_rumble * (noise - rumble)
		hiss_high += alpha_hiss_high * (noise - hiss_high)
		hiss_low += alpha_hiss_low * (noise - hiss_low)
		var swell: float = WIND_SWELL_FLOOR + (1.0 - WIND_SWELL_FLOOR) \
			* (0.5 + 0.5 * sin(TAU * float(WIND_SWELL_CYCLES) * turn))
		var hiss_swell: float = 0.5 + 0.5 * sin(TAU * float(WIND_HISS_SWELL_CYCLES) * turn)
		raw[i] = swell * (rumble + WIND_HISS_LEVEL * hiss_swell * (hiss_high - hiss_low))

	var samples := PackedFloat32Array()
	samples.resize(loop_frames)
	for i in loop_frames:
		samples[i] = raw[i]
	for i in fade:
		# Weight rises from 0, so sample 0 is exactly raw[loop_frames] and the
		# filter's silent start is faded out rather than heard.
		#
		# Equal POWER, not equal gain, and the sqrt is the whole of the difference.
		# The two halves being mixed are independent draws from the same noise
		# process, so the power of their sum is the sum of their powers: lerpf's
		# weights add to one in amplitude, which at the middle of the fade leaves
		# sqrt(0.5^2 + 0.5^2) = 0.707 of the bed's level — an audible 3 dB sag every
		# four seconds. Square-root weights add to one in power instead, which holds
		# the level flat across the join. For correlated material the reverse would
		# be true, which is why this is worth spelling out.
		var weight: float = float(i) / float(fade)
		samples[i] = raw[loop_frames + i] * sqrt(1.0 - weight) + raw[i] * sqrt(weight)

	var stream: AudioStreamWAV = _stream(samples, PEAK_AMBIENT_WIND)
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	# loop_end is exclusive: AudioStreamPlaybackWAV wraps once the read offset
	# reaches it, so the whole buffer plays and frame 0 follows the last frame.
	# Reading one frame past the end during interpolation is safe — AudioStreamWAV
	# pads its own data buffer on both sides for exactly that.
	stream.loop_end = loop_frames
	return stream


## ADSR envelope value at `t` seconds into a cue of `duration` seconds.
##
## One helper rather than the same maths retyped nine times. Every cue here is a
## short one-shot, so the sustain is whatever is left after attack, decay and
## release, and may be nothing at all: a slap is attack and release only.
##
## `curve` bends the whole envelope. A straight line falling to zero sounds
## unnatural for anything percussive, and raising the line to a power around
## three gives the plunge of an exponential decay while still reaching exactly
## zero at the end — a truncated exponential does not, and the step to silence
## is a click.
static func envelope(
	t: float,
	duration: float,
	attack: float,
	decay: float,
	sustain: float,
	release: float,
	curve: float = 1.0
) -> float:
	if t < 0.0 or t > duration or duration <= 0.0:
		return 0.0
	var value: float = sustain
	if attack > 0.0 and t < attack:
		value = t / attack
	else:
		var release_start: float = maxf(attack, duration - release)
		if t >= release_start:
			# Level the release falls from. With no decay that is full level; if
			# the release begins before the decay finished, it starts from
			# wherever the decay had got to rather than jumping back up.
			var level: float = 1.0
			if decay > 0.0:
				level = lerpf(1.0, sustain, clampf((release_start - attack) / decay, 0.0, 1.0))
			var span: float = duration - release_start
			value = 0.0 if span <= 0.0 else level * (1.0 - (t - release_start) / span)
		elif decay > 0.0 and t < attack + decay:
			value = lerpf(1.0, sustain, (t - attack) / decay)
	value = clampf(value, 0.0, 1.0)
	return value if is_equal_approx(curve, 1.0) else pow(value, curve)


## One struck note summed into `samples`, starting `start` seconds in, returning
## the buffer it wrote into.
##
## Returns the buffer rather than mutating the caller's, and callers must assign
## the result back. Packed arrays are copy-on-write value types in GDScript, so a
## write inside a function that received one as a parameter may land on a private
## copy and never reach the caller. That gives silence with no error anywhere,
## which is a miserable thing to debug.
static func _add_chime(
	samples: PackedFloat32Array, start: float, seconds: float, hz: float, level: float
) -> PackedFloat32Array:
	var first: int = maxi(0, _frame_at(start))
	var count: int = _frames(seconds)
	# Fixed frequency, so the phase is exact rather than accumulated: an
	# accumulator would drift by a sample's worth of rounding per sample.
	var step: float = TAU * hz / float(MIX_RATE)
	for i in count:
		var index: int = first + i
		if index >= samples.size():
			return samples
		var phase: float = step * float(i)
		var env: float = envelope(
			float(i) / float(MIX_RATE), seconds,
			seconds * CHIME_ATTACK_FRACTION, seconds * CHIME_DECAY_FRACTION,
			CHIME_SUSTAIN, seconds * CHIME_RELEASE_FRACTION, CHIME_CURVE
		)
		var partials: float = sin(phase) \
			+ CHIME_HARMONIC_2 * sin(phase * 2.0) \
			+ CHIME_HARMONIC_3 * sin(phase * 3.0)
		samples[index] += env * level * partials
	return samples


## Frequency `progress` of the way (0..1) through an exponential sweep.
##
## Exponential rather than linear because pitch is logarithmic: a linear ramp
## from 180 to 1400 Hz spends most of its time in the top octave and reads as a
## sweep that stalls. The caller must integrate this into a phase accumulator —
## evaluating sin(TAU * f(t) * t) instead is the classic sweep bug, since the
## instantaneous frequency of that expression is f(t) + t * f'(t), which for this
## sweep ends up near double the frequency asked for.
static func _sweep_hz(from_hz: float, to_hz: float, progress: float) -> float:
	return from_hz * pow(to_hz / from_hz, clampf(progress, 0.0, 1.0))


## Smoothing coefficient for a one-pole lowpass at `cutoff_hz`, for use as
## `y += alpha * (x - y)`.
static func _one_pole_alpha(cutoff_hz: float) -> float:
	return clampf(1.0 - exp(-TAU * cutoff_hz / float(MIX_RATE)), 0.0, 1.0)


static func _frame_at(seconds: float) -> int:
	return roundi(seconds * float(MIX_RATE))


static func _frames(seconds: float) -> int:
	return maxi(1, _frame_at(seconds))


## Wraps encoded samples in a non-looping mono 16-bit stream.
static func _stream(samples: PackedFloat32Array, peak: float) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	stream.data = _encode(samples, peak)
	return stream


## Scales float samples to `peak` of full scale and encodes them little-endian.
##
## The clamp stays even though normalisation already bounds the peak: rounding
## can put the loudest sample one count past the end of the range, and encode_s16
## of 32768 wraps to -32768, which is an audible full-scale spike.
static func _encode(samples: PackedFloat32Array, peak: float) -> PackedByteArray:
	var count: int = samples.size()
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	var loudest: float = 0.0
	for i in count:
		loudest = maxf(loudest, absf(samples[i]))
	var gain: float = 0.0 if loudest <= 0.0 else peak * FULL_SCALE / loudest
	for i in count:
		bytes.encode_s16(i * 2, clampi(roundi(samples[i] * gain), SAMPLE_MIN, SAMPLE_MAX))
	return bytes
