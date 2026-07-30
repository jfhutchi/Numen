class_name GestureGuide
extends Control
## The five castable gestures, drawn as the strokes the recogniser actually
## matches against.
##
## The shapes are taken from GestureTemplates.all() rather than re-drawn by hand.
## A hand-drawn icon has no way of noticing when the template behind it changes,
## so it drifts silently and the guide starts teaching a stroke that no longer
## casts anything — the worst possible failure for a help panel, because it looks
## fine.
##
## Names and costs come from MiracleLibrary for the same reason: one table, not
## two that agree until somebody retunes a cost.
##
## Layout and drawing are deliberately kept in _draw() over a single Control
## instead of a container full of Labels and TextureRects. There are five rows,
## none of them interactive, and a scene tree of thirty nodes to show them would
## be more code and more to keep in step.


## One row of the guide: a gesture, the miracle it casts, and whether the player
## can currently pay for it.
class Entry:
	extends RefCounted
	## Name of the $P template, as the recogniser returns it.
	var gesture: StringName = &""
	var miracle_id: StringName = &""
	## "unbound" rather than empty, so a broken binding is visible on screen
	## rather than being an invisible blank row.
	var display_name: String = "unbound"
	var cost: float = 0.0
	## The template, normalised into the icon box and ready to draw.
	var stroke := PackedVector2Array()
	var affordable: bool = false


@export_group("Layout")
@export var panel_width: float = 176.0
## Side of the square each stroke is normalised into.
@export var icon_size: float = 34.0
@export var row_height: float = 42.0
@export var padding: float = 8.0
@export var stroke_width: float = 2.0
@export var text_size: int = 13

@export_group("Colours")
@export var background_colour: Color = Color(0.05, 0.06, 0.09, 0.72)
@export var affordable_colour: Color = Color(0.78, 0.88, 1.0)
## Dimmed and greyed, not hidden. A miracle the player cannot afford yet is
## still something they need to know the stroke for.
@export var unaffordable_colour: Color = Color(0.44, 0.47, 0.54, 0.7)

## The table names and costs are read from. Assigned by the caller when it has
## one already; built here otherwise, since five Resources are free.
var library: MiracleLibrary = null

var _entries: Array = []
## Starts effectively unlimited, so a caller that forgets to call update_prayer()
## gets a readable guide rather than five greyed-out rows that look like a bug.
var _prayer: float = INF


func _ready() -> void:
	# The gesture itself is drawn on the viewport with the mouse. A Control that
	# accepted input would swallow any stroke begun over the guide, which is
	# exactly where a player reading it would start one.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	rebuild()


## Points the guide at a specific miracle table and redraws.
func bind_library(miracle_library: MiracleLibrary) -> void:
	library = miracle_library
	rebuild()


func toggle() -> void:
	visible = not visible


## Rebuilds every row from the gesture templates and the miracle table.
func rebuild() -> void:
	if library == null:
		library = MiracleLibrary.new()

	_entries.clear()
	var templates: Dictionary = GestureTemplates.all()
	# Sorted rather than taken in Dictionary order, which is insertion order:
	# harmless today, but it would silently reshuffle the panel the moment
	# GestureTemplates.all() built its five shapes in a different sequence.
	var names: Array = templates.keys()
	names.sort()

	for gesture: StringName in names:
		var entry := Entry.new()
		entry.gesture = gesture
		entry.stroke = normalise(templates[gesture], Vector2(icon_size, icon_size))
		entry.miracle_id = GestureTemplates.miracle_for(gesture)
		var miracle: Miracle = library.by_gesture(gesture)
		if miracle != null:
			entry.display_name = miracle.display_name
			entry.cost = miracle.prayer_cost
		_entries.append(entry)

	custom_minimum_size = Vector2(
		panel_width, padding * 2.0 + float(_entries.size()) * row_height
	)
	update_prayer(_prayer)


## Tells the guide how much prayer power the player has, so it can dim what they
## cannot pay for.
##
## The comparison matches PrayerPower.spend(), which refuses only when the cost
## is strictly greater than the pool: exactly enough is affordable.
func update_prayer(current: float) -> void:
	_prayer = current
	for entry: Entry in _entries:
		entry.affordable = current >= entry.cost
	queue_redraw()


func entries() -> Array:
	return _entries


func entry_for(gesture: StringName) -> Entry:
	for entry: Entry in _entries:
		if entry.gesture == gesture:
			return entry
	return null


## Fits a point cloud into `box`, scaled uniformly and centred.
##
## Uniform on purpose. The five templates are told apart partly by the aspect
## ratio of their bounding boxes (see gesture_templates.gd), so stretching each
## one to fill a square would draw a flat wave as tall as a bolt and hide the
## very difference the player needs to see.
static func normalise(points: PackedVector2Array, box: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if points.is_empty():
		return out

	var low: Vector2 = points[0]
	var high: Vector2 = points[0]
	for point: Vector2 in points:
		low = low.min(point)
		high = high.max(point)

	var span: Vector2 = high - low
	var scale: float = minf(box.x / maxf(span.x, 0.001), box.y / maxf(span.y, 0.001))
	var origin: Vector2 = (box - span * scale) * 0.5
	for point: Vector2 in points:
		out.append(origin + (point - low) * scale)
	return out


func _draw() -> void:
	if _entries.is_empty():
		return
	draw_rect(Rect2(Vector2.ZERO, size), background_colour, true)

	var font: Font = get_theme_default_font()
	var y: float = padding
	for entry: Entry in _entries:
		var tint: Color = affordable_colour if entry.affordable else unaffordable_colour
		var offset := Vector2(padding, y)

		if entry.stroke.size() >= 2:
			var placed := PackedVector2Array()
			for point: Vector2 in entry.stroke:
				placed.append(point + offset)
			draw_polyline(placed, tint, stroke_width, true)

		if font != null:
			draw_string(
				font,
				offset + Vector2(icon_size + padding, icon_size * 0.62),
				"%s  %.0f" % [entry.display_name, entry.cost],
				HORIZONTAL_ALIGNMENT_LEFT,
				-1.0,
				text_size,
				tint
			)
		y += row_height
