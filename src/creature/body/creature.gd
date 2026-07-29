extends CharacterBody3D
## The creature's body: the thing that carries the mind around and acts on what
## it decides.
##
## The body is deliberately dumb. It holds no plan and makes no choices — it
## walks to whatever the mind picked, performs the action when it arrives, and
## reports what the world did back. Every decision lives in src/creature/mind/.

signal chose(option: CreatureMind.Option)
signal acted_on(action: StringName, object: WorldObject)
signal feedback_shown(value: float)

const LEASH_NONE := &"none"
const LEASH_LEARNING := &"learning"
const LEASH_COMPASSION := &"compassion"
const LEASH_AGGRESSION := &"aggression"

## How hard each leash leans on the relevant desire. Not an override — a
## leashed creature still does what it has learned, it is just inclined.
const LEASH_BIAS: Dictionary = {
	LEASH_COMPASSION: {&"Compassion": 2.2, &"Anger": 0.35},
	LEASH_AGGRESSION: {&"Anger": 2.2, &"Compassion": 0.35},
}

@export var move_speed: float = 7.0
@export var turn_speed: float = 6.0
## How close it must be before it can act on something.
@export var action_radius: float = 3.0
@export var gravity: float = 24.0
## Drives drift over time so the creature has reasons to do things.
@export var hunger_per_second: float = 0.012
@export var fatigue_per_second: float = 0.006
@export var idle_per_second: float = 0.05

var mind: CreatureMind
var leash: StringName = LEASH_NONE

var _island: Node3D
var _registry: Node
var _rng := RandomNumberGenerator.new()
var _next_decision: float = 0.0
var _target: WorldObject = null
var _body_mesh: MeshInstance3D
var _flash: float = 0.0
var _flash_colour := Color.WHITE


func configure(
	registry: Node, island: Node3D, tunables: MindTunables = null, seed_value: int = 0
) -> void:
	_registry = registry
	_island = island
	_rng.seed = seed_value
	mind = CreatureMind.new(tunables, seed_value)
	mind.bind_world(registry, global_position)


func _ready() -> void:
	_build_body()
	if mind == null:
		# Standing alone in a scene with no configure() call; still functional.
		mind = CreatureMind.new()


func set_leash(new_leash: StringName) -> void:
	leash = new_leash
	var bias: Dictionary = LEASH_BIAS.get(new_leash, {})
	var typed: Dictionary[StringName, float] = {}
	for key: StringName in bias:
		typed[key] = float(bias[key])
	mind.desire_bias = typed


## Player reward. Credits whatever the creature did in the last few seconds.
func pet() -> void:
	mind.apply_player_feedback(1.0)
	_flash_with(Color(0.4, 1.0, 0.5))
	feedback_shown.emit(1.0)


## Player punishment.
func slap() -> void:
	mind.apply_player_feedback(-1.0)
	_flash_with(Color(1.0, 0.35, 0.3))
	feedback_shown.emit(-1.0)


## The player did something to an object in front of the creature. On the leash
## of learning this is a strong lesson; otherwise it is mere imitation.
func witness(action: StringName, object: WorldObject, value: float) -> void:
	var desire: StringName = &"Curiosity"
	if leash == LEASH_LEARNING:
		mind.learn_from_demonstration(desire, action, object, value)
	else:
		mind.learn_from_imitation(desire, action, object, value)


func _physics_process(delta: float) -> void:
	_drift_drives(delta)
	mind.advance_clock(delta)
	mind.set_position(global_position)

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	_next_decision -= delta
	if _next_decision <= 0.0:
		_decide()
		# Jittered so a herd of creatures never thinks on the same frame.
		var interval: float = 1.0 / maxf(mind.tunables.decision_hz, 0.001)
		_next_decision = interval * (
			1.0 + _rng.randf_range(-mind.tunables.decision_jitter, mind.tunables.decision_jitter)
		)

	_move_toward_target(delta)
	move_and_slide()
	_tick_flash(delta)


func _decide() -> void:
	var choice: CreatureMind.Option = mind.choose()
	if choice == null:
		_target = null
		return
	_target = choice.object
	chose.emit(choice)

	# Act immediately if already close enough; otherwise walk over first and the
	# next decision will catch it.
	if _target != null and global_position.distance_to(_target.current_position()) <= action_radius:
		_perform(choice)


