extends GutTest
## The world store, and the scatter that fills it.

const REGISTRY := preload("res://src/world/object_registry.gd")
const ISLAND := preload("res://src/world/island.gd")
const SCATTER := preload("res://src/world/scatter.gd")
## Asserted against below. Absent in a checkout without the generated assets, in
## which case the scatter falls back to primitives of a different size.
const TREE_SCENE := "res://assets/procedural/meshes/tree.glb"

var _registry: Node


func before_each() -> void:
	_registry = REGISTRY.new()
	autofree(_registry)


## An island with scenery scattered over it. Both are freed with the test.
func _populated_scatter(trees: int, rocks: int) -> Node3D:
	var island: Node3D = ISLAND.new()
	add_child_autofree(island)
	island.generate(20260729)

	var scatter: Node3D = SCATTER.new()
	scatter.tree_count = trees
	scatter.rock_count = rocks
	add_child_autofree(scatter)
	scatter.populate(island, _registry)
	return scatter


func test_added_objects_get_unique_ids() -> void:
	var a: WorldObject = _registry.add(&"tree", Vector3.ZERO)
	var b: WorldObject = _registry.add(&"rock", Vector3.ONE)
	assert_ne(a.id, b.id)
	assert_eq(_registry.count(), 2)


func test_removed_objects_are_marked_dead_and_ids_are_not_reused() -> void:
	var a: WorldObject = _registry.add(&"tree", Vector3.ZERO)
	_registry.remove(a.id)
	assert_false(a.alive, "removed objects should be flagged, not silently dropped")
	assert_null(_registry.get_object(a.id))

	var b: WorldObject = _registry.add(&"rock", Vector3.ZERO)
	assert_ne(b.id, a.id, "reusing an id would alias anything still holding the old one")


func test_query_near_respects_radius() -> void:
	_registry.add(&"tree", Vector3(0.0, 0.0, 0.0))
	_registry.add(&"tree", Vector3(5.0, 0.0, 0.0))
	_registry.add(&"tree", Vector3(50.0, 0.0, 0.0))
	assert_eq(_registry.query_near(Vector3.ZERO, 10.0).size(), 2)
	assert_eq(_registry.query_near(Vector3.ZERO, 100.0).size(), 3)


func test_query_near_filters_by_type() -> void:
	_registry.add(&"tree", Vector3.ZERO)
	_registry.add(&"rock", Vector3.ZERO)
	_registry.add(&"villager", Vector3.ZERO)
	var found: Array[WorldObject] = _registry.query_near(Vector3.ZERO, 10.0, [&"rock", &"villager"])
	assert_eq(found.size(), 2)
	for object: WorldObject in found:
		assert_ne(object.type, &"tree")


func test_nearest_picks_the_closest() -> void:
	_registry.add(&"tree", Vector3(9.0, 0.0, 0.0))
	var close: WorldObject = _registry.add(&"tree", Vector3(2.0, 0.0, 0.0))
	assert_eq(_registry.nearest(Vector3.ZERO, 20.0).id, close.id)


func test_nearest_returns_null_when_nothing_is_in_range() -> void:
	_registry.add(&"tree", Vector3(100.0, 0.0, 0.0))
	assert_null(_registry.nearest(Vector3.ZERO, 5.0))


func test_queries_track_a_live_node_rather_than_the_spawn_position() -> void:
	# A thrown rock must be found where it landed, not where it grew.
	var node := Node3D.new()
	add_child_autofree(node)
	var object: WorldObject = _registry.add(&"rock", Vector3.ZERO, node)
	node.global_position = Vector3(30.0, 0.0, 0.0)
	assert_null(_registry.nearest(Vector3.ZERO, 5.0), "stale spawn position should not match")
	assert_not_null(_registry.nearest(Vector3(30.0, 0.0, 0.0), 5.0))


