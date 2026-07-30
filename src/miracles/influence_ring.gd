class_name InfluenceRing
extends MeshInstance3D
## The ring of divine influence, drawn as a ribbon that follows the ground.
##
## Two failed shapes preceded this one. The scaled TorusMesh had real thickness
## and intersected every hill it crossed as a flat blue band. Its replacement, a
## flat shader disc on the water plane, kept the depth test honest — and was
## therefore occluded by the terrain, which made the ring invisible over land,
## the one place the player actually acts. A circle painted on the world has to
## lie on the world: this ribbon samples the island's height around the boundary
## and drapes itself over the hills.
##
## The shader survives all of this unchanged. It draws the boundary from
## world-space XZ distance against a radius uniform, so it does not care what
## shape carries it; set_radius writes the same number Influence.radius holds,
## and the drawn edge sits exactly where Influence.contains() flips — one
## number, two consumers, no drift.

const RING_SHADER := preload("res://src/miracles/influence_ring.gdshader")

## Width of the bright boundary band, in metres.
@export var edge_width: float = 2.5
## Height above the ground, so slope between samples does not bury the ribbon.
@export var hover_height: float = 0.45
## How far inside the boundary the ribbon reaches, in metres. This is the bed
## the travelling pulse breathes across; the deep interior is deliberately
## unbuilt — a faint fill across the whole island would cost a triangulated
## disc for something barely visible.
@export var inner_reach: float = 16.0
## Metres of arc per segment. Terrain cells are 1.25 m, so 2.5 m steps track
## the ground closely enough that hover_height covers the sag between samples.
@export var arc_step: float = 2.5
## Radial rows across the ribbon, so it bends over ridges radially too.
@export var radial_rows: int = 6
## Radius or centre must move this far before the ribbon is rebuilt. Belief
## grows continuously, and rebuilding thousands of vertices for a millimetre of
## growth every frame would be pure waste.
@export var rebuild_epsilon: float = 0.3

var _material: ShaderMaterial = ShaderMaterial.new()
var _ribbon: ImmediateMesh = ImmediateMesh.new()
var _island: Object = null
var _radius: float = 1.0
var _built_radius: float = -1.0
var _built_centre: Vector3 = Vector3(INF, 0.0, INF)


func _init() -> void:
	name = "InfluenceRing"
	mesh = _ribbon
	_material.shader = RING_SHADER
	# Drawn after the water in the transparent pass. Both are transparent and
	# the water writes depth (depth_draw_always); losing this ordering lets the
	# sea erase the ring wherever the sort happens to disagree.
	_material.render_priority = 1
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_radius(1.0)
	set_strength(1.0)


## The ground the ribbon drapes over. Duck-typed: anything with height_at(x, z).
func set_island(island: Object) -> void:
	_island = island
	_built_radius = -1.0
	_maybe_rebuild()


## Sets the influence radius in metres — pass Influence.radius, nothing derived.
func set_radius(r: float) -> void:
	_radius = maxf(r, 0.0)
	_material.set_shader_parameter(&"radius", _radius)
	_material.set_shader_parameter(&"edge_width", edge_width)
	_maybe_rebuild()


## Moves the ring. The node sits at the centre — the shader reads the centre
## from MODEL_MATRIX, so there is no separate uniform to forget — and vertices
## carry the terrain height, so the node itself stays at y = 0.
func set_centre(c: Vector3) -> void:
	var flat := Vector3(c.x, 0.0, c.z)
	if is_inside_tree():
		global_position = flat
	else:
		position = flat
	_maybe_rebuild()


## How decisively the player may act, 0..1; drives the ring's brightness.
func set_strength(s: float) -> void:
	_material.set_shader_parameter(&"strength", clampf(s, 0.0, 1.0))


## The radius the ribbon was last built at, for tests and the rebuild guard.
func built_radius() -> float:
	return _built_radius


func _centre_now() -> Vector3:
	return global_position if is_inside_tree() else position


func _maybe_rebuild() -> void:
	var centre: Vector3 = _centre_now()
	if (
		absf(_radius - _built_radius) < rebuild_epsilon
		and centre.distance_to(_built_centre) < rebuild_epsilon
	):
		return
	_rebuild(centre)


## Rebuilds the ribbon: an annulus from inner_reach inside the boundary to just
## past it, each vertex dropped onto the terrain. Local XZ, world height.
func _rebuild(centre: Vector3) -> void:
	_built_radius = _radius
	_built_centre = centre
	_ribbon.clear_surfaces()
	if _radius <= 0.05:
		return

	var outer: float = _radius + edge_width
	var inner: float = maxf(_radius - inner_reach, 0.5)
	var segments: int = clampi(int(TAU * outer / maxf(arc_step, 0.5)), 48, 320)
	var rows: int = maxi(radial_rows, 1)

	for row in rows:
		var r0: float = lerpf(inner, outer, float(row) / float(rows))
		var r1: float = lerpf(inner, outer, float(row + 1) / float(rows))
		_ribbon.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for seg in segments + 1:
			var angle: float = TAU * float(seg) / float(segments)
			var direction := Vector2(cos(angle), sin(angle))
			_ribbon.surface_add_vertex(_ground_vertex(centre, direction * r1))
			_ribbon.surface_add_vertex(_ground_vertex(centre, direction * r0))
		_ribbon.surface_end()


## A vertex at a local XZ offset, lifted to the terrain under it. Over the sea
## it rides the waterline, same as the gesture trail.
func _ground_vertex(centre: Vector3, offset: Vector2) -> Vector3:
	var height: float = 0.0
	if _island != null and _island.has_method("height_at"):
		height = maxf(float(_island.height_at(centre.x + offset.x, centre.z + offset.y)), 0.0)
	return Vector3(offset.x, height + hover_height, offset.y)
