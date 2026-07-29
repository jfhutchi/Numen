extends GutTest
## Phase 1 acceptance test: a thrown body must follow a ballistic arc.
##
## This is the gate on the divine hand feeling right. If damping, gravity scale
## or the physics backend ever drift, throwing stops matching where the player
## aimed, and nothing else in the project would notice.

const RADIUS := 0.5
const START := Vector3(0.0, 12.0, 0.0)
const THROW_VELOCITY := Vector3(9.0, 6.0, -4.0)
## Flight time for this arc is about 1.75 s, so ~105 steps at 60 Hz. The budget
## is generous but not unbounded — headless physics runs in real time, and a
## 900-step ceiling turned this file into a 34-second gate.
const MAX_STEPS := 300
## Steps to let the thrown body land and settle vertically before inspecting it.
const SETTLE_STEPS := 200

## Semi-implicit Euler integration lags the continuous solution by roughly
## 0.5*g*dt per step of velocity, so the discrete arc lands slightly long. At
## 60 Hz over this arc that is a few centimetres; 0.40 m leaves headroom for a
## different physics tick rate without being loose enough to hide real damping.
const TOLERANCE_M := 0.40


func _gravity() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))


func _make_body() -> RigidBody3D:
	var body := RigidBody3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = RADIUS
	var collision := CollisionShape3D.new()
	collision.shape = sphere
	body.add_child(collision)
	# The project default is 0.1 linear damp. Left in place it would bleed speed
	# out of the arc and quietly break the prediction, so it is replaced, not
	# merely set.
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = 0.0
	body.gravity_scale = 1.0
	return body


func _make_floor() -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 2.0, 400.0)
	var collision := CollisionShape3D.new()
	collision.shape = box
	# Box centred one metre down puts its top surface exactly at y = 0.
	collision.position = Vector3(0.0, -1.0, 0.0)
	floor_body.add_child(collision)
	return floor_body


## Closed-form ballistic solution: where the centre of the body crosses
## `target_y` on the way down, with no drag.
func _predict_landing(target_y: float) -> Vector3:
	var g: float = _gravity()
	var vy: float = THROW_VELOCITY.y
	var drop: float = START.y - target_y
	var flight: float = (vy + sqrt(vy * vy + 2.0 * g * drop)) / g
	return Vector3(
		START.x + THROW_VELOCITY.x * flight,
		target_y,
		START.z + THROW_VELOCITY.z * flight
	)


func test_thrown_body_follows_a_ballistic_arc() -> void:
	var body: RigidBody3D = _make_body()
	add_child_autofree(body)
	body.global_position = START
	body.linear_velocity = THROW_VELOCITY

	# Measured in free flight, then interpolated to the exact crossing height.
	# Sampling only at physics-step boundaries would add up to a whole step of
	# horizontal travel — about 15 cm here — as pure measurement error.
	var previous: Vector3 = body.global_position
	var current: Vector3 = previous
	var crossed := false
	for step in MAX_STEPS:
		await wait_physics_frames(1)
		previous = current
		current = body.global_position
		if current.y <= RADIUS:
			crossed = true
			break

	assert_true(crossed, "body did not fall past the target height within %d steps" % MAX_STEPS)
	if not crossed:
		return

	var t: float = inverse_lerp(previous.y, current.y, RADIUS)
	var measured: Vector3 = previous.lerp(current, t)
	var predicted: Vector3 = _predict_landing(RADIUS)
	var error: float = Vector2(measured.x - predicted.x, measured.z - predicted.z).length()

	gut.p("predicted landing: %s" % predicted)
	gut.p("measured  landing: %s" % measured)
	gut.p("horizontal error : %.4f m (tolerance %.2f m)" % [error, TOLERANCE_M])

	assert_lt(error, TOLERANCE_M,
		"thrown body landed %.3f m from the ballistic prediction" % error)


func test_thrown_body_comes_to_rest_on_the_ground() -> void:
	# The arc test deliberately measures in free flight. This one confirms the
	# collision half actually works, so a body that flies correctly and then
	# falls through the world cannot pass.
	add_child_autofree(_make_floor())
	var body: RigidBody3D = _make_body()
	add_child_autofree(body)
	body.global_position = START
	body.linear_velocity = THROW_VELOCITY

	await wait_physics_frames(SETTLE_STEPS)

	# Deliberately not asserting the body has fully stopped. A sphere with no
	# rolling resistance keeps rolling across a flat floor indefinitely, which is
	# correct physics — an earlier version of this test asserted a full stop and
	# failed for that reason. What matters here is that it is resting *on* the
	# surface rather than sinking through it.
	gut.p("resting position: %s (vy %.4f)" % [body.global_position, body.linear_velocity.y])

	assert_almost_eq(body.global_position.y, RADIUS, 0.1,
		"a resting sphere should sit one radius above the surface, not through it")
	assert_lt(absf(body.linear_velocity.y), 0.5,
		"vertical motion should have stopped once it is on the ground")
