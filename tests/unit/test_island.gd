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


func test_ground_normals_point_up() -> void:
	# Regression guard. The first build wound its triangles the wrong way round,
	# which culled the entire island as backfaces and left generate_normals()
	# pointing every normal at the sea floor. Nothing in the suite noticed —
	# only a screenshot did. Winding is invisible to every other assertion here,
	# so it gets its own.
	var mesh_instance: MeshInstance3D = _island.get_node_or_null(^"IslandMesh")
	assert_not_null(mesh_instance)
	if mesh_instance == null:
		return

	var arrays: Array = mesh_instance.mesh.surface_get_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	assert_gt(normals.size(), 0, "mesh should carry normals")

	var upward: int = 0
	for normal: Vector3 in normals:
		if normal.dot(Vector3.UP) > 0.0:
			upward += 1
	var fraction: float = float(upward) / float(normals.size())
	gut.p("normals facing up: %.1f%%" % (fraction * 100.0))
	assert_gt(fraction, 0.99, "ground normals should face the sky, not the sea floor")


func test_collision_heightfield_matches_the_rendered_heights() -> void:
	# If these ever diverge, things land on invisible ground.
	var collision: CollisionShape3D = _island.get_node_or_null(^"IslandBody/IslandCollision")
	var shape: HeightMapShape3D = collision.shape
	assert_eq(shape.map_width, _island.resolution)
	assert_eq(shape.map_depth, _island.resolution)
	assert_eq(shape.map_data, _island.get_heights())


# --- Surface materials --------------------------------------------------------

func test_a_cliff_and_a_meadow_at_the_same_height_look_different() -> void:
	# The assertion the old code could not pass. Colour was driven by altitude
	# alone, so a cliff face and a flat meadow at the same height came out the same
	# green and the island read as one smooth painted lump whatever its shape.
	var height: float = _island.height_scale * 0.4
	var flat: Color = _island._colour_for_surface(height, 0.02)
	var cliff: Color = _island._colour_for_surface(height, 0.95)

	gut.p("at height %.1f: flat %s vs steep %s" % [height, flat, cliff])
	var difference: float = (
		absf(flat.r - cliff.r) + absf(flat.g - cliff.g) + absf(flat.b - cliff.b)
	)
	assert_gt(difference, 0.05, "steep ground should be a different colour from flat ground")
	# Specifically: rock is greyer than grass, so the green channel must lose its lead.
	assert_gt(flat.g - flat.r, cliff.g - cliff.r,
		"a cliff should read as rock, meaning less green-dominant than a meadow")


func test_the_tideline_is_sandy_and_the_uplands_are_not() -> void:
	var beach: Color = _island._colour_for_surface(0.1, 0.05)
	var upland: Color = _island._colour_for_surface(_island.height_scale * 0.45, 0.05)
	gut.p("beach %s vs upland %s" % [beach, upland])
	assert_gt(beach.r, upland.r, "sand should be warmer than grass")
	assert_gt(beach.r, beach.g, "sand should be red-dominant, grass green-dominant")
	assert_gt(upland.g, upland.r, "upland grass should stay green")


func test_the_surface_blends_rather_than_banding() -> void:
	# Hard thresholds give contour bands, which read as a topographic map instead of
	# ground. Stepping across the sand boundary must be gradual.
	var previous: Color = _island._colour_for_surface(0.0, 0.05)
	var biggest_jump: float = 0.0
	for i in range(1, 40):
		var h: float = float(i) * 0.15
		var current: Color = _island._colour_for_surface(h, 0.05)
		biggest_jump = maxf(biggest_jump, absf(current.r - previous.r))
		previous = current
	gut.p("largest single-step colour jump across the tideline: %.4f" % biggest_jump)
	assert_lt(biggest_jump, 0.08, "a visible step here would appear as a contour line")


func test_steepness_reads_flat_ground_as_flat() -> void:
	# Sanity on the measurement itself, since every surface decision rests on it.
	var flattest: float = 1.0
	var steepest: float = 0.0
	for iz in range(1, _island.resolution - 1, 7):
		for ix in range(1, _island.resolution - 1, 7):
			var s: float = _island._steepness_at(ix, iz)
			assert_between(s, 0.0, 1.0, "steepness should stay normalised")
			flattest = minf(flattest, s)
			steepest = maxf(steepest, s)
	gut.p("steepness across the island: %.3f to %.3f" % [flattest, steepest])
	assert_lt(flattest, 0.1, "somewhere on the island should be nearly flat")
	assert_gt(steepest, 0.2, "and somewhere should be a real slope")
