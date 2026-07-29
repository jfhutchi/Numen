class_name GesturePointCloud
extends RefCounted
## Stroke normalisation for the $P point-cloud recogniser: resample, scale,
## translate, and an explicit rotate the recogniser uses for its bounded
## rotation search.
##
## Provenance: written from the published description of the method in Vatavu,
## Anthony & Wobbrock, "Gestures as Point Clouds: A $P Recognizer for User
## Interface Prototypes" (ICMI 2012). No reference implementation was consulted
## or copied. ATTRIBUTIONS.md records the paper.
##
## Everything here is a static pure function over PackedVector2Array, so the
## normalisation can be tested without a recogniser, a scene tree or a mouse.
##
## Named GesturePointCloud rather than PointCloud on purpose: bare, generic
## class names are how this project has previously collided with a built-in and
## produced an error message that pointed nowhere near the cause.

## Resamples a stroke to exactly `count` points spaced equally along its arc
## length.
##
## A mouse samples fast movement sparsely and slow movement densely, so the raw
## point spacing describes the player's hand speed, not the shape they drew.
## Resampling throws the speed away and keeps the shape.
static func resample(points: PackedVector2Array, count: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	if count <= 0 or points.is_empty():
		return result

	var total: float = path_length(points)
	if points.size() == 1 or count == 1 or total <= 0.0:
		# A tap has no path to walk. Returning `count` copies of the one point
		# keeps every caller from having to special-case it, and the recogniser
		# will score it as nothing in particular, which is correct.
		result.resize(count)
		result.fill(points[0])
		return result

	var interval: float = total / float(count - 1)
	var accumulated: float = 0.0
	result.append(points[0])

	var previous: Vector2 = points[0]
	var i: int = 1
	while i < points.size():
		var current: Vector2 = points[i]
		var segment: float = previous.distance_to(current)
		if segment <= 0.0:
			previous = current
			i += 1
			continue
		if accumulated + segment >= interval:
			var inserted: Vector2 = previous.lerp(current, (interval - accumulated) / segment)
			result.append(inserted)
			# Walk on from the inserted point without advancing i: one long
			# segment of a fast drag can carry several resampled points, and
			# advancing here would silently return a short array.
			previous = inserted
			accumulated = 0.0
		else:
			accumulated += segment
			previous = current
			i += 1

	# Accumulated floating-point error can leave the walk one point short of the
	# far end, or one past it. Both are corrected rather than tolerated: the
	# greedy match compares two clouds index for index and a size mismatch would
	# quietly truncate one of them.
	while result.size() < count:
		result.append(points[points.size() - 1])
	if result.size() > count:
		result.resize(count)
	return result


## Total length of the polyline through the raw points.
static func path_length(points: PackedVector2Array) -> float:
	var total: float = 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total


## Axis-aligned bounds of a stroke.
##
## Public because the aspect ratio of a normalised cloud is load-bearing here:
## it is most of what separates the flat water wave from the tall lightning
## bolt, so tests assert on it directly.
static func bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var lower: Vector2 = points[0]
	var upper: Vector2 = points[0]
	for p: Vector2 in points:
		lower.x = minf(lower.x, p.x)
		lower.y = minf(lower.y, p.y)
		upper.x = maxf(upper.x, p.x)
		upper.y = maxf(upper.y, p.y)
	return Rect2(lower, upper - lower)


## Scales a stroke uniformly so that its longer bounding-box side is 1.
##
## $1 scales non-uniformly to a reference square, which throws the aspect ratio
## away. $P keeps it and NUMEN depends on that: the water wave and the lightning
## bolt are both zigzags, and that one is drawn flat and wide while the other is
## tall and narrow is the strongest feature between them. Stretching both to fill
## a square would delete exactly that feature.
static func scale_to_square(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	if points.is_empty():
		return result
	var box: Rect2 = bounds(points)
	var size: float = maxf(box.size.x, box.size.y)
	result.resize(points.size())
	if size <= 0.0:
		# A dot has no extent to divide by. Collapsing it on the origin is the
		# only sane answer and stops a division by zero seeding NaN through
		# every later distance.
		result.fill(Vector2.ZERO)
		return result
	for i in points.size():
		result[i] = (points[i] - box.position) / size
	return result


## Moves a stroke so its centroid sits on the origin.
static func translate_to_origin(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	if points.is_empty():
		return result
	var centre: Vector2 = centroid(points)
	result.resize(points.size())
	for i in points.size():
		result[i] = points[i] - centre
	return result


## Mean position of the points. Arc-length uniform after resampling, so this is
## the centroid of the drawn curve rather than of the raw input samples.
static func centroid(points: PackedVector2Array) -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for p: Vector2 in points:
		sum += p
	return sum / float(points.size())


## Rotates a stroke about the origin.
##
## Not part of $P normalisation — $P never rotates. The recogniser uses this for
## its bounded rotation search, and it has to happen before scale_to_square
## because rotation changes the bounding box. Scaling by a box measured before
## the rotation would leave each trial angle at a different size, and the match
## would then be partly about size rather than shape.
static func rotate_by(points: PackedVector2Array, radians: float) -> PackedVector2Array:
	if is_zero_approx(radians):
		return points
	var result := PackedVector2Array()
	result.resize(points.size())
	for i in points.size():
		result[i] = points[i].rotated(radians)
	return result


## The full $P normalisation: resample to `count` points, scale uniformly to the
## reference square, translate the centroid to the origin.
static func normalize(points: PackedVector2Array, count: int) -> PackedVector2Array:
	return translate_to_origin(scale_to_square(resample(points, count)))
