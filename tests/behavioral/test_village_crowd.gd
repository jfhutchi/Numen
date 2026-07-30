extends GutTest
## The draw-call half of the village's Definition of Done: two hundred villagers at
## sixty frames a second.
##
## Frame rate itself needs a real renderer, so what this file measures is the thing
## that makes it possible. Every villager used to be its own MeshInstance3D, which
## put two hundred draw calls on the frame before the island had been drawn; they
## are now one MultiMesh, and the numbers printed below are the evidence for that
## claim — how many mesh nodes a populated village creates, and how long one step of
## its simulation takes against a 60 fps frame.
##
## The MultiMesh is write-only: under --headless the dummy renderer throws instance
## data away and get_instance_transform() returns identity, so everything asserted
## about placement here goes through Village.villager_instance_transform(), which is
## the village's own authoritative copy. Same rule as src/world/scatter.gd.

const ISLAND := preload("res://src/world/island.gd")
const REGISTRY := preload("res://src/world/object_registry.gd")
const VILLAGE := preload("res://src/village/village.gd")
const TUNABLES := preload("res://src/village/village_tunables.gd")

const SEED := 20260729
## The Definition of Done figure.
const CROWD := 200
## Matches the default decision interval, as in test_village_sim.gd.
const STEP := 0.2
## A hidden instance is scaled to Village.HIDDEN_SCALE, so anything with a basis
## bigger than this is standing at something like full size.
const VISIBLE_SCALE := 0.01

var _island: Node3D
var _registry: Node
var _village: Node3D


func before_all() -> void:
	# One heightmap for the file: it is the most expensive thing here and nothing in
	# the village writes to it. Freed by hand because GUT's queue is per test.
	_island = ISLAND.new()
	_island.generate(SEED)


func after_all() -> void:
	if _island != null and is_instance_valid(_island):
		_island.free()
		_island = null


func before_each() -> void:
	_registry = REGISTRY.new()
	autofree(_registry)
	_village = VILLAGE.new()
	# The test drives the clock, so the frame loop cannot advance the village
	# between tests and make the run unreproducible.
	_village.auto_simulate = false
	add_child_autofree(_village)


func test_two_hundred_villagers_draw_as_one_multimesh() -> void:
	# Two hundred founders bunch up on one ring — _founder_spot() puts them all at
	# half the house radius. In the game a village reaches two hundred by breeding,
	# which scatters each newborn around its parent; opening with two hundred is
	# just the cheapest way to get the population under test.
	_populate(_tunables_for(CROWD, CROWD))
	assert_eq(_village.population(), CROWD, "the village should have opened with two hundred")

	var batches: Array[MultiMeshInstance3D] = _multimeshes(_village)
	var meshes: int = _mesh_instances(_village)
	var buildings: int = _village.houses().size() + _village.fields().size() + 1

	gut.p("%d villagers: %d MultiMesh(es), %d MeshInstance3D node(s)" % [
		_village.population(), batches.size(), meshes
	])
	gut.p("those %d are %d building(s) and the desire indicator; a node per villager as before" % [
		meshes, buildings
	])
	gut.p("would have made it %d, so this is where the draw calls for 200 villagers went" % [
		meshes + _village.population()
	])

	assert_eq(batches.size(), 1, "the whole population has to be one draw batch")
	var multimesh: MultiMesh = batches[0].multimesh
	gut.p("the batch holds %d instances, %d of them drawn, over a mesh of %d surface(s)" % [
		multimesh.instance_count, _village.villager_instances_drawn(),
		multimesh.mesh.get_surface_count()
	])
	assert_gte(multimesh.instance_count, CROWD, "with room for every villager in it")
	assert_eq(_village.villager_instances_drawn(), CROWD, "and every villager drawn in one")
	assert_eq(multimesh.transform_format, MultiMesh.TRANSFORM_3D,
		"a 2D transform format is the silent failure: it is refused after the first instance")
	assert_true(multimesh.use_colors, "the job colour is carried per instance")
	# The other half of that, and the half nothing else would catch: a per-instance
	# colour only reaches albedo through a material that reads vertex colour.
	# Without the flag every villager renders white and the job colouring is gone.
	var skin: StandardMaterial3D = batches[0].material_override
	assert_not_null(skin, "the villager batch needs a material of its own")
	assert_true(skin.vertex_color_use_as_albedo,
		"without this the per-instance job colour is silently ignored and all villagers are white")

	# The claim itself: mesh nodes must not scale with the population. The same
	# village with eight people instead of two hundred has to create exactly the same
	# nodes, which cannot be true if any of them is per-villager.
	var small: Node3D = _second_village(_tunables_for(8, CROWD))
	gut.p("the same village with 8 people instead of %d: %d MultiMesh(es), %d mesh node(s)" % [
		CROWD, _multimeshes(small).size(), _mesh_instances(small)
	])
	assert_eq(_multimeshes(small).size(), 1)
	assert_eq(_mesh_instances(small), meshes,
		"mesh nodes moved with the population, so something is still per-villager")

	# The simulation half of the frame budget, measured. The render half is the
	# draw-call count above, which needs a real renderer to time.
	var steps: int = int(60.0 / STEP)
	var started: int = Time.get_ticks_usec()
	for step in steps:
		_village.simulate(STEP)
	var per_step: float = float(Time.get_ticks_usec() - started) / float(steps)

	gut.p("simulate() over %d villagers costs %.0f us a step, against 16667 us of a 60 fps frame"
		% [_village.population(), per_step])
	gut.p("after 60s: pop %d, %d houses, %d fields, desire '%s', %d instances drawn" % [
		_village.population(), _village.houses().size(), _village.fields().size(),
		_village.current_desire(), _village.villager_instances_drawn()
	])
	assert_lt(per_step, 16667.0, "one step of village life has to fit inside a frame")
	# Growth is at the ceiling, so nobody may be born, and sixty seconds is far short
	# of starving anyone: the population under test is the population all the way.
	assert_eq(_village.population(), CROWD, "the timed run has to be the crowd, not a remnant")


