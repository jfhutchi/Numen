class_name GestureRecognizer
extends Resource
## The $P point-cloud gesture recogniser.
##
## Provenance: implemented from the published description of the algorithm in
## Vatavu, Anthony & Wobbrock, "Gestures as Point Clouds: A $P Recognizer for
## User Interface Prototypes" (ICMI 2012). Written from the method — normalise
## by resampling, uniform scaling and translation, then Greedy-Cloud-Match with
## epsilon-weighted greedy nearest-point matching over sampled start indices —
## not transcribed from any reference source. ATTRIBUTIONS.md records the paper.
##
## ROTATION — the deliberate choice, and what it costs.
##
## $P as published is rotation *sensitive*. Its normalisation resamples, scales
## and translates, and never rotates, so a shape turned on its side is a
## different cloud. That is kept here on purpose. Full rotation invariance (the
## $1-style indicative-angle trick) would fold NUMEN's water wave onto its
## lightning bolt: both are zigzags, and the only strong thing between them is
## that water is drawn flat and wide and lightning tall and narrow. Rotating
## every stroke to a canonical angle would destroy that difference and turn two
## of the five miracles into a coin flip.
##
## What is offered instead is *bounded* rotation tolerance. The stroke is
## matched at `rotation_candidates` trial angles spread evenly across
## +/- `rotation_tolerance_degrees` and the best of them wins. Thirty degrees
## absorbs a wonky hand and is nowhere near enough to turn a wave into a bolt.
##
## The consequence, stated plainly: the trial cone is bounded, so a stroke drawn
## further out of true than +/- `rotation_tolerance_degrees` is never matched at
## the angle it was drawn — it will read as some other gesture, or as nothing
## worth casting. That is intended behaviour, not a defect, and the acceptance
## test asserts recognition only inside the cone the recogniser claims.
##
## A half turn is the exception, and it comes from the shapes rather than from
## the search. Normalisation drops translation and the cloud match ignores
## stroke order, so a shape that is point-symmetric about its centroid maps onto
## itself at 180 degrees and matches there. The circle and the wave are exactly
## point-symmetric and the bolt is near enough, so those three ARE recognised
## upside down even though 180 degrees is nowhere near a trial angle. The
## chevron and the spiral are neither, so they are not.
##
## The search runs before scaling for a reason — see
## GesturePointCloud.rotate_by.
##
## Extends Resource rather than RefCounted only so the tunables below can be
## `@export`ed, per the project's no-magic-numbers rule. Nothing here needs a
## scene tree; tests build one with `.new()`.

@export_group("Normalisation")
## Points every stroke is resampled to before matching. 32 is the paper's own
## default. Below about 16 the cloud stops describing the shape; above about 64
## the O(n^2) greedy match gets expensive for no measured gain.
@export var point_count: int = 32

@export_group("Rotation tolerance")
## Half-width of the rotation cone the recogniser will match through. Raising
## this past roughly 45 degrees starts to make the water wave and the lightning
## bolt reachable from each other — see the note above.
@export var rotation_tolerance_degrees: float = 30.0
## Trial rotations spread evenly across that cone. Keep it odd so that zero is
## one of them: a stroke drawn straight should be matched exactly, not at the
## nearest trial angle. Five gives a worst-case residual of 7.5 degrees.
@export var rotation_candidates: int = 5

@export_group("Matching")
## The greedy match's epsilon. The paper samples n^(1-epsilon) start points
## rather than all n, and 0.5 — sqrt(n) starts — is its published default. This
## is where $P's speed comes from.
@export_range(0.0, 1.0) var greedy_epsilon: float = 0.5
## Mean weighted point offset, in reference-square units, at which the score
## reaches zero. A correct match sits well under a tenth of the square; a
## scribble sits nearer a third of it. Lower this to make the score harsher.
@export var score_falloff: float = 0.25
## Score below which a match is not worth acting on. recognize() always names
## its nearest template, so without a floor here every scribble casts whichever
## miracle it happened to land closest to and spends the player's prayer power
## doing it.
##
## Measured on the acceptance suite: real gestures — rotated inside the cone,
## scaled, thinned and jittered — score 0.882 on average, while random scribbles
## score 0.585 on average with an observed worst case of 0.760. 0.80 sits above
## every scribble seen and well under the real-gesture mean, so it is the gap,
## not a guess. Raise it to make the god harder to petition.
@export_range(0.0, 1.0) var min_score: float = 0.80

