extends Node3D
## Scatters trees and rocks over the island's dry land.
##
## Scenery is drawn with MultiMesh and carries no physics body — a body is
## promoted only when something actually picks the object up. That keeps a few
## hundred props at three draw calls.
##
## Trees are two MultiMeshes (trunk and canopy) sharing an instance index, which
## avoids hand-authoring a combined mesh just to get two colours.
##
## This node keeps its own authoritative copy of every instance transform and
## treats the MultiMesh as write-only. Two reasons: reading transforms back out
## of the rendering server is a stall, and under `--headless` the dummy renderer
## discards the data entirely, so `get_instance_transform` returns identity and
## nothing about placement could be tested.

const RNG_STREAM := &"world"
const TYPE_TREE := &"tree"
const TYPE_ROCK := &"rock"
## Scale applied to an instance to make it vanish while it is being carried.
const HIDDEN_SCALE := Vector3(0.0001, 0.0001, 0.0001)

@export var tree_count: int = 200
@export var rock_count: int = 80
## Trees avoid the tideline and the bare peaks.
@export var tree_min_height: float = 1.5
@export var tree_max_height: float = 15.0
@export var rock_min_height: float = 0.3
@export var rock_max_height: float = 22.0
@export var placement_attempts_per_item: int = 24

var _trunks: MultiMeshInstance3D
var _canopies: MultiMeshInstance3D
var _rocks: MultiMeshInstance3D

# Authoritative state, keyed by WorldObject id.
var _body_rest: Dictionary[int, Transform3D] = {}
var _canopy_rest: Dictionary[int, Transform3D] = {}
var _hidden: Dictionary[int, bool] = {}


