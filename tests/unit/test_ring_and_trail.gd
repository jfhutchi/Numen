extends GutTest
## The influence ring's shader boundary and the world-space gesture trail.
##
## The assertion that matters most here: the ring's shader radius is the very
## number Influence.contains() compares against. The old TorusMesh scaled a
## separate copy of the radius, which is exactly the kind of second source of
## truth these tests exist to forbid.

const RING := preload("res://src/miracles/influence_ring.gd")
const TRAIL := preload("res://src/hand/gesture_trail.gd")


## Duck-typed stand-in for the island: just height_at. RefCounted so it cannot
## leak as an orphan.
class StubIsland:
	extends RefCounted
	var ground: float = 5.0

	func height_at(_x: float, _z: float) -> float:
		return ground


func _make_ring() -> InfluenceRing:
	var ring: InfluenceRing = RING.new()
	add_child_autofree(ring)
	return ring


func _make_trail() -> GestureTrail:
	var trail: GestureTrail = TRAIL.new()
	add_child_autofree(trail)
	return trail


# --- ring ---------------------------------------------------------------------

func test_set_radius_updates_shader_uniform_and_ribbon_together() -> void:
	# The disc predecessor scaled the node; the ribbon rebuilds geometry instead,
	# so the consistency that matters is uniform vs built mesh extent.
	var ring := _make_ring()
	ring.set_island(StubIsland.new())
	ring.set_radius(23.5)
	var material := ring.material_override as ShaderMaterial
	assert_eq(float(material.get_shader_parameter(&"radius")), 23.5,
		"the shader must draw the boundary at exactly the radius it was given")
	assert_eq(ring.built_radius(), 23.5, "the ribbon must be rebuilt for that radius")

	var aabb: AABB = ring.mesh.get_aabb()
	var cover: float = 23.5 + ring.edge_width
	assert_almost_eq(aabb.size.x, cover * 2.0, 0.5,
		"the ribbon must reach the radius plus the edge band or the boundary is clipped")
	assert_almost_eq(aabb.size.z, aabb.size.x, 0.5, "a circle, not an ellipse")


func test_the_ribbon_lies_on_the_terrain_not_the_sea() -> void:
	# The regression that forced the ribbon: the flat disc sat on the water plane
	# and the depth test let every hill occlude it, so the ring was invisible over
	# land — the one place the player acts. The ribbon must carry the ground's own
	# height in its vertices.
	var ring := _make_ring()
	var island := StubIsland.new()
	island.ground = 7.25
	ring.set_island(island)
	ring.set_radius(20.0)

	var aabb: AABB = ring.mesh.get_aabb()
	gut.p("ribbon sits at y %.2f over ground %.2f (hover %.2f)" % [
		aabb.position.y, island.ground, ring.hover_height
	])
	assert_almost_eq(aabb.position.y, island.ground + ring.hover_height, 0.01,
		"the ribbon must drape over the terrain, not float on the waterline")


func test_a_tiny_radius_change_does_not_rebuild() -> void:
	# Belief grows continuously; rebuilding thousands of vertices for a millimetre
	# of growth every frame is the waste rebuild_epsilon exists to stop.
	var ring := _make_ring()
	ring.set_island(StubIsland.new())
	ring.set_radius(30.0)
	var built: float = ring.built_radius()
	ring.set_radius(30.0 + ring.rebuild_epsilon * 0.5)
	assert_eq(ring.built_radius(), built, "a sub-epsilon change should keep the old ribbon")
	ring.set_radius(30.0 + ring.rebuild_epsilon * 2.0)
	assert_ne(ring.built_radius(), built, "a real change should rebuild")