## gesture name -> raw template points, as handed in.
##
## Raw, not normalised, so that changing point_count can never leave a stale
## cloud of the wrong size behind. Recognition happens once per drawn gesture
## rather than once per frame, so five resamples per call are cheaper than a
## cache-invalidation bug.
var _templates: Dictionary = {}


## Registers a template under a name. Later templates with the same name replace
## earlier ones.
func add_template(gesture_name: StringName, points: PackedVector2Array) -> void:
	if points.size() < 2:
		push_warning("[gesture] template '%s' has fewer than two points; ignored" % gesture_name)
		return
	_templates[gesture_name] = points


## Loads the five NUMEN gestures. Not done in _init so tests can drive the
## recogniser with shapes of their own.
func load_default_templates() -> void:
	var defaults: Dictionary = GestureTemplates.all()
	for gesture_name: StringName in defaults:
		var points: PackedVector2Array = defaults[gesture_name]
		add_template(gesture_name, points)


func clear_templates() -> void:
	_templates.clear()


func template_count() -> int:
	return _templates.size()


func has_template(gesture_name: StringName) -> bool:
	return _templates.has(gesture_name)


## Best matching template for a raw stroke.
##
## Returns `{name: StringName, score: float, distance: float,
## rotation_degrees: float}`. `name` is empty when there is nothing to match
## against. `score` is in [0,1], higher is better; it is a confidence, not a
## probability, and a nearest template is always named — ask is_confident before
## acting on one, because nearest is not the same as right. `rotation_degrees` is
## the trial rotation that won, which tells the caller how crooked the stroke
## was.
##
## Deliberately returns only the winner. Per-template distances would be
## misleading: the early-abandoning in _greedy_cloud_match stops summing as soon
## as a pairing cannot win, so a loser's distance is a lower bound, not a value.
func recognize(points: PackedVector2Array) -> Dictionary:
	if _templates.is_empty() or points.size() < 2:
		return {"name": &"", "score": 0.0, "distance": INF, "rotation_degrees": 0.0}

	var resampled: PackedVector2Array = GesturePointCloud.resample(points, point_count)

	var clouds: Dictionary = {}
	for gesture_name: StringName in _templates:
		var raw: PackedVector2Array = _templates[gesture_name]
		clouds[gesture_name] = GesturePointCloud.normalize(raw, point_count)

	var best_name: StringName = &""
	var best_distance: float = INF
	var best_rotation: float = 0.0

	for angle: float in rotation_offsets():
		var cloud: PackedVector2Array = GesturePointCloud.translate_to_origin(
			GesturePointCloud.scale_to_square(GesturePointCloud.rotate_by(resampled, angle))
		)
		for candidate: StringName in clouds:
			var template: PackedVector2Array = clouds[candidate]
			# ponytail: every angle is tried against every template. A
			# coarse-to-fine pass (rank at zero, refine the top two) would cut
			# it by half again if this ever shows up on a frame budget.
			var distance: float = _greedy_cloud_match(cloud, template, best_distance)
			if distance < best_distance:
				best_distance = distance
				best_name = candidate
				best_rotation = angle

	return {
		"name": best_name,
		"score": _score_for(best_distance),
		"distance": best_distance,
		"rotation_degrees": rad_to_deg(best_rotation),
	}


## Whether a recognize() result is worth acting on.
##
## The one place rejection happens. Callers ask this instead of comparing scores
## themselves, so that retuning min_score retunes the whole game rather than
## whichever call sites remembered to check.
func is_confident(result: Dictionary) -> bool:
	var gesture_name: StringName = result.get("name", &"")
	return gesture_name != &"" and float(result.get("score", 0.0)) >= min_score


