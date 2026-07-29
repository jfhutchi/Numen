extends GutTest
## Phase 3a acceptance tests for the $P point-cloud gesture recogniser.
##
## The keystone here is test_recognises_rotated_and_scaled_variants: at least
## twenty synthetic strokes per template, rotated and scaled, recognised at 90%
## or better. Everything else guards a decision that was made deliberately and
## would otherwise rot silently — uniform scaling, bounded rotation tolerance,
## and refusing to answer confidently when handed noise.

const CLOUD := preload("res://src/gesture/point_cloud.gd")
const RECOGNIZER := preload("res://src/gesture/recognizer.gd")
const TEMPLATES := preload("res://src/gesture/gesture_templates.gd")
const SYNTH := preload("res://src/gesture/stroke_synth.gd")

## Fixed. A recognition-accuracy number that cannot be reproduced is an
## anecdote, and a flaky accuracy test is worse than none.
const SEED := 20260729
## The acceptance criterion asks for at least twenty strokes per template.
const VARIANTS_PER_TEMPLATE := 20
## Rotation half-width the variants are drawn with. This must not exceed the
## cone the recogniser claims to support: $P is left rotation-sensitive on
## purpose so the flat water wave and the tall lightning bolt stay apart, and a
## test demanding more than that would be testing a promise nobody made.
const TEST_ROTATION_DEGREES := 30.0
## Positional noise as a fraction of stroke extent, roughly a shaky hand.
const TEST_JITTER := 0.02

var _recognizer: GestureRecognizer
var _rng: RandomNumberGenerator


func before_each() -> void:
	_recognizer = RECOGNIZER.new()
	_recognizer.load_default_templates()
	_rng = RandomNumberGenerator.new()
	_rng.seed = SEED


# --- Normalisation ------------------------------------------------------------

func test_resampling_produces_exactly_n_points() -> void:
	var sources: Array = [
		TEMPLATES.spiral(),
		TEMPLATES.chevron(),
		TEMPLATES.circle(),
		PackedVector2Array([Vector2(0.0, 0.0), Vector2(10.0, 0.0)]),
	]
	for count: int in [8, 16, 32, 64, 128]:
		for source: PackedVector2Array in sources:
			assert_eq(
				CLOUD.resample(source, count).size(),
				count,
				"resample must return exactly the count asked for"
			)

	# A tap: no path length at all. Must not divide by zero and must not come
	# back short — the greedy match compares two clouds index for index and a
	# short array would quietly truncate the other one.
	var tap := PackedVector2Array([Vector2(5.0, 5.0), Vector2(5.0, 5.0), Vector2(5.0, 5.0)])
	assert_eq(CLOUD.resample(tap, 32).size(), 32, "a zero-length stroke must still resample")


func test_resampled_points_are_evenly_spaced() -> void:
	var source: PackedVector2Array = TEMPLATES.circle()
	var count: int = 32
	var resampled: PackedVector2Array = CLOUD.resample(source, count)
	var expected: float = CLOUD.path_length(source) / float(count - 1)

	var shortest: float = INF
	var longest: float = 0.0
	for i in range(1, resampled.size()):
		var gap: float = resampled[i - 1].distance_to(resampled[i])
		shortest = minf(shortest, gap)
		longest = maxf(longest, gap)
	gut.p("resample spacing: expected %.4f, shortest %.4f, longest %.4f" % [
		expected, shortest, longest
	])
	assert_between(shortest, expected * 0.5, expected * 1.5, "a resampled gap collapsed")
	assert_between(longest, expected * 0.5, expected * 1.5, "a resampled gap stretched")


func test_normalisation_centres_and_bounds_the_cloud() -> void:
	var templates: Dictionary = TEMPLATES.all()
	for gesture_name: StringName in templates:
		var source: PackedVector2Array = templates[gesture_name]
		var cloud: PackedVector2Array = CLOUD.normalize(source, 32)
		var box: Rect2 = CLOUD.bounds(cloud)
		var centre: Vector2 = CLOUD.centroid(cloud)

		assert_almost_eq(maxf(box.size.x, box.size.y), 1.0, 0.001,
			"%s should fill the reference square on its longer side" % gesture_name)
		assert_almost_eq(centre.x, 0.0, 0.001, "%s centroid should sit on the origin" % gesture_name)
		assert_almost_eq(centre.y, 0.0, 0.001, "%s centroid should sit on the origin" % gesture_name)