func test_the_villager_instances_track_births_and_deaths() -> void:
	# Beds and larder well clear of the ceiling, because can_birth() gates on housing
	# and food as well as on max_population, and the default village opens with
	# exactly as many people as it has beds.
	var tunables: VillageTunables = _tunables_for(8, CROWD)
	tunables.starting_houses = 8
	tunables.starting_food = 200.0
	_populate(tunables)

	var capacity: int = _multimeshes(_village)[0].multimesh.instance_count
	assert_eq(capacity, CROWD, "the buffer is allocated at the ceiling, once")
	assert_eq(_village.villager_instances_drawn(), 8, "eight villagers, eight instances")
	_assert_nothing_standing_above(8, capacity)

	# A birth, through the village's own seam and delivered inside simulate().
	_village.request_birth(_village.villagers()[0])
	_village.simulate(STEP)
	var newborn_index: int = _village.population() - 1
	var newborn: Villager = _village.villagers()[newborn_index]
	var newborn_drawn: Transform3D = _village.villager_instance_transform(newborn_index)

	assert_eq(_village.population(), 9, "the birth should have been delivered")
	assert_eq(_village.villager_instances_drawn(), 9, "and taken the next instance")
	assert_almost_eq(newborn_drawn.origin.distance_to(newborn.position), 0.0, 0.001,
		"instance %d is drawn %.3f m from the newborn it belongs to" % [
			newborn_index, newborn_drawn.origin.distance_to(newborn.position)
		])
	assert_gt(newborn_drawn.basis.get_scale().length(), VISIBLE_SCALE,
		"a newborn taking over a hidden instance has to be scaled back up to visible")
	_assert_nothing_standing_above(9, capacity)

	# And a death, through the one path there is. Advanced by hand rather than by
	# simulate() because the village's own farmers refill an emptied store in about
	# nine seconds, so there is no way to hold a famine open through the loop.
	var doomed: Villager = _village.villagers()[0]
	doomed.needs[Villager.FOOD] = 1.0
	for second in int(_village.tunables.starve_seconds * 1.2):
		doomed.advance(1.0)
	assert_false(doomed.alive, "the test never actually starved anybody")
	_village.simulate(STEP)

	gut.p("population 8 -> 9 -> %d, instances drawn %d of a %d-instance buffer" % [
		_village.population(), _village.villager_instances_drawn(), capacity
	])
	gut.p("instance %d after the funeral: scale %.5f, which is hidden below %.2f" % [
		8, _village.villager_instance_transform(8).basis.get_scale().length(), VISIBLE_SCALE
	])
	assert_eq(_village.population(), 8, "the corpse should have been reaped")
	assert_eq(_village.villager_instances_drawn(), 8, "and its instance given up")
	# The ghost check. Instance 8 drew somebody a step ago; leaving it where it was is
	# how a dead villager goes on standing in the square forever.
	_assert_nothing_standing_above(8, capacity)


