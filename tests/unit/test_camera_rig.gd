extends GutTest
## Camera panning must follow what the player sees, not the world axes.

const CAMERA_RIG := preload("res://src/hand/camera_rig.gd")

## Screen-space input directions, using Godot's convention that y is down.
const UP := Vector2(0.0, -1.0)
const DOWN := Vector2(0.0, 1.0)
const LEFT := Vector2(-1.0, 0.0)
const RIGHT := Vector2(1.0, 0.0)

## A spread of orbit angles including the axis-aligned ones, where a
## world-relative bug can accidentally look correct.
const YAWS: Array[float] = [0.0, 0.6, 1.5708, 2.4, 3.14159, -1.1, -2.7]

var _rig: Node3D


func before_each() -> void:
	_rig = CAMERA_RIG.new()
	add_child_autofree(_rig)


## Points the rig at a known angle and settles the camera there immediately.
func _orbit_to(yaw: float) -> void:
	_rig.set("_yaw", yaw)
	_rig.set_focus(Vector3.ZERO)
	_rig.call("_apply", 1.0)


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func test_pan_basis_matches_where_the_camera_actually_looks() -> void:
	for yaw: float in YAWS:
		_orbit_to(yaw)
		var directions: Array[Vector3] = _rig.pan_basis()
		var expected: Vector3 = _flat(-_rig.camera.global_transform.basis.z).normalized()
		assert_almost_eq(directions[1].dot(expected), 1.0, 0.001,
			"forward should be the camera's own flattened view direction at yaw %.2f" % yaw)


func test_pan_basis_right_is_perpendicular_and_correctly_handed() -> void:
	for yaw: float in YAWS:
		_orbit_to(yaw)
		var directions: Array[Vector3] = _rig.pan_basis()
		assert_almost_eq(directions[0].dot(directions[1]), 0.0, 0.001,
			"right and forward should be perpendicular at yaw %.2f" % yaw)
		var expected_right: Vector3 = _flat(_rig.camera.global_transform.basis.x).normalized()
		assert_gt(directions[0].dot(expected_right), 0.99,
			"right should match the camera's own right at yaw %.2f, not its mirror" % yaw)


func test_pressing_up_pans_away_from_the_camera() -> void:
	# The regression that mattered. The old rig rebuilt `forward` from _yaw with
	# the sign inverted, so pressing up dragged the view back toward the viewer.
	# Nothing in the suite noticed because no test looked at the direction.
	for yaw: float in YAWS:
		_orbit_to(yaw)
		var camera_to_focus: Vector3 = _flat(
			_rig.focus_point() - _rig.camera.global_position
		).normalized()

		var before: Vector3 = _rig.focus_point()
		_rig.pan(UP, 1.0)
		var moved: Vector3 = _flat(_rig.focus_point() - before)

		assert_gt(moved.length(), 0.0, "pressing up should move the focus at yaw %.2f" % yaw)
		assert_gt(moved.normalized().dot(camera_to_focus), 0.99,
			"up must pan away from the camera at yaw %.2f, not toward it" % yaw)


func test_pressing_down_pans_toward_the_camera() -> void:
	for yaw: float in YAWS:
		_orbit_to(yaw)
		var focus_to_camera: Vector3 = _flat(
			_rig.camera.global_position - _rig.focus_point()
		).normalized()

		var before: Vector3 = _rig.focus_point()
		_rig.pan(DOWN, 1.0)
		var moved: Vector3 = _flat(_rig.focus_point() - before)

		assert_gt(moved.normalized().dot(focus_to_camera), 0.99,
			"down should pan back toward the camera at yaw %.2f" % yaw)


func test_left_and_right_are_mirror_images_along_the_screen_axis() -> void:
	for yaw: float in YAWS:
		_orbit_to(yaw)
		var start: Vector3 = _rig.focus_point()
		_rig.pan(RIGHT, 1.0)
		var right_move: Vector3 = _flat(_rig.focus_point() - start)

		_orbit_to(yaw)
		_rig.pan(LEFT, 1.0)
		var left_move: Vector3 = _flat(_rig.focus_point() - start)

		assert_gt(right_move.length(), 0.0, "right should move the focus at yaw %.2f" % yaw)
		assert_almost_eq((right_move + left_move).length(), 0.0, 0.001,
			"left and right should be exact opposites at yaw %.2f" % yaw)