func test_normalisation_removes_scale_and_translation() -> void:
	# Scale and translation invariance is the whole reason normalisation exists;
	# if it were only approximate, the accuracy figure would be measuring how
	# big the test happened to draw things.
	var templates: Dictionary = TEMPLATES.all()
	for gesture_name: StringName in templates:
		var source: PackedVector2Array = templates[gesture_name]
		var moved := PackedVector2Array()
		moved.resize(source.size())
		for i in source.size():
			moved[i] = source[i] * 7.3 + Vector2(-220.0, 640.0)

		var a: PackedVector2Array = CLOUD.normalize(source, 32)
		var b: PackedVector2Array = CLOUD.normalize(moved, 32)
		var worst: float = 0.0
		for i in a.size():
			worst = maxf(worst, a[i].distance_to(b[i]))
		assert_lt(worst, 0.005, "%s moved and scaled should normalise identically" % gesture_name)


func test_uniform_scaling_keeps_the_aspect_ratio() -> void:
	# Regression for a deliberate departure from $1. $1 stretches a stroke into
	# a reference square, which would flatten the tall bolt and the flat wave
	# into the same box and delete the strongest feature between them. $P scales
	# uniformly and this test pins that down.
	var wave: PackedVector2Array = CLOUD.normalize(TEMPLATES.wave(), 32)
	var bolt: PackedVector2Array = CLOUD.normalize(TEMPLATES.bolt(), 32)
	var wave_box: Rect2 = CLOUD.bounds(wave)
	var bolt_box: Rect2 = CLOUD.bounds(bolt)
	gut.p("normalised extents: wave %.3f x %.3f, bolt %.3f x %.3f" % [
		wave_box.size.x, wave_box.size.y, bolt_box.size.x, bolt_box.size.y
	])
	assert_lt(wave_box.size.y, 0.5, "the water wave must stay flat after normalisation")
	assert_lt(bolt_box.size.x, 0.7, "the lightning bolt must stay narrow after normalisation")


# --- Recognition --------------------------------------------------------------

func test_recognises_rotated_and_scaled_variants() -> void:
	# THE acceptance test. Twenty synthetic strokes per template, each thinned,
	# rotated within the supported cone, uniformly scaled, translated and
	# jittered. Overall accuracy must reach 90%.
	var templates: Dictionary = TEMPLATES.all()
	var total: int = 0
	var correct: int = 0
	var score_total: float = 0.0

	gut.p("template  | trials | correct | accuracy | mean score | min score")
	for gesture_name: StringName in templates:
		var source: PackedVector2Array = templates[gesture_name]
		var hits: int = 0
		var scores: float = 0.0
		var lowest: float = 1.0

		for i in VARIANTS_PER_TEMPLATE:
			var stroke: PackedVector2Array = SYNTH.variant(
				source, _rng, TEST_ROTATION_DEGREES, TEST_JITTER
			)
			var result: Dictionary = _recognizer.recognize(stroke)
			var got: StringName = result["name"]
			var score: float = result["score"]
			scores += score
			lowest = minf(lowest, score)
			if got == gesture_name:
				hits += 1
			else:
				gut.p("  miss: drew %s, recognised %s (score %.3f, rotation %.1f deg)" % [
					gesture_name, got, score, result["rotation_degrees"]
				])

		total += VARIANTS_PER_TEMPLATE
		correct += hits
		score_total += scores
		gut.p("%-9s | %6d | %7d | %7.1f%% | %10.3f | %9.3f" % [
			gesture_name,
			VARIANTS_PER_TEMPLATE,
			hits,
			100.0 * float(hits) / float(VARIANTS_PER_TEMPLATE),
			scores / float(VARIANTS_PER_TEMPLATE),
			lowest,
		])

	var accuracy: float = float(correct) / float(total)
	gut.p("overall: %d/%d correct = %.1f%%, mean score %.3f (seed %d, rotation +/-%.0f deg, jitter %.0f%%)" % [
		correct, total, 100.0 * accuracy, score_total / float(total),
		SEED, TEST_ROTATION_DEGREES, 100.0 * TEST_JITTER
	])

	assert_gte(total, 100, "the criterion asks for at least 100 strokes overall")
	assert_gte(accuracy, 0.90, "recognition accuracy fell below the 90% acceptance criterion")