func test_a_villager_instance_is_drawn_where_the_villager_walked_to() -> void:
	_populate(_tunables_for(CROWD, CROWD))
	# Long enough that the round-robin has been round everybody and the village is
	# actually walking about rather than standing where it was founded.
	for step in int(20.0 / STEP):
		_village.simulate(STEP)

	var people: Array = _village.villagers()
	var before: Array[Vector3] = []
	for villager: Villager in people:
		before.append(villager.position)
	_village.simulate(STEP)
	# Instance i draws villagers()[i], so a birth or a death inside this step would
	# renumber everybody and the comparison below would be against the wrong people.
	# Neither can happen here — the population is at its ceiling and twenty seconds is
	# nowhere near long enough to starve — but if it ever does, say so plainly.
	assert_eq(people.size(), CROWD, "the roster moved under the comparison")

	var moved: int = 0
	var furthest: float = 0.0
	var worst_gap: float = 0.0
	var worst_lift: float = 0.0
	var facing_errors: int = 0
	for index in people.size():
		var villager: Villager = people[index]
		var drawn: Transform3D = _village.villager_instance_transform(index)
		var gap: Vector3 = drawn.origin - villager.position
		# Horizontally, because the vertical offset is the model's lift and not a
		# failure to follow: the generated models stand on y = 0 and lift by nothing,
		# the fallback capsule is centred on its origin and lifts by half its height.
		worst_gap = maxf(worst_gap, Vector2(gap.x, gap.z).length())
		worst_lift = maxf(worst_lift, gap.y)

		var walked: Vector3 = villager.position - before[index]
		walked.y = 0.0
		if walked.length() < 0.05:
			continue
		moved += 1
		furthest = maxf(furthest, walked.length())
		# atan2(x, z), the same convention creature.gd turns its body by: the model's
		# local +Z is mapped onto the direction of travel.
		if absf(angle_difference(drawn.basis.get_euler().y, atan2(walked.x, walked.z))) > 0.01:
			facing_errors += 1

	gut.p("one %.1fs step: %d of %d villagers walked, the furthest %.3f m" % [
		STEP, moved, _village.population(), furthest
	])
	gut.p("worst gap between a villager and its instance: %.6f m across, %.3f m of lift" % [
		worst_gap, worst_lift
	])
	assert_gt(moved, 0, "nobody walked, so following a villager was never tested")
	assert_eq(facing_errors, 0, "%d instance(s) face somewhere other than where they walked"
		% facing_errors)
	assert_almost_eq(worst_gap, 0.0, 0.001,
		"an instance is drawn %.4f m away from the villager it draws" % worst_gap)
	# The placement carries no lift by design — the model's own internal offset is
	# composed in at write time, so that `previous.origin` stays comparable with
	# `villager.position` and the facing step is not skewed by the model's height.
	assert_almost_eq(worst_lift, 0.0, 0.001,
		"placement should be the villager's own position, with no offset folded in")


func test_the_villager_model_is_stood_on_its_feet() -> void:
	# The assertion this replaces checked the lift's SIGN, which is non-negative in
	# every code path, so it passed at exactly 0 — i.e. it passed on the bug it was
	# aimed at. generate_meshes.py joins the villager's parts into the first one, so
	# the joined mesh data sits with the feet at y = -0.475 and the glTF node
	# translation is what stands it up. Taking the Mesh alone loses that and draws
	# every villager buried to the thighs.
	#
	# Expected value derived from the asset rather than written down, so a lost
	# offset AND a doubled one both fail.
	_populate(_tunables_for(8, 8))
	var mesh: Mesh = _village._villager_mesh.multimesh.mesh
	assert_not_null(mesh, "the crowd batch should carry a mesh")
	if mesh == null:
		return

	var offset: float = _village._villager_local.origin.y
	var feet: float = mesh.get_aabb().position.y
	gut.p("model offset %.4f m, mesh feet at %.4f m, so drawn feet at %.4f m" % [
		offset, feet, offset + feet
	])
	assert_almost_eq(offset + feet, 0.0, 0.01,
		"the model's feet should land on the ground, not above or below it")