func test_panning_is_relative_to_the_camera_not_the_world() -> void:
	# The actual complaint: the same keypress should move the view differently
	# once the camera has been orbited. If panning were world-relative these two
	# displacements would be identical.
	_orbit_to(0.0)
	var start: Vector3 = _rig.focus_point()
	_rig.pan(UP, 1.0)
	var unrotated: Vector3 = _flat(_rig.focus_point() - start)

	_orbit_to(PI * 0.5)
	_rig.pan(UP, 1.0)
	var rotated: Vector3 = _flat(_rig.focus_point() - start)

	gut.p("up at yaw 0: %s" % unrotated)
	gut.p("up at yaw 90: %s" % rotated)
	assert_gt(unrotated.length(), 0.0)
	assert_lt(unrotated.normalized().dot(rotated.normalized()), 0.1,
		"a quarter turn of the camera should send the same key a quarter turn round")


func test_pan_speed_scales_with_zoom() -> void:
	# Zoomed out, a keypress should cover more ground, so it feels like the same
	# amount of screen either way.
	_orbit_to(0.0)
	_rig.set("_distance", 20.0)
	var near_start: Vector3 = _rig.focus_point()
	_rig.pan(UP, 1.0)
	var near_move: float = _flat(_rig.focus_point() - near_start).length()

	_orbit_to(0.0)
	_rig.set("_distance", 160.0)
	var far_start: Vector3 = _rig.focus_point()
	_rig.pan(UP, 1.0)
	var far_move: float = _flat(_rig.focus_point() - far_start).length()

	gut.p("pan per second: %.2f m at distance 20, %.2f m at 160" % [near_move, far_move])
	assert_gt(far_move, near_move * 2.0, "panning should open up as you zoom out")


func test_focus_stays_within_the_pan_limit() -> void:
	_orbit_to(0.0)
	for i in 400:
		_rig.pan(UP, 1.0)
	assert_lte(absf(_rig.focus_point().x), _rig.pan_limit + 0.001)
	assert_lte(absf(_rig.focus_point().z), _rig.pan_limit + 0.001,
		"panning must not sail the camera off the island for ever")


func test_panning_still_works_at_the_steepest_allowed_pitch() -> void:
	# The real limit a player can reach.
	_rig.set("_pitch", _rig.min_pitch)
	_rig.set_focus(Vector3.ZERO)
	_rig.call("_apply", 1.0)

	var before: Vector3 = _rig.focus_point()
	_rig.pan(UP, 1.0)
	var moved: Vector3 = _flat(_rig.focus_point() - before)
	var camera_to_focus: Vector3 = _flat(
		_rig.focus_point() - _rig.camera.global_position
	).normalized()

	gut.p("at min pitch %.2f rad, up moved %s" % [_rig.min_pitch, moved])
	assert_gt(moved.length(), 0.0, "panning should still work looking steeply down")
	assert_gt(moved.normalized().dot(camera_to_focus), 0.9,
		"up should still pan away from the camera at the steepest pitch")


func test_pan_basis_survives_a_camera_pointed_straight_down() -> void:
	# Unreachable in play, because the rig clamps pitch — but the guard exists
	# because flattening -Z to the ground plane collapses it to zero there, and a
	# naive normalise would hand back NaN which then poisons the focus for ever.
	#
	# The basis is set directly rather than through look_at, which legitimately
	# warns that the target and up vectors are colinear.
	_rig.set_focus(Vector3.ZERO)
	_rig.call("_apply", 1.0)
	_rig.camera.global_transform = Transform3D(
		Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0)),
		Vector3(0.0, 40.0, 0.0)
	)

	var directions: Array[Vector3] = _rig.pan_basis()
	assert_almost_eq(directions[1].length(), 1.0, 0.01, "forward should stay a unit vector")
	assert_almost_eq(directions[0].length(), 1.0, 0.01, "right should stay a unit vector")
	assert_false(is_nan(directions[1].x), "forward went NaN looking straight down")
	assert_almost_eq(directions[0].dot(directions[1]), 0.0, 0.001,
		"the fallback basis should still be perpendicular")