func test_scatter_places_props_on_dry_land_and_registers_them() -> void:
	var island: Node3D = ISLAND.new()
	add_child_autofree(island)
	island.generate(20260729)

	var scatter: Node3D = SCATTER.new()
	scatter.tree_count = 40
	scatter.rock_count = 20
	add_child_autofree(scatter)
	scatter.populate(island, _registry)

	assert_gt(_registry.count(), 0, "scatter should register what it places")

	for object: WorldObject in _registry.all():
		var ground: float = island.height_at(object.position.x, object.position.z)
		assert_gt(ground, 0.0, "%s was placed below the waterline" % object)
		assert_almost_eq(object.position.y, ground, 0.01,
			"%s should sit on the ground, not float or sink" % object)


func test_hiding_a_scattered_instance_shrinks_it_away() -> void:
	# Carrying an object must remove it from the MultiMesh, or the player sees a
	# ghost copy still standing where they picked it up.
	var island: Node3D = ISLAND.new()
	add_child_autofree(island)
	island.generate(20260729)

	var scatter: Node3D = SCATTER.new()
	scatter.tree_count = 10
	scatter.rock_count = 10
	add_child_autofree(scatter)
	scatter.populate(island, _registry)

	var rocks: Array[WorldObject] = _registry.query_near(Vector3.ZERO, 10000.0, [&"rock"])
	assert_gt(rocks.size(), 0, "expected the scatter to place some rocks")
	if rocks.is_empty():
		return

	# Asserted against the scatter's own authoritative transforms, not read back
	# from the MultiMesh: under --headless the dummy renderer discards instance
	# data and get_instance_transform always returns identity.
	var target: WorldObject = rocks[0]
	var before: Vector3 = scatter.visual_transform(target).basis.get_scale()
	assert_false(scatter.is_hidden(target))

	scatter.hide_instance(target)
	var after: Vector3 = scatter.visual_transform(target).basis.get_scale()

	assert_true(scatter.is_hidden(target))
	assert_gt(before.length(), after.length(), "hidden instance should shrink away")
	assert_lt(after.length(), 0.01)


func test_restoring_a_carried_prop_puts_it_back_where_it_was_dropped() -> void:
	var island: Node3D = ISLAND.new()
	add_child_autofree(island)
	island.generate(20260729)

	var scatter: Node3D = SCATTER.new()
	scatter.tree_count = 10
	scatter.rock_count = 10
	add_child_autofree(scatter)
	scatter.populate(island, _registry)

	var trees: Array[WorldObject] = _registry.query_near(Vector3.ZERO, 10000.0, [&"tree"])
	assert_gt(trees.size(), 0)
	if trees.is_empty():
		return

	var target: WorldObject = trees[0]
	var original_scale: Vector3 = scatter.visual_transform(target).basis.get_scale()
	scatter.hide_instance(target)

	var dropped_at := Vector3(11.0, 4.0, -6.0)
	scatter.restore_instance(target, dropped_at)

	assert_false(scatter.is_hidden(target), "restored prop should be drawn again")
	assert_eq(scatter.visual_transform(target).origin, dropped_at)
	assert_almost_eq(
		scatter.visual_transform(target).basis.get_scale().y, original_scale.y, 0.001,
		"a carried tree should not change size on the way back down"
	)
	assert_eq(target.position, dropped_at, "the world record should follow the prop")


func test_each_prop_type_draws_from_a_single_multimesh() -> void:
	# Trees used to be two MultiMeshes, a trunk and a canopy sharing an instance
	# index, because a primitive carries one colour. tree.glb is one joined mesh
	# with a material slot per part, so a second batch is pure overhead.
	var scatter: Node3D = _populated_scatter(30, 15)

	var batches: Array[String] = []
	for child: Node in scatter.get_children():
		if child is MultiMeshInstance3D:
			var multimesh: MultiMesh = (child as MultiMeshInstance3D).multimesh
			var mesh: Mesh = multimesh.mesh
			batches.append("%s(%d instances, %d surfaces)" % [
				child.name, multimesh.instance_count,
				0 if mesh == null else mesh.get_surface_count()
			])
	gut.p("scatter MultiMeshInstance3D count = %d: %s" % [batches.size(), ", ".join(batches)])

	assert_eq(batches.size(), 2, "one MultiMesh per prop type: trees and rocks")


