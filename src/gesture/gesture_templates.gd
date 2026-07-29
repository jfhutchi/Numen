class_name GestureTemplates
extends RefCounted
## The five NUMEN gesture templates and the miracle each one casts.
##
## Generated from maths, not typed out. Hand-entered coordinate lists rot: the
## moment a shape needs to be a little taller or a little more coiled, someone
## has to re-key a hundred numbers and will get one wrong.
##
## Authored in screen coordinates, y growing downward, because that is the frame
## the player draws in and the recogniser is deliberately rotation-sensitive
## (see recognizer.gd). A template authored y-up would be recognised as an
## upside-down gesture, which is to say not at all.
##
## The shapes are chosen so that their bounding-box aspect ratios differ, since
## $P scales uniformly and therefore keeps aspect. The wave is flat and wide
## (about 1.0 x 0.29 once normalised), the bolt tall and narrow (about 0.43 x
## 1.0), the chevron broad (1.0 x 0.8), and circle and spiral both fill their
## square but differ throughout the interior. Water and lightning are the pair
## most at risk of collapsing into each other — both are zigzags — so water is
## drawn as a smooth wave and lightning as hard-cornered segments, and the two
## are pulled apart in aspect as well.

const SPIRAL := &"spiral"
const CHEVRON := &"chevron"
const WAVE := &"wave"
const CIRCLE := &"circle"
const BOLT := &"bolt"

## Gesture name -> the miracle it casts.
const MIRACLES: Dictionary = {
	&"spiral": &"food",
	&"chevron": &"wood",
	&"wave": &"water",
	&"circle": &"heal",
	&"bolt": &"lightning",
}

## Radius of the round gestures, in template units. Absolute size is irrelevant
## — normalisation removes it — but keeping every template near the same scale
## makes them readable when printed or drawn as a debug overlay.
const RADIUS := 50.0
## Turns in the food spiral. Two or fewer and it starts to read as a circle;
## much more and the outer turn swallows nearly all the arc length, so
## resampling puts almost every point on the rim and it reads as a circle again.
const SPIRAL_TURNS := 3.0

const WAVE_LENGTH := 150.0
const WAVE_AMPLITUDE := 22.0
const WAVE_CYCLES := 3.0

## Points laid along each straight segment of the polyline gestures. Dense
## enough that stroke_synth's thinning rounds a corner slightly instead of
## deleting a whole limb of the gesture.
const SEGMENT_SAMPLES := 24


## Every template, by name.
static func all() -> Dictionary:
	var templates: Dictionary = {}
	templates[SPIRAL] = spiral()
	templates[CHEVRON] = chevron()
	templates[WAVE] = wave()
	templates[CIRCLE] = circle()
	templates[BOLT] = bolt()
	return templates


## The miracle a recognised gesture casts, or an empty name for an unknown one.
static func miracle_for(gesture_name: StringName) -> StringName:
	var found: StringName = MIRACLES.get(gesture_name, &"")
	return found


## Food. An Archimedean spiral drawn outward from the centre: radius grows
## linearly with angle, which is what makes it read as one coil rather than a
## set of concentric rings.
static func spiral(turns: float = SPIRAL_TURNS, samples: int = 220) -> PackedVector2Array:
	var points := PackedVector2Array()
	var sweep: float = TAU * turns
	for i in samples:
		var theta: float = sweep * float(i) / float(samples - 1)
		var radius: float = RADIUS * theta / sweep
		points.append(Vector2(cos(theta), sin(theta)) * radius)
	return points


## Heal. A closed circle: the last point repeats the first so the stroke ends
## where it began, as a drawn one would.
static func circle(samples: int = 96) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in samples:
		var theta: float = TAU * float(i) / float(samples - 1)
		points.append(Vector2(cos(theta), sin(theta)) * RADIUS)
	return points


## Wood. A broad V, drawn left to right through the apex.
static func chevron() -> PackedVector2Array:
	return _polyline(
		PackedVector2Array([Vector2(0.0, 0.0), Vector2(50.0, 80.0), Vector2(100.0, 0.0)]),
		SEGMENT_SAMPLES
	)


## Water. A smooth sine, wide and shallow. Smooth rather than hard-cornered so
## that corner sharpness, as well as aspect ratio, separates it from lightning.
static func wave(samples: int = 160) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in samples:
		var x: float = WAVE_LENGTH * float(i) / float(samples - 1)
		points.append(Vector2(x, WAVE_AMPLITUDE * sin(TAU * WAVE_CYCLES * x / WAVE_LENGTH)))
	return points


## Lightning. Four hard-cornered segments drawn top to bottom, tall and narrow,
## with the short backward kick in the middle that makes a bolt a bolt rather
## than a tall zigzag.
static func bolt() -> PackedVector2Array:
	return _polyline(
		PackedVector2Array([
			Vector2(60.0, 0.0),
			Vector2(18.0, 62.0),
			Vector2(44.0, 58.0),
			Vector2(8.0, 120.0),
		]),
		SEGMENT_SAMPLES
	)


## Fills a vertex list out into an evenly sampled polyline.
static func _polyline(vertices: PackedVector2Array, per_segment: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	if vertices.is_empty():
		return points
	points.append(vertices[0])
	for i in range(1, vertices.size()):
		var from: Vector2 = vertices[i - 1]
		var to: Vector2 = vertices[i]
		for step in range(1, per_segment + 1):
			points.append(from.lerp(to, float(step) / float(per_segment)))
	return points