func test_scribble_does_not_match_confidently() -> void:
	# A recogniser that always answers with its nearest template at high
	# confidence is worse than useless in a god-game: a misread scribble spends
	# the player's prayer power on the wrong miracle. The recogniser always
	# names *something*, so what has to hold is that the score is clearly worse
	# than a real gesture's, and that min_score falls in the gap between the two
	# populations: every real gesture above it, every scribble below.
	var templates: Dictionary = TEMPLATES.all()

	var good_total: float = 0.0
	var good_count: int = 0
	for gesture_name: StringName in templates:
		var source: PackedVector2Array = templates[gesture_name]
		var plain: Dictionary = _recognizer.recognize(source)
		assert_eq(plain["name"], gesture_name, "%s must recognise itself" % gesture_name)
		assert_true(_recognizer.is_confident(plain),
			"%s drawn exactly scored %.3f, below the %.3f confidence threshold" % [
				gesture_name, plain["score"], _recognizer.min_score
			])
		for i in 2:
			var stroke: PackedVector2Array = SYNTH.variant(
				source, _rng, TEST_ROTATION_DEGREES, TEST_JITTER
			)
			good_total += float(_recognizer.recognize(stroke)["score"])
			good_count += 1
	var good_mean: float = good_total / float(good_count)

	var noise_total: float = 0.0
	var noise_worst: float = 0.0
	var trials: int = 10
	gut.p("scribble | recognised | score")
	for i in trials:
		var stroke: PackedVector2Array = SYNTH.scribble(_rng)
		var result: Dictionary = _recognizer.recognize(stroke)
		var score: float = result["score"]
		noise_total += score
		noise_worst = maxf(noise_worst, score)
		gut.p("%8d | %10s | %.3f" % [i + 1, result["name"], score])
		assert_false(_recognizer.is_confident(result),
			"scribble %d was accepted as %s at %.3f" % [i + 1, result["name"], score])
	var noise_mean: float = noise_total / float(trials)

	gut.p("mean score: real gestures %.3f, scribbles %.3f (worst scribble %.3f)" % [
		good_mean, noise_mean, noise_worst
	])
	# 0.80, not 0.75. Measured across many seeds the scribble score distribution
	# runs mean 0.585 with an observed maximum of 0.760, and it crossed 0.75
	# about once in forty seeds. A bound sitting inside the tail of the
	# distribution it is bounding is a flake, not a test. 0.80 is outside
	# everything observed and is the same number min_score rejects at. The gap
	# assertion below is the one carrying the weight and is deliberately left
	# exactly where it was.
	assert_lt(noise_worst, 0.80, "a random scribble matched a template confidently")
	assert_lt(noise_mean, good_mean - 0.15,
		"scribbles score too close to real gestures for a threshold to separate them")


func test_recognition_survives_a_reversed_stroke() -> void:
	# $P matches clouds, not sequences, so a gesture drawn backwards is the same
	# gesture. The epsilon weighting is start-point biased, which is exactly why
	# the algorithm samples several start indices and both match directions —
	# drop either and this is the test that goes red.
	var templates: Dictionary = TEMPLATES.all()
	for gesture_name: StringName in templates:
		var source: PackedVector2Array = templates[gesture_name]
		var forward: PackedVector2Array = SYNTH.variant(source, _rng, 0.0, 0.0)
		var backward: PackedVector2Array = _reversed(forward)

		var a: Dictionary = _recognizer.recognize(forward)
		var b: Dictionary = _recognizer.recognize(backward)
		gut.p("%-9s forward %s %.3f | reversed %s %.3f" % [
			gesture_name, a["name"], a["score"], b["name"], b["score"]
		])
		# Pin the forward identity first. Without it the agreement below is
		# satisfied just as well by both directions being wrong together.
		assert_eq(a["name"], gesture_name,
			"%s was misrecognised drawn forwards, so the reversal check means nothing" % gesture_name)
		assert_eq(b["name"], a["name"], "%s changed identity when drawn backwards" % gesture_name)
		assert_almost_eq(float(b["score"]), float(a["score"]), 0.10,
			"%s scored differently when drawn backwards" % gesture_name)


func test_recognition_survives_a_different_starting_point() -> void:
	# The circle is the case that matters: on a closed stroke the player can
	# start anywhere on the rim and it is the same gesture.
	var source: PackedVector2Array = TEMPLATES.circle()
	var baseline: Dictionary = _recognizer.recognize(source)
	assert_eq(baseline["name"], TEMPLATES.CIRCLE, "the plain circle template must recognise itself")

	for offset: int in [17, 41, 63]:
		var rolled: PackedVector2Array = _roll_closed(source, offset)
		var result: Dictionary = _recognizer.recognize(rolled)
		gut.p("circle started at index %d: %s (score %.3f)" % [offset, result["name"], result["score"]])
		assert_eq(result["name"], TEMPLATES.CIRCLE,
			"a circle begun elsewhere on the rim must still be a circle")


