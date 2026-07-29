extends GutTest
## Island generation: determinism, island-shaped-ness, and a usable ground query.

const ISLAND := preload("res://src/world/island.gd")
const SEED := 20260729

var _island: Node3D


func before_each() -> void:
	_island = ISLAND.new()
	add_child_autofree(_island)
	_island.generate(SEED)


func test_heightmap_has_the_expected_sample_count() -> void:
	assert_eq(_island.get_heights().size(), _island.resolution * _island.resolution)


func test_generation_is_deterministic_for_a_seed() -> void:
	var other: Node3D = ISLAND.new()
	add_child_autofree(other)
	other.generate(SEED)
	assert_eq(other.get_heights(), _island.get_heights(),
		"the same seed must produce the same island")


func test_different_seeds_produce_different_islands() -> void:
	var other: Node3D = ISLAND.new()
	add_child_autofree(other)
	other.generate(SEED + 1)
	assert_ne(other.get_heights(), _island.get_heights())


func test_centre_is_land_and_edges_are_submerged() -> void:
	# The radial falloff is what makes this an island rather than an open field.
	assert_true(_island.is_land(0.0, 0.0), "the middle of the island should be dry land")

	var half: float = _island.extent * 0.5
	for corner: Vector2 in [
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(-half, half), Vector2(half, half),
	]:
		assert_lt(_island.height_at(corner.x, corner.y), 0.0,
			"corner %s should be below the waterline" % corner)


func test_height_query_outside_bounds_returns_sea_floor() -> void:
	var far: float = _island.extent * 5.0
	assert_eq(_island.height_at(far, far), -_island.sea_floor_depth)


func test_height_query_interpolates_between_samples() -> void:
	# A midpoint between two samples must not simply snap to one of them,
	# otherwise anything placed on the ground will visibly step.
	var step: float = _island.cell_size()
	var half: float = _island.extent * 0.5
	var a: float = _island.height_at(-half + step * 10.0, -half + step * 10.0)
	var b: float = _island.height_at(-half + step * 11.0, -half + step * 10.0)
	var mid: float = _island.height_at(-half + step * 10.5, -half + step * 10.0)
	if is_equal_approx(a, b):
		pass_test("adjacent samples are level here; nothing to interpolate")
		return
	assert_between(mid, minf(a, b), maxf(a, b),
		"midpoint height should lie between its neighbouring samples")
	assert_ne(mid, a)
	assert_ne(mid, b)


func test_mesh_and_collision_are_built() -> void:
	var mesh_instance: MeshInstance3D = _island.get_node_or_null(^"IslandMesh")
	assert_not_null(mesh_instance, "island should build a mesh")
	assert_not_null(mesh_instance.mesh)
	assert_gt(mesh_instance.mesh.get_surface_count(), 0)

	var collision: CollisionShape3D = _island.get_node_or_null(^"IslandBody/IslandCollision")
	assert_not_null(collision, "island should build collision")
	assert_true(collision.shape is HeightMapShape3D,
		"expected a height-field shape, not a fallback")


func test_collision_heightfield_matches_the_rendered_heights() -> void:
	# If these ever diverge, things land on invisible ground.
	var collision: CollisionShape3D = _island.get_node_or_null(^"IslandBody/IslandCollision")
	var shape: HeightMapShape3D = collision.shape
	assert_eq(shape.map_width, _island.resolution)
	assert_eq(shape.map_depth, _island.resolution)
	assert_eq(shape.map_data, _island.get_heights())
