extends GutTest
## The orbit camera's terrain clearance.
##
## Requested from play: the camera clipped through hillsides. Nothing checked the
## camera's own position against the ground — the focus point rode the terrain,
## but a shallow-pitched orbit swings the camera itself through any ridge between
## it and the focus, and the smoothing lerp spends many frames on that path.

const RIG := preload("res://src/hand/camera_rig.gd")
const ISLAND := preload("res://src/world/island.gd")

var _island: Node3D
var _rig: Node3D


func before_each() -> void:
	_island = ISLAND.new()
	add_child_autofree(_island)
	_island.generate(20260729)
	_rig = RIG.new()
	add_child_autofree(_rig)
	_rig.set_island(_island)


func _ground_under_camera() -> float:
	var at: Vector3 = _rig.camera.global_position
	return maxf(_island.height_at(at.x, at.z), 0.0)


func test_the_camera_stays_out_of_the_hills() -> void:
	# A low, shallow orbit aimed at a point on land: the raw orbit position would
	# sit inside whatever slope is behind the focus.
	_rig.set_focus(Vector3(0.0, _island.height_at(0.0, 0.0), 0.0))
	_rig.set("_distance", 14.0)
	_rig.set("_pitch", -0.13)
	var worst: float = INF
	for step in 24:
		_rig.set("_yaw", TAU * float(step) / 24.0)
		_rig._apply(1.0)
		worst = minf(worst, _rig.camera.global_position.y - _ground_under_camera())
	gut.p("lowest clearance over a full low orbit: %.2f m" % worst)
	assert_gte(worst, _rig.ground_clearance - 0.001,
		"the camera must never dip beneath its ground clearance")


func test_the_lerped_path_is_clamped_too() -> void:
	# Both endpoints legal, the path between them inside a ridge: the smoothing
	# lerp must be clamped as well, or the camera clips for the frames in between.
	_rig.set_focus(Vector3(-30.0, _island.height_at(-30.0, -30.0), -30.0))
	_rig.set("_distance", 20.0)
	_rig.set("_pitch", -0.15)
	_rig.set("_yaw", 0.0)
	_rig._apply(1.0)
	# Swing to the far side and take one small smoothing step toward it.
	_rig.set_focus(Vector3(30.0, _island.height_at(30.0, 30.0), 30.0))
	_rig.set("_yaw", PI)
	_rig._apply(0.15)
	var clearance: float = _rig.camera.global_position.y - _ground_under_camera()
	gut.p("clearance mid-swing: %.2f m" % clearance)
	assert_gte(clearance, _rig.ground_clearance - 0.001,
		"the smoothing path must not pass through the terrain")


func test_over_the_sea_the_floor_is_the_waterline() -> void:
	_rig.set_focus(Vector3(200.0, 0.0, 200.0))
	_rig.set("_distance", 10.0)
	_rig.set("_pitch", -0.12)
	_rig._apply(1.0)
	assert_gte(_rig.camera.global_position.y, _rig.ground_clearance - 0.001,
		"a low orbit over open water must not dive beneath the waves")