func test_a_carried_tree_is_built_from_the_tree_mesh_at_its_real_size() -> void:
	var scatter: Node3D = _populated_scatter(20, 5)
	var trees: Array[WorldObject] = _registry.query_near(Vector3.ZERO, 10000.0, [&"tree"])
	assert_gt(trees.size(), 0, "expected the scatter to place some trees")
	if trees.is_empty():
		return
	var target: WorldObject = trees[0]

	var visual: Node3D = scatter.build_detached_visual(target)
	autofree(visual)
	var drawn: Array[Node] = visual.find_children("*", "MeshInstance3D", true, false)
	var bounds := AABB()
	var surfaces: int = 0
	for node: Node in drawn:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		surfaces += mesh.get_surface_count()
		bounds = bounds.merge((node as MeshInstance3D).transform * mesh.get_aabb())
	gut.p("carried tree visual: %d MeshInstance3D, %d surfaces, bounds %s" % [
		drawn.size(), surfaces, bounds.size
	])

	assert_eq(drawn.size(), 1, "a carried tree should be one mesh, not a trunk plus a canopy")
	assert_gt(surfaces, 0, "a carried tree with no surfaces would be invisible")
	# Loose on purpose: the primitive fallback trunk is under a metre tall.
	assert_gt(bounds.size.y, 0.5, "and an empty mesh would have no extent at all")

	# The hand builds the grabbed body's box from these, so they have to describe
	# the mesh rather than the primitive that used to stand in for it.
	var scale: float = scatter.visual_transform(target).basis.get_scale().y
	var extents: Vector3 = scatter.detached_extents(target)
	var size: Vector3 = extents * 2.0 / scale
	gut.p("tree instance scale %.3f, half-extents %s, unscaled mesh size %s" % [
		scale, extents, size
	])
	if not ResourceLoader.exists(TREE_SCENE):
		pass_test("tree.glb is not in this checkout; the primitive fallback is in use")
		return
	assert_almost_eq(size.x, 2.36, 0.05, "collision width should match tree.glb")
	assert_almost_eq(size.y, 5.15, 0.05, "collision height should match tree.glb")
	assert_almost_eq(size.z, 2.21, 0.05, "collision depth should match tree.glb")


func test_scattered_trees_vary_in_scale_and_yaw() -> void:
	# A forest stamped from one transform is the failure this guards: every tree
	# the same size, all facing the same way.
	var scatter: Node3D = _populated_scatter(40, 5)
	var trees: Array[WorldObject] = _registry.query_near(Vector3.ZERO, 10000.0, [&"tree"])
	assert_gt(trees.size(), 1, "need at least two trees to compare")
	if trees.size() < 2:
		return

	var scales: Array[float] = []
	var yaws: Array[float] = []
	for tree: WorldObject in trees:
		var basis: Basis = scatter.visual_transform(tree).basis
		scales.append(basis.get_scale().y)
		# Read off the facing vector rather than get_euler(), which assumes an
		# orthonormal basis this one is not.
		var facing: Vector3 = (basis * Vector3.FORWARD).normalized()
		yaws.append(atan2(facing.x, facing.z))
	scales.sort()
	yaws.sort()

	var scale_spread: float = scales[scales.size() - 1] - scales[0]
	var yaw_spread: float = yaws[yaws.size() - 1] - yaws[0]
	gut.p("%d trees: scale %.3f..%.3f (spread %.3f), yaw %.2f..%.2f rad (spread %.2f)" % [
		trees.size(), scales[0], scales[scales.size() - 1], scale_spread,
		yaws[0], yaws[yaws.size() - 1], yaw_spread
	])

	assert_gt(scale_spread, 0.05, "instances should differ in size")
	assert_gt(yaw_spread, 0.5, "instances should differ in yaw")