## Fills the island with scenery and registers every piece in the world store.
func populate(island: Node3D, registry: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed()

	var tree_spots: Array[Vector3] = _pick_spots(
		island, rng, tree_count, tree_min_height, tree_max_height
	)
	var rock_spots: Array[Vector3] = _pick_spots(
		island, rng, rock_count, rock_min_height, rock_max_height
	)

	_trunks = _make_multimesh(
		"Trunks", _trunk_mesh(), _colour_material(Color(0.32, 0.22, 0.14)), tree_spots.size()
	)
	_canopies = _make_multimesh(
		"Canopies", _canopy_mesh(), _colour_material(Color(0.20, 0.42, 0.18)), tree_spots.size()
	)
	_rocks = _make_multimesh(
		"Rocks", _rock_mesh(), _colour_material(Color(0.48, 0.47, 0.45)), rock_spots.size()
	)

	for i in tree_spots.size():
		var trunk_height: float = rng.randf_range(3.0, 6.0)
		var yaw: float = rng.randf_range(0.0, TAU)
		var canopy_scale: float = rng.randf_range(1.6, 2.4)
		var object: WorldObject = registry.add(TYPE_TREE, tree_spots[i], null, i)

		_body_rest[object.id] = Transform3D(
			Basis(Vector3.UP, yaw).scaled(Vector3(1.0, trunk_height, 1.0)), tree_spots[i]
		)
		_canopy_rest[object.id] = Transform3D(
			Basis(Vector3.UP, yaw).scaled(
				Vector3(canopy_scale, canopy_scale * 0.85, canopy_scale)
			),
			tree_spots[i] + Vector3.UP * trunk_height * 0.95
		)
		_hidden[object.id] = false
		_push(object)

	for i in rock_spots.size():
		var scale := Vector3(
			rng.randf_range(0.5, 1.4), rng.randf_range(0.4, 1.0), rng.randf_range(0.5, 1.4)
		)
		var object: WorldObject = registry.add(TYPE_ROCK, rock_spots[i], null, i)
		_body_rest[object.id] = Transform3D(
			Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(scale),
			rock_spots[i] + Vector3.UP * scale.y * 0.35
		)
		_hidden[object.id] = false
		_push(object)


## Hides an object's instance because something has picked it up.
func hide_instance(object: WorldObject) -> void:
	if not _body_rest.has(object.id):
		return
	_hidden[object.id] = true
	_push(object)


## Puts an object back into the MultiMesh at a new resting place.
func restore_instance(object: WorldObject, at: Vector3) -> void:
	if not _body_rest.has(object.id):
		return
	var body: Transform3D = _body_rest[object.id]
	var lift: float = 0.0
	if _canopy_rest.has(object.id):
		lift = _canopy_rest[object.id].origin.y - body.origin.y
	_body_rest[object.id] = Transform3D(body.basis, at)
	if _canopy_rest.has(object.id):
		var canopy: Transform3D = _canopy_rest[object.id]
		_canopy_rest[object.id] = Transform3D(canopy.basis, at + Vector3.UP * lift)
	_hidden[object.id] = false
	object.position = at
	_push(object)


## True while this object is being carried rather than drawn in place.
func is_hidden(object: WorldObject) -> bool:
	return _hidden.get(object.id, false)


## The transform this object is currently drawn with — authoritative, and safe
## to assert against in headless tests.
func visual_transform(object: WorldObject) -> Transform3D:
	var rest: Transform3D = _body_rest.get(object.id, Transform3D.IDENTITY)
	if _hidden.get(object.id, false):
		return Transform3D(rest.basis.orthonormalized().scaled(HIDDEN_SCALE), rest.origin)
	return rest


func rest_transform_of(object: WorldObject) -> Transform3D:
	return _body_rest.get(object.id, Transform3D.IDENTITY)


## Collision shape radius that roughly bounds this prop, for the physics proxy.
func detached_extents(object: WorldObject) -> Vector3:
	var rest: Transform3D = _body_rest.get(object.id, Transform3D.IDENTITY)
	var scale: Vector3 = rest.basis.get_scale()
	if object.type == TYPE_TREE:
		return Vector3(0.5, maxf(scale.y, 1.0) * 0.5, 0.5)
	return Vector3(0.8, 0.7, 0.8) * scale


## Visual for a detached, physically simulated copy of this prop.
func build_detached_visual(object: WorldObject) -> Node3D:
	var holder := Node3D.new()
	var scale: Vector3 = _body_rest.get(object.id, Transform3D.IDENTITY).basis.get_scale()
	if object.type == TYPE_TREE:
		var height: float = maxf(scale.y, 1.0)
		var trunk := MeshInstance3D.new()
		trunk.mesh = _trunk_mesh()
		trunk.scale = Vector3(1.0, height, 1.0)
		trunk.material_override = _colour_material(Color(0.32, 0.22, 0.14))
		holder.add_child(trunk)
		var canopy := MeshInstance3D.new()
		canopy.mesh = _canopy_mesh()
		canopy.scale = _canopy_rest.get(object.id, Transform3D.IDENTITY).basis.get_scale()
		canopy.position = Vector3.UP * height * 0.95
		canopy.material_override = _colour_material(Color(0.20, 0.42, 0.18))
		holder.add_child(canopy)
	else:
		var rock := MeshInstance3D.new()
		rock.mesh = _rock_mesh()
		rock.scale = scale
		rock.material_override = _colour_material(Color(0.48, 0.47, 0.45))
		holder.add_child(rock)
	return holder


## Writes this object's current transforms into the rendering server.
func _push(object: WorldObject) -> void:
	var hidden: bool = _hidden.get(object.id, false)
	var body: Transform3D = _body_rest.get(object.id, Transform3D.IDENTITY)
	if object.type == TYPE_TREE:
		_write(_trunks, object.multimesh_index, body, hidden)
		_write(_canopies, object.multimesh_index, _canopy_rest.get(object.id, body), hidden)
	else:
		_write(_rocks, object.multimesh_index, body, hidden)


func _write(
	instance: MultiMeshInstance3D, index: int, transform: Transform3D, hidden: bool
) -> void:
	if not _instance_valid(instance, index):
		return
	var final := transform
	if hidden:
		final = Transform3D(transform.basis.orthonormalized().scaled(HIDDEN_SCALE), transform.origin)
	instance.multimesh.set_instance_transform(index, final)


func _instance_valid(instance: MultiMeshInstance3D, index: int) -> bool:
	return (
		instance != null
		and instance.multimesh != null
		and index >= 0
		and index < instance.multimesh.instance_count
	)


func _pick_spots(
	island: Node3D, rng: RandomNumberGenerator, wanted: int, min_h: float, max_h: float
) -> Array[Vector3]:
	var spots: Array[Vector3] = []
	var half: float = island.extent * 0.5 * 0.94
	for i in wanted:
		for attempt in placement_attempts_per_item:
			var x: float = rng.randf_range(-half, half)
			var z: float = rng.randf_range(-half, half)
			var h: float = island.height_at(x, z)
			if h >= min_h and h <= max_h:
				spots.append(Vector3(x, h, z))
				break
	return spots


func _make_multimesh(
	node_name: String, mesh: Mesh, material: Material, instances: int
) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	# transform_format must be set while instance_count is still 0; the engine
	# refuses the change afterwards and silently leaves the mesh in 2D mode.
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = instances
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	add_child(instance)
	return instance


func _trunk_mesh() -> Mesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.18
	mesh.bottom_radius = 0.3
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.rings = 1
	return mesh


func _canopy_mesh() -> Mesh:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 7
	mesh.rings = 4
	return mesh


func _rock_mesh() -> Mesh:
	var mesh := SphereMesh.new()
	mesh.radius = 0.8
	mesh.height = 1.4
	mesh.radial_segments = 6
	mesh.rings = 3
	return mesh


func _colour_material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.9
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material


func _seed() -> int:
	if is_inside_tree():
		var rng_service: Node = get_node_or_null(^"/root/Rng")
		if rng_service != null:
			return rng_service.derive_seed(RNG_STREAM)
	return hash("numen:scatter")