## The trial rotations, in radians, spread evenly across the tolerance cone.
## Public so a test can assert the cone it exercises is the cone on offer.
func rotation_offsets() -> PackedFloat32Array:
	var offsets := PackedFloat32Array()
	var count: int = maxi(rotation_candidates, 1)
	if count == 1 or rotation_tolerance_degrees <= 0.0:
		offsets.append(0.0)
		return offsets
	var span: float = deg_to_rad(rotation_tolerance_degrees)
	for i in count:
		offsets.append(lerpf(-span, span, float(i) / float(count - 1)))
	return offsets


## Turns a raw $P match distance into a confidence in [0,1].
##
## The paper stops at the distance and leaves scoring to the application. The
## distance is a weighted sum over n points, so it grows with n and means
## nothing on its own. Dividing by the total weight — the weights run
## 1, 1-1/n, ... 1/n, summing to (n+1)/2 — turns it into the mean offset of a
## matched pair in reference-square units, which is comparable across point
## counts and readable by a human.
func _score_for(distance: float) -> float:
	if not is_finite(distance):
		return 0.0
	var weight_sum: float = 0.5 * float(point_count + 1)
	var mean_offset: float = distance / maxf(weight_sum, 1.0)
	return clampf(1.0 - mean_offset / maxf(score_falloff, 0.0001), 0.0, 1.0)


## Greedy-Cloud-Match: try a spread of starting points and both directions of
## the (asymmetric) cloud distance, and keep the smallest.
##
## Both directions matter. The cloud distance walks one cloud and consumes
## points from the other, so it is not symmetric — a sparse stroke matched
## against a dense template scores differently from the reverse.
##
## `ceiling` is the best distance found so far anywhere in this recognition.
## Passing it down lets a hopeless pairing abandon after a handful of points
## instead of completing a full O(n^2) pass, which is most of what keeps a
## five-template, five-angle search cheap enough to run inside a unit test.
func _greedy_cloud_match(
	a: PackedVector2Array, b: PackedVector2Array, ceiling: float
) -> float:
	var n: int = mini(a.size(), b.size())
	if n <= 0:
		return INF
	var step: int = maxi(floori(pow(float(n), 1.0 - greedy_epsilon)), 1)
	var best: float = ceiling
	var start: int = 0
	while start < n:
		best = minf(best, _cloud_distance(a, b, start, n, best))
		best = minf(best, _cloud_distance(b, a, start, n, best))
		start += step
	return best


## One greedy pass: walk `a` from `start`, and give each of its points the
## nearest point of `b` that nothing has claimed yet.
##
## Matches made early, near the start index, are weighted more heavily than late
## ones. Greedy matching is at its most trustworthy at the beginning and at its
## worst at the end, where it is forced onto whatever partner is left over; the
## weighting stops that forced last assignment from dominating the total.
##
## Returns a partial sum if it exceeds `ceiling`. That is safe only because the
## sum never decreases and the caller only ever compares the result against the
## same ceiling — see _greedy_cloud_match.
static func _cloud_distance(
	a: PackedVector2Array, b: PackedVector2Array, start: int, n: int, ceiling: float
) -> float:
	var matched := PackedByteArray()
	matched.resize(n)
	matched.fill(0)

	var sum: float = 0.0
	var i: int = start
	for k in n:
		var index: int = -1
		# Compared squared, rooted once. The inner loop is the whole cost of the
		# recogniser and sqrt in it buys nothing: squared distance orders the
		# candidates identically.
		var nearest: float = INF
		for j in n:
			if matched[j] != 0:
				continue
			var d: float = a[i].distance_squared_to(b[j])
			if d < nearest:
				nearest = d
				index = j
		if index < 0:
			break
		matched[index] = 1
		sum += (1.0 - float(k) / float(n)) * sqrt(nearest)
		if sum >= ceiling:
			return sum
		i = (i + 1) % n
	return sum
