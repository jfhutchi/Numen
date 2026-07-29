extends GutTest
## The world store, and the scatter that fills it.

const REGISTRY := preload("res://src/world/object_registry.gd")
const ISLAND := preload("res://src/world/island.gd")
const SCATTER := preload("res://src/world/scatter.gd")

var _registry: Node


func before_each() -> void:
	_registry = REGISTRY.new()
	autofree(_registry)


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
