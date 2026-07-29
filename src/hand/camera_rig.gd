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
	var move := Vector2(
		Input.get_axis(&"ui_left", &"ui_right"), Input.get_axis(&"ui_up", &"ui_down")
	)
	if move != Vector2.ZERO:
		# Pan relative to where the camera is looking, and scale with zoom so a
		# drag covers the same fraction of the screen at every distance.
		var forward := Vector3(sin(_yaw), 0.0, cos(_yaw))
		var right := Vector3(forward.z, 0.0, -forward.x)
		var speed: float = pan_speed * delta * (_distance / start_distance)
		_focus += (right * move.x - forward * move.y) * speed
		_focus.x = clampf(_focus.x, -pan_limit, pan_limit)
		_focus.z = clampf(_focus.z, -pan_limit, pan_limit)

	if _island != null:
		_focus.y = maxf(_island.height_at(_focus.x, _focus.z), 0.0)

	_apply(clampf(delta * smoothing, 0.0, 1.0))


func _zoom(amount: float) -> void:
	_distance = clampf(_distance * (1.0 + amount), min_distance, max_distance)


func _apply(weight: float) -> void:
	var offset := Vector3(0.0, 0.0, _distance).rotated(Vector3.RIGHT, _pitch).rotated(
		Vector3.UP, _yaw
	)
	var wanted: Vector3 = _focus + offset
	camera.global_position = camera.global_position.lerp(wanted, weight)
	camera.look_at(_focus, Vector3.UP)


## Where the camera is pointing, for systems that need to follow it.
func focus_point() -> Vector3:
	return _focus


func set_focus(point: Vector3) -> void:
	_focus = point