func test_ring_boundary_is_the_number_influence_contains_flips_on() -> void:
	var influence := Influence.new()
	influence.set_belief(120.0)
	var ring := _make_ring()
	ring.set_radius(influence.radius)
	var material := ring.material_override as ShaderMaterial
	var drawn: float = float(material.get_shader_parameter(&"radius"))
	gut.p("influence radius %.2f, drawn radius %.2f" % [influence.radius, drawn])
	assert_eq(drawn, influence.radius, "one radius, two consumers — they must match")
	assert_true(influence.contains(Vector3(drawn - 0.01, 0.0, 0.0)),
		"just inside the drawn edge must be castable")
	assert_false(influence.contains(Vector3(drawn + 0.01, 0.0, 0.0)),
		"just outside the drawn edge must be refused")


func test_strength_clamps_to_unit_range() -> void:
	var ring := _make_ring()
	var material := ring.material_override as ShaderMaterial
	ring.set_strength(3.0)
	assert_eq(float(material.get_shader_parameter(&"strength")), 1.0,
		"strength above 1 clamps down")
	ring.set_strength(-2.0)
	assert_eq(float(material.get_shader_parameter(&"strength")), 0.0,
		"strength below 0 clamps up")
	ring.set_strength(0.4)
	assert_almost_eq(float(material.get_shader_parameter(&"strength")), 0.4, 0.0001,
		"in-range strength passes through untouched")


# --- trail --------------------------------------------------------------------

func test_trail_records_a_stroke_headless() -> void:
	var trail := _make_trail()
	trail.set_island(StubIsland.new())
	trail.begin()
	for i in 6:
		trail.extend(Vector3(float(i) * 2.0, 0.0, 0.0))
	assert_eq(trail.point_count(), 6, "six well-spaced points all survive")
	assert_gt((trail.mesh as ImmediateMesh).get_surface_count(), 0,
		"two or more points should have produced ribbon geometry")


func test_points_closer_than_min_spacing_are_merged() -> void:
	var trail := _make_trail()
	trail.set_island(StubIsland.new())
	trail.begin()
	trail.extend(Vector3.ZERO)
	for i in 20:
		trail.extend(Vector3(0.001 * float(i + 1), 0.0, 0.0))
	assert_eq(trail.point_count(), 1,
		"a jittering pointer must not balloon the ribbon it rebuilds every frame")


func test_end_stroke_fades_then_clears() -> void:
	var trail := _make_trail()
	trail.set_island(StubIsland.new())
	trail.begin()
	trail.extend(Vector3.ZERO)
	trail.extend(Vector3(2.0, 0.0, 0.0))
	trail.end_stroke()
	assert_eq(trail.point_count(), 2, "the ribbon lingers while it fades")
	trail.advance(trail.fade_time * 0.5)
	assert_eq(trail.point_count(), 2, "half the fade is not the whole fade")
	# The fade must actually be visible, not just a countdown: mid-fade the
	# material's alpha should sit near the halfway mark.
	var mid_alpha: float = (trail.material_override as StandardMaterial3D).albedo_color.a
	assert_between(mid_alpha, 0.2, 0.8, "mid-fade the ribbon should be part-faded, was %f" % mid_alpha)
	trail.advance(trail.fade_time)
	assert_eq(trail.point_count(), 0, "past the fade the stroke is gone")
	assert_eq((trail.mesh as ImmediateMesh).get_surface_count(), 0,
		"and so is its geometry")


func test_extend_snaps_to_terrain_plus_hover() -> void:
	var trail := _make_trail()
	var island := StubIsland.new()
	island.ground = 7.5
	trail.set_island(island)
	trail.begin()
	trail.extend(Vector3(3.0, 99.0, -4.0))
	assert_almost_eq(trail._points[0].y, 7.5 + trail.hover_height, 0.001,
		"the ribbon follows the ground, not the pointer's y")


func test_extend_over_the_sea_rides_the_waterline() -> void:
	var trail := _make_trail()
	var island := StubIsland.new()
	island.ground = -6.0
	trail.set_island(island)
	trail.begin()
	trail.extend(Vector3.ZERO)
	assert_almost_eq(trail._points[0].y, trail.hover_height, 0.001,
		"below the waterline the ribbon floats on the water, not the sea floor")
