class_name GestureTrail
extends MeshInstance3D
## The player's gesture stroke, drawn in the world as a glowing ground ribbon.
##
## The 2D Line2D on the HUD stays — it is the recogniser's input record. This is
## presentation only: casting is aimed at the world, so the stroke the player
## sees follows the ground the miracle will land on.
##
## The node must stay at the origin with no transform: points are stored in
## world space and written straight into the mesh as local vertices.

## Height the ribbon floats above the ground, in metres.
@export var hover_height: float = 0.6
## Points closer than this are merged. Mouse motion arrives far denser than the
## ribbon needs, and the whole ImmediateMesh is rebuilt on every extend — a
## stroke of 500 near-identical points would be rebuilt 500 times for nothing.
@export var min_spacing: float = 0.35
## Longest stroke kept, in points. Spacing bounds density but not length — an
## island-wide sweep grew the array without limit, and _rebuild is O(n) per
## extend, so a long stroke cost O(n^2) overall. Oldest points drop first, which
## also reads correctly: the tail of a long gesture fades away behind the hand.
@export var max_points: int = 512
@export var ribbon_width: float = 0.5
## Seconds the finished stroke takes to fade out.
@export var fade_time: float = 0.5
## Albedo multiplier past the environment's glow threshold (1.05) so the ribbon
## blooms. Deliberately in albedo rather than the material's emission slot: an
## unshaded material outputs albedo directly on both renderers, which makes it
## the one channel guaranteed to reach the glow pass under gl_compatibility.
@export var glow_energy: float = 2.0
## Authored in sRGB; converted where it is consumed.
@export var trail_colour: Color = Color(0.75, 0.86, 1.0)

var _points: PackedVector3Array = PackedVector3Array()
var _drawing: bool = false
var _fade_left: float = 0.0
var _island: Object = null
var _mesh: ImmediateMesh = ImmediateMesh.new()
var _material: StandardMaterial3D = StandardMaterial3D.new()


func _init() -> void:
	top_level = true
	name = "GestureTrail"
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = _hdr_colour(1.0)
	# Transparent surfaces sort by render_priority, and the sea is a transparent
	# depth-writing plane at 0 — at the default the water drew over the trail.
	# 2 rather than 1 so it also draws after the influence ring.
	_material.render_priority = 2
	material_override = _material


func _process(delta: float) -> void:
	advance(delta)


## The ground provider: anything with height_at(x, z) -> float. Duck-typed so
## tests can hand in a stub instead of generating a whole island.
func set_island(island: Object) -> void:
	_island = island


func begin() -> void:
	_drawing = true
	_fade_left = 0.0
	_points = PackedVector3Array()
	_mesh.clear_surfaces()
	_material.albedo_color = _hdr_colour(1.0)


## Adds a world-space point under the pointer. The stored point snaps to terrain
## height plus hover_height — the given y is ignored when an island is bound —
## and the terrain is clamped to the waterline so the ribbon rides over the sea
## rather than diving to the sea floor.
func extend(world_point: Vector3) -> void:
	if not _drawing:
		return
	var ground: float = world_point.y
	if _island != null and _island.has_method("height_at"):
		ground = _island.height_at(world_point.x, world_point.z)
	var point := Vector3(world_point.x, maxf(ground, 0.0) + hover_height, world_point.z)
	if not _points.is_empty() and point.distance_to(_points[_points.size() - 1]) < min_spacing:
		return
	_points.append(point)
	while _points.size() > max_points:
		_points.remove_at(0)
	_rebuild()


## Stops the stroke and starts the fade; advance() finishes it.
func end_stroke() -> void:
	_drawing = false
	_fade_left = fade_time


## Ticks the fade. Split out of _process so headless tests can drive time
## directly instead of waiting real frames.
func advance(delta: float) -> void:
	if _drawing or _fade_left <= 0.0:
		return
	_fade_left -= delta
	if _fade_left <= 0.0:
		_fade_left = 0.0
		_points = PackedVector3Array()
		_mesh.clear_surfaces()
		return
	# With additive blending, fading the alpha fades the contribution to nothing.
	_material.albedo_color = _hdr_colour(_fade_left / maxf(fade_time, 0.001))


func point_count() -> int:
	return _points.size()


## Rebuilds the ribbon: a triangle strip, one vertex pair per point, laid flat
## and widened perpendicular to the stroke's direction in XZ.
func _rebuild() -> void:
	_mesh.clear_surfaces()
	if _points.size() < 2:
		return
	var last: int = _points.size() - 1
	var half: float = ribbon_width * 0.5
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in _points.size():
		# Central difference for the direction, so interior points bend smoothly
		# and the two ends borrow their neighbour's heading.
		var along: Vector3 = _points[mini(i + 1, last)] - _points[maxi(i - 1, 0)]
		along.y = 0.0
		if along.length_squared() < 0.000001:
			along = Vector3.FORWARD
		var side: Vector3 = Vector3(-along.z, 0.0, along.x).normalized() * half
		_mesh.surface_add_vertex(_points[i] - side)
		_mesh.surface_add_vertex(_points[i] + side)
	_mesh.surface_end()


## The stroke colour in linear space (the renderer consumes material colours as
## linear), glow_energy times bright so it crosses the bloom threshold, with
## `fade` as the alpha.
func _hdr_colour(fade: float) -> Color:
	# No srgb_to_linear here: albedo_color is a source_color property, so the
	# engine converts it itself — converting first double-applied the transform
	# and the trail's hue differed between Forward+ and the web renderer.
	return Color(
		trail_colour.r * glow_energy, trail_colour.g * glow_energy,
		trail_colour.b * glow_energy, fade
	)