func test_the_decision_slice_grows_with_the_population() -> void:
	# What a flat slice costs at two hundred. villagers_per_decision_tick is a floor
	# now, and above it the slice is a fraction of the population — otherwise the
	# interval between a villager's turns grows with the village and at two hundred
	# it is ten seconds, which the player sees as the whole square standing still.
	var tunables: VillageTunables = _tunables_for(CROWD, CROWD)
	_populate(tunables)
	assert_eq(_total_decisions(), 0, "populate should not have anyone deciding yet")

	_village.simulate(1.0 / tunables.decisions_per_second)
	var slice: int = _total_decisions()
	var flat: int = tunables.villagers_per_decision_tick
	var turn_seconds: float = float(CROWD) / (tunables.decisions_per_second * float(slice))
	var flat_turn_seconds: float = float(CROWD) / (tunables.decisions_per_second * float(flat))

	gut.p("one tick over %d villagers: %d decided, against a flat budget of %d" % [
		CROWD, slice, flat
	])
	gut.p("so a villager gets a turn every %.1fs, where the flat slice took %.1fs" % [
		turn_seconds, flat_turn_seconds
	])
	assert_gt(slice, flat,
		"the slice is still the flat %d, which is the thing being fixed" % flat)
	assert_lt(turn_seconds, 2.0, "and a villager has to come round again inside a second or two")

	# Round-robin still, not the same faces every tick: the whole point of a slice is
	# that the cost is bounded, and the whole point of the cursor is that everyone
	# eventually gets a turn.
	_village.simulate(1.0 / tunables.decisions_per_second)
	assert_eq(_total_decisions(), slice * 2, "the next tick moves on to the next villagers")


func _populate(tunables: VillageTunables) -> void:
	_village.tunables = tunables
	_village.populate(_island, _registry, SEED)


## A second village with its own registry, for comparing what two populations build.
## Its own registry because two villages settling the same seeded island land on the
## same centre, and sharing would have each one's farmers walking to the other's
## fields.
func _second_village(tunables: VillageTunables) -> Node3D:
	var registry: Node = REGISTRY.new()
	autofree(registry)
	var village: Node3D = VILLAGE.new()
	village.auto_simulate = false
	village.tunables = tunables
	add_child_autofree(village)
	village.populate(_island, registry, SEED)
	return village


func _tunables_for(starting: int, ceiling: int) -> VillageTunables:
	var tunables := TUNABLES.new()
	tunables.starting_population = starting
	tunables.max_population = ceiling
	return tunables


## Every instance from `drawn` up to the buffer's capacity must be scaled to nothing.
## One left at full size is a villager standing in the square that the simulation
## does not know about and nothing will ever move again.
func _assert_nothing_standing_above(drawn: int, capacity: int) -> void:
	var standing: Array[int] = []
	for index in range(drawn, capacity):
		if _village.villager_instance_transform(index).basis.get_scale().length() > VISIBLE_SCALE:
			standing.append(index)
	assert_eq(standing.size(), 0,
		"%d instance(s) above a population of %d are still standing at full size: %s" % [
			standing.size(), drawn, standing.slice(0, 8)
		])


## Every MultiMeshInstance3D under a node, however deep. One is the bar: the
## villagers are a batch, and a batch per villager would defeat the point.
func _multimeshes(node: Node) -> Array[MultiMeshInstance3D]:
	var found: Array[MultiMeshInstance3D] = []
	var instance := node as MultiMeshInstance3D
	if instance != null:
		found.append(instance)
	for child in node.get_children():
		found.append_array(_multimeshes(child))
	return found


## MeshInstance3D nodes under a node, however deep. MultiMeshInstance3D is not one
## of them — both descend from GeometryInstance3D, so the two counts do not overlap.
func _mesh_instances(node: Node) -> int:
	var count: int = 1 if node is MeshInstance3D else 0
	for child in node.get_children():
		count += _mesh_instances(child)
	return count


func _total_decisions() -> int:
	var total: int = 0
	var people: Array = _village.villagers()
	for villager: Villager in people:
		total += villager.decisions_made
	return total