func _perform(option: CreatureMind.Option) -> void:
	mind.perform(option)
	acted_on.emit(option.action, option.object)

	# Intrinsic consequences: what the world says back, with no player involved.
	if option.object == null:
		return
	match option.action:
		&"eat":
			var nutrition: float = ObjectAttributes.truth_for(option.object.type)[
				ObjectAttributes.index_of(&"nutritious")
			]
			if nutrition > 0.1:
				mind.hunger = clampf(mind.hunger - nutrition * 0.5, 0.0, 1.0)
				mind.apply_intrinsic_feedback(option.desire, option.action, option.object, nutrition)
			else:
				# Eating a rock teaches its own lesson.
				mind.apply_intrinsic_feedback(option.desire, option.action, option.object, -0.5)
		&"sleep":
			mind.fatigue = clampf(mind.fatigue - 0.4, 0.0, 1.0)
			mind.apply_intrinsic_feedback(option.desire, option.action, option.object, 0.4)


func _drift_drives(delta: float) -> void:
	mind.hunger = clampf(mind.hunger + hunger_per_second * delta, 0.0, 1.0)
	mind.fatigue = clampf(mind.fatigue + fatigue_per_second * delta, 0.0, 1.0)
	mind.idle = clampf(mind.idle + idle_per_second * delta, 0.0, 1.0)


func _move_toward_target(delta: float) -> void:
	if _target == null or not _target.alive:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	var to_target: Vector3 = _target.current_position() - global_position
	to_target.y = 0.0
	if to_target.length() <= action_radius:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	var direction: Vector3 = to_target.normalized()
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed

	var wanted: float = atan2(direction.x, direction.z)
	rotation.y = lerp_angle(rotation.y, wanted, clampf(turn_speed * delta, 0.0, 1.0))


func _build_body() -> void:
	# Procedural: a body, a head and two eyes. Enough to read which way it is
	# facing and to show alignment through colour, which is what Phase 5 needs.
	var root := Node3D.new()
	root.name = "Body"
	add_child(root)

	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.8
	capsule.height = 2.6
	body.mesh = capsule
	body.position = Vector3(0.0, 1.3, 0.0)
	body.material_override = _skin()
	root.add_child(body)
	_body_mesh = body

	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.62
	head_mesh.height = 1.24
	head.mesh = head_mesh
	head.position = Vector3(0.0, 2.7, 0.25)
	head.material_override = _skin()
	root.add_child(head)

	for side: float in [-0.26, 0.26]:
		var eye := MeshInstance3D.new()
		var eye_mesh := SphereMesh.new()
		eye_mesh.radius = 0.12
		eye_mesh.height = 0.24
		eye.mesh = eye_mesh
		eye.position = Vector3(side, 2.85, 0.78)
		var white := StandardMaterial3D.new()
		white.albedo_color = Color(0.05, 0.05, 0.06)
		eye.material_override = white
		root.add_child(eye)

	var shape := CollisionShape3D.new()
	var collider := CapsuleShape3D.new()
	collider.radius = 0.8
	collider.height = 2.6
	shape.shape = collider
	shape.position = Vector3(0.0, 1.3, 0.0)
	add_child(shape)


func _skin() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.55, 0.45, 0.38).srgb_to_linear()
	material.roughness = 0.85
	return material


func _flash_with(colour: Color) -> void:
	_flash = 1.0
	_flash_colour = colour


func _tick_flash(delta: float) -> void:
	if _body_mesh == null:
		return
	# Alignment tints the creature: cruelty darkens and reddens it. Feedback
	# flashes over the top so a slap reads instantly.
	var base := Color(0.55, 0.45, 0.38).lerp(Color(0.32, 0.13, 0.14), clampf(-mind.alignment, 0.0, 1.0))
	base = base.lerp(Color(0.62, 0.58, 0.40), clampf(mind.alignment, 0.0, 1.0))
	var material: StandardMaterial3D = _body_mesh.material_override
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 2.0, 0.0)
		material.albedo_color = base.lerp(_flash_colour, _flash).srgb_to_linear()
	else:
		material.albedo_color = base.srgb_to_linear()
