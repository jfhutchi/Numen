extends GutTest
## The divine hand: picking things up, and throwing them where the player flicked.

const REGISTRY := preload("res://src/world/object_registry.gd")
const ISLAND := preload("res://src/world/island.gd")
const SCATTER := preload("res://src/world/scatter.gd")
const HAND := preload("res://src/hand/hand.gd")

var _registry: Node
var _island: Node3D
var _scatter: Node3D
var _hand: Node3D


func before_each() -> void:
	_registry = REGISTRY.new()
	autofree(_registry)

	_island = ISLAND.new()
	add_child_autofree(_island)
	_island.generate(20260729)

	_scatter = SCATTER.new()
	_scatter.tree_count = 20
	_scatter.rock_count = 20
	add_child_autofree(_scatter)
	_scatter.populate(_island, _registry)

	_hand = HAND.new()
	add_child_autofree(_hand)
	# No camera: the tests drive grab_at() directly rather than through a mouse.
	_hand.configure(null, _island, _scatter, _registry)


func after_each() -> void:
	# Detached props are parented next to the hand, so they outlive autofree.
	for child: Node in get_children():
		if child.name.begins_with("Detached_"):
			child.free()


func _a_rock() -> WorldObject:
	var rocks: Array[WorldObject] = _registry.query_near(Vector3.ZERO, 100000.0, [&"rock"])
	return rocks[0] if not rocks.is_empty() else null


func test_grab_catches_the_nearest_object_and_detaches_it() -> void:
	var rock: WorldObject = _a_rock()
	assert_not_null(rock, "expected the scatter to place a rock")
	if rock == null:
		return

	assert_true(_hand.grab_at(rock.position), "hand should close on a rock under it")
	assert_true(_hand.is_holding())
	assert_eq(_hand.held_object().id, rock.id)
	assert_true(_scatter.is_hidden(rock), "a carried rock must leave the MultiMesh")
	assert_not_null(rock.node, "carrying should promote a physics body")
	assert_true(rock.node is RigidBody3D)


func test_grab_misses_when_nothing_is_in_reach() -> void:
	# Far out to sea, well beyond any scattered prop.
	assert_false(_hand.grab_at(Vector3(5000.0, 0.0, 5000.0)))
	assert_false(_hand.is_holding())


func test_hand_cannot_hold_two_things_at_once() -> void:
	var rock: WorldObject = _a_rock()
	if rock == null:
		return
	assert_true(_hand.grab_at(rock.position))
	assert_false(_hand.grab_at(rock.position), "a full hand should refuse a second object")


func test_smoothed_velocity_averages_over_the_window() -> void:
	# A steady 10 m/s slide should read as 10 m/s.
	for i in 8:
		_hand.track_sample(Vector3(float(i) * 0.1, 0.0, 0.0), 0.01)
	var velocity: Vector3 = _hand.smoothed_velocity()
	assert_almost_eq(velocity.x, 10.0, 0.5, "steady motion should read back at its true speed")


func test_smoothed_velocity_rejects_a_single_frame_of_jitter() -> void:
	# The reason smoothing exists: one bad frame must not decide the throw.
	# The stray frame below is a 300 m/s sideways spike. Displacement-over-window
	# smoothing let 60 m/s of that through; trimming the fastest sample should
	# leave the honest forward motion essentially untouched.
	for i in 7:
		_hand.track_sample(Vector3(float(i) * 0.1, 0.0, 0.0), 0.01)
	_hand.track_sample(Vector3(0.6, 0.0, 3.0), 0.01)
	var jittered: Vector3 = _hand.smoothed_velocity()
	gut.p("velocity after one 300 m/s stray frame: %s" % jittered)

	assert_lt(absf(jittered.z), 5.0,
		"a single stray frame should not steer the throw sideways")
	assert_almost_eq(jittered.x, 10.0, 1.0,
		"and the genuine forward motion should survive the trim")


func test_released_object_keeps_flying() -> void:
	var rock: WorldObject = _a_rock()
	if rock == null:
		return
	assert_true(_hand.grab_at(rock.position))

	# Simulate the hand sweeping sideways, then let go.
	var body: RigidBody3D = rock.node
	var start: Vector3 = Vector3(0.0, 40.0, 0.0)
	for i in 8:
		_hand.track_sample(start + Vector3(float(i) * 0.15, 0.0, 0.0), 1.0 / 60.0)
	body.global_position = start

	var throw_velocity: Vector3 = _hand.release()
	gut.p("release velocity: %s (%.2f m/s)" % [throw_velocity, throw_velocity.length()])

	assert_gt(throw_velocity.length(), 1.0, "a swept hand should impart real speed")
	assert_false(_hand.is_holding())
	assert_false(body.freeze, "released body must be simulated again")

	var before: Vector3 = body.global_position
	await wait_physics_frames(20)
	var after: Vector3 = body.global_position

	assert_gt(after.distance_to(before), 0.5, "a thrown rock should actually travel")
	assert_lt(after.y, before.y, "and gravity should be acting on it")


func test_throw_speed_is_capped() -> void:
	var rock: WorldObject = _a_rock()
	if rock == null:
		return
	assert_true(_hand.grab_at(rock.position))
	# An absurd flick, the sort a fast mouse produces.
	for i in 8:
		_hand.track_sample(Vector3(float(i) * 20.0, 0.0, 0.0), 1.0 / 60.0)
	var throw_velocity: Vector3 = _hand.release()
	assert_lte(throw_velocity.length(), _hand.max_throw_speed + 0.001,
		"uncapped throws would fling props off the island")