func test_rotation_support_is_bounded_as_documented() -> void:
	# Regression for the rotation decision in recognizer.gd. Inside the claimed
	# cone the gesture must be recognised; well outside it the score must fall
	# away. The test says so out loud rather than pretending $P is rotation
	# invariant, because making it so would collapse water onto lightning.
	var source: PackedVector2Array = TEMPLATES.wave()
	var upright: float = 0.0
	var sideways: float = 0.0

	gut.p("rotation | recognised | score")
	# 7.5 and 22.5 are the angles that matter. The trial rotations are
	# -30/-15/0/15/30, so every multiple of 15 is cancelled exactly and probing
	# only those measures nothing but the trial grid itself. Halfway between two
	# trials is the recogniser's worst case — a 7.5 degree residual it cannot
	# cancel — and it is the only place partial cancellation is exercised.
	for degrees: float in [0.0, 7.5, 15.0, 22.5, 30.0, 60.0, 90.0]:
		var rotated: PackedVector2Array = CLOUD.rotate_by(source, deg_to_rad(degrees))
		var result: Dictionary = _recognizer.recognize(rotated)
		var score: float = result["score"]
		gut.p("%7.1f | %10s | %.3f" % [degrees, result["name"], score])
		if is_zero_approx(degrees):
			upright = score
		if is_equal_approx(degrees, 90.0):
			sideways = score
		if degrees <= TEST_ROTATION_DEGREES:
			assert_eq(result["name"], TEMPLATES.WAVE,
				"a wave rotated %.1f degrees is inside the supported cone" % degrees)

	assert_lt(sideways, upright - 0.15,
		"a wave turned on its side must not score like an upright one")

	# And the search has to actually buy the residual back. At 22.5 degrees the
	# nearest trial angles are 15 and 30, so a recogniser that only ever tries
	# zero is left with the whole 22.5 to absorb and must score strictly worse.
	# This is what stops the probes above from passing on a gutted search: the
	# comparison is a minimum over a subset of the same angles, so it cannot be
	# lucky, only right or broken.
	var unrotated: GestureRecognizer = RECOGNIZER.new()
	unrotated.load_default_templates()
	unrotated.rotation_candidates = 1
	var tilted: PackedVector2Array = CLOUD.rotate_by(source, deg_to_rad(22.5))
	var searched: float = float(_recognizer.recognize(tilted)["score"])
	var unsearched: float = float(unrotated.recognize(tilted)["score"])
	gut.p("22.5 deg: rotation search %.3f, no search %.3f" % [searched, unsearched])
	assert_gt(searched, unsearched,
		"the rotation search scored no better than not searching at all")


func test_recognizer_with_no_templates_answers_nothing() -> void:
	_recognizer.clear_templates()
	assert_eq(_recognizer.template_count(), 0)
	var result: Dictionary = _recognizer.recognize(TEMPLATES.circle())
	assert_eq(result["name"], &"", "an empty recogniser must not name a gesture")
	assert_eq(float(result["score"]), 0.0)


func test_every_gesture_maps_to_a_miracle() -> void:
	var expected: Dictionary = {
		TEMPLATES.SPIRAL: &"food",
		TEMPLATES.CHEVRON: &"wood",
		TEMPLATES.WAVE: &"water",
		TEMPLATES.CIRCLE: &"heal",
		TEMPLATES.BOLT: &"lightning",
	}
	var templates: Dictionary = TEMPLATES.all()
	assert_eq(templates.size(), 5, "the five NUMEN gestures must all be generated")
	for gesture_name: StringName in templates:
		assert_eq(TEMPLATES.miracle_for(gesture_name), expected[gesture_name],
			"%s casts the wrong miracle" % gesture_name)
	assert_eq(TEMPLATES.miracle_for(&"not_a_gesture"), &"",
		"an unknown gesture must map to no miracle rather than a default one")


# --- Helpers ------------------------------------------------------------------

func _reversed(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(points.size())
	for i in points.size():
		result[i] = points[points.size() - 1 - i]
	return result


## Restarts a closed stroke at a different point on its loop. The template's
## last point repeats its first, so the repeat is dropped before rolling and
## re-added afterwards.
func _roll_closed(points: PackedVector2Array, offset: int) -> PackedVector2Array:
	var loop: int = points.size() - 1
	var result := PackedVector2Array()
	result.resize(loop + 1)
	for i in loop + 1:
		result[i] = points[(offset + i) % loop]
	return result
