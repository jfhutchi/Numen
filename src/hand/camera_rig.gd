extends Node3D
## Orbit / zoom / pan camera over the island.
##
## Right mouse orbits, wheel zooms, WASD or arrows pan. Left mouse is left alone
## because it belongs to the divine hand — the hand is the only cursor.

@export var min_distance: float = 10.0
@export var max_distance: float = 180.0
@export var start_distance: float = 80.0
## Pitch is negative because the camera looks down at the island.
@export var min_pitch: float = -1.35
@export var max_pitch: float = -0.12
@export var orbit_sensitivity: float = 0.005
@export var zoom_factor: float = 0.12
@export var pan_speed: float = 28.0
@export var smoothing: float = 12.0
## Keeps the focus point inside the island rather than drifting out to sea.
@export var pan_limit: float = 90.0
## Minimum height the camera keeps above the terrain (or the waterline, over the
## sea). Without it a shallow-pitched orbit clipped straight through hillsides —
## the lerp path between two legal positions is not itself checked by anything.
@export var ground_clearance: float = 1.6

var camera: Camera3D

var _yaw: float = 0.6
var _pitch: float = -0.65
var _distance: float = 80.0
var _focus: Vector3 = Vector3.ZERO
var _orbiting: bool = false
var _island: Node3D


func _ready() -> void:
	_distance = start_distance
	camera = Camera3D.new()
	camera.name = "Camera3D"
	# Far enough that the water plane's edge is never clipped into view.
	camera.far = 2400.0
	add_child(camera)
	camera.current = true
	_apply(1.0)


## The island is optional; with one, the focus point rides the terrain so the
## camera keeps a steady height over hills instead of clipping into them.
func set_island(island: Node3D) -> void:
	_island = island


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = button.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					_zoom(-zoom_factor)
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					_zoom(zoom_factor)
	elif event is InputEventMouseMotion and _orbiting:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * orbit_sensitivity
		_pitch = clampf(_pitch - motion.relative.y * orbit_sensitivity, min_pitch, max_pitch)


func _process(delta: float) -> void:
	var move: Vector2 = pan_input()
	if move != Vector2.ZERO:
		pan(move, delta)

	if _island != null:
		_focus.y = maxf(_island.height_at(_focus.x, _focus.z), 0.0)

	_apply(clampf(delta * smoothing, 0.0, 1.0))


## Pan input as a screen-space direction: x is right, y is *down*, matching
## Godot's own `ui_up`/`ui_down` convention.
func pan_input() -> Vector2:
	var axis := Vector2(
		Input.get_axis(&"ui_left", &"ui_right"), Input.get_axis(&"ui_up", &"ui_down")
	)
	# WASD alongside the arrows. Physical keycodes, so the cluster keeps its
	# shape on AZERTY and Dvorak instead of scattering across the keyboard.
	if Input.is_physical_key_pressed(KEY_A):
		axis.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		axis.x += 1.0
	if Input.is_physical_key_pressed(KEY_W):
		axis.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		axis.y += 1.0
	# Limited rather than normalised so a single key still gives full speed while
	# two together do not add up to 1.41x.
	return axis.limit_length(1.0)


## Slides the focus point across the ground, in the directions the player sees
## on screen. Separated from _process so the mapping can be tested without
## synthesising input.
func pan(move: Vector2, delta: float) -> void:
	var directions: Array[Vector3] = pan_basis()
	# move.y is screen-down, so it is subtracted: pressing up goes forward.
	var displacement: Vector3 = directions[0] * move.x - directions[1] * move.y
	# Scaled with zoom so a keypress covers the same fraction of the screen
	# whether you are looking at one hut or the whole island.
	var speed: float = pan_speed * delta * (_distance / maxf(start_distance, 0.001))
	_focus += displacement * speed
	_focus.x = clampf(_focus.x, -pan_limit, pan_limit)
	_focus.z = clampf(_focus.z, -pan_limit, pan_limit)


## The ground-plane [right, forward] the camera is currently looking along.
##
## Taken from the camera's own basis rather than rebuilt from `_yaw` with trig.
## The previous version did the latter and got the sign wrong: `forward` actually
## pointed from the focus back toward the camera, so pressing up panned
## backwards, and `right` was only correct because a second sign error cancelled
## the first. Reading the transform is correct by construction and stays correct
## if the rig's maths ever changes.
func pan_basis() -> Array[Vector3]:
	if camera == null:
		return [Vector3.RIGHT, Vector3.FORWARD]

	var basis: Basis = camera.global_transform.basis
	var forward: Vector3 = -basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.000001:
		# Looking almost straight down, where -Z collapses onto the ground plane.
		# The camera's +Y is screen-up, which is what the player means by forward.
		forward = basis.y
		forward.y = 0.0
	if forward.length_squared() < 0.000001:
		return [Vector3.RIGHT, Vector3.FORWARD]
	forward = forward.normalized()

	# Right-handed, Y up: rotating the ground forward -90 degrees about Y.
	return [Vector3(-forward.z, 0.0, forward.x), forward]


func _zoom(amount: float) -> void:
	_distance = clampf(_distance * (1.0 + amount), min_distance, max_distance)


func _apply(weight: float) -> void:
	var offset := Vector3(0.0, 0.0, _distance).rotated(Vector3.RIGHT, _pitch).rotated(
		Vector3.UP, _yaw
	)
	var wanted: Vector3 = _keep_above_ground(_focus + offset)
	# Clamped again AFTER the lerp, not only before it: both endpoints of a lerp
	# can be legally above ground while the path between them passes through a
	# ridge, and a smoothed camera spends many frames on that path. Orbiting low
	# across a hill clipped straight through the hillside.
	camera.global_position = _keep_above_ground(
		camera.global_position.lerp(wanted, weight)
	)
	camera.look_at(_focus, Vector3.UP)


## The position lifted clear of the terrain under it. Over the sea the floor is
## the water plane, so a low orbit cannot dive beneath the waves either.
func _keep_above_ground(at: Vector3) -> Vector3:
	if _island == null:
		return at
	var floor_y: float = maxf(_island.height_at(at.x, at.z), 0.0) + ground_clearance
	if at.y < floor_y:
		at.y = floor_y
	return at


## Where the camera is pointing, for systems that need to follow it.
func focus_point() -> Vector3:
	return _focus


func set_focus(point: Vector3) -> void:
	_focus = point
