class_name StrokeSynth
extends RefCounted
## Synthetic stroke variants, so the recogniser can be tested against strokes it
## has never seen without collecting hundreds of real mouse drags first.
##
## Every draw comes from a RandomNumberGenerator the caller owns and seeds. No
## randf() or randi() here: a recognition-accuracy figure that cannot be
## reproduced is not a measurement, it is an anecdote.

## Uniform scale and translation are applied but not exposed as parameters,
## because $P normalisation removes both outright — the range genuinely changes
## nothing, and a knob that does nothing is a knob someone will waste an
## afternoon on. Only rotation and jitter are worth varying per test, so only
## those are arguments.
const SCALE_MIN := 0.35
const SCALE_MAX := 3.0
const TRANSLATION_RANGE := 400.0

## Worst-case fraction of interior points a thinned stroke keeps. A fast mouse
## drag samples sparsely and the recogniser has to cope with it.
const MIN_KEEP_FRACTION := 0.65


## One synthetic variant of a template: thinned, rotated, scaled, translated and
## jittered.
##
## `rotation_degrees` is a half-width — the rotation is drawn from
## [-rotation_degrees, +rotation_degrees]. Keep it inside the cone the
## recogniser claims to support (see recognizer.gd); asking for more is a test
## asserting behaviour the recogniser deliberately does not offer.
##
## `jitter` is a fraction of the stroke's own extent, so it stays meaningful
## whatever scale the variant lands at.
static func variant(
	points: PackedVector2Array,
	rng: RandomNumberGenerator,
	rotation_degrees: float = 30.0,
	jitter: float = 0.02
) -> PackedVector2Array:
	var result := PackedVector2Array()
	if points.is_empty():
		return result

	var extent: float = maxf(_extent(points), 0.0001)
	var thinned: PackedVector2Array = thin(points, rng)
	var angle: float = deg_to_rad(rng.randf_range(-rotation_degrees, rotation_degrees))
	var stroke_scale: float = rng.randf_range(SCALE_MIN, SCALE_MAX)
	var offset := Vector2(
		rng.randf_range(-TRANSLATION_RANGE, TRANSLATION_RANGE),
		rng.randf_range(-TRANSLATION_RANGE, TRANSLATION_RANGE)
	)
	# Jitter is scaled with the stroke, not applied in template units, so that a
	# variant drawn three times larger has three times the absolute wobble and
	# the same relative wobble. Otherwise the large variants would be unfairly
	# clean and the accuracy figure would flatter the recogniser.
	var noise: float = jitter * extent * stroke_scale

	result.resize(thinned.size())
	for i in thinned.size():
		var p: Vector2 = thinned[i].rotated(angle) * stroke_scale + offset
		p += Vector2(rng.randf_range(-noise, noise), rng.randf_range(-noise, noise))
		result[i] = p
	return result


## Randomly drops interior points, imitating a mouse sampled unevenly.
##
## The two endpoints are always kept. Dropping one would shorten the stroke and
## change what was drawn rather than blur how it was sampled, which is a
## different — and much larger — perturbation than this is meant to model.
static func thin(points: PackedVector2Array, rng: RandomNumberGenerator) -> PackedVector2Array:
	if points.size() <= 3:
		return points
	var keep: float = rng.randf_range(MIN_KEEP_FRACTION, 1.0)
	var result := PackedVector2Array()
	result.append(points[0])
	for i in range(1, points.size() - 1):
		if rng.randf() <= keep:
			result.append(points[i])
	result.append(points[points.size() - 1])
	return result


## A meaningless stroke: a bounded random walk.
##
## Used to check the recogniser does not answer confidently when the player drew
## nothing in particular. A recogniser that always returns its nearest template
## with a high score is worse than useless in a god-game, where a misread
## scribble spends the player's prayer power on the wrong miracle.
static func scribble(
	rng: RandomNumberGenerator, steps: int = 60, extent: float = 100.0
) -> PackedVector2Array:
	var result := PackedVector2Array()
	var p := Vector2.ZERO
	result.append(p)
	for i in steps:
		# A quarter of the box per step, and bounded. Larger steps let the walk
		# drift into a long jagged line, which is close enough to the water wave
		# to be an unfair test of the recogniser rather than a fair one.
		p += Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * (extent * 0.25)
		p.x = clampf(p.x, -extent, extent)
		p.y = clampf(p.y, -extent, extent)
		result.append(p)
	return result


## Longer bounding-box side of a stroke.
static func _extent(points: PackedVector2Array) -> float:
	var box: Rect2 = GesturePointCloud.bounds(points)
	return maxf(box.size.x, box.size.y)
