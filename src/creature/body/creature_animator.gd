class_name CreatureAnimator
extends Node
## The creature's animation state machine.
##
## The body is procedural geometry — a capsule, a sphere and two eyes built in
## code — so there is no skeleton, no imported clips and nothing an
## AnimationPlayer could drive. Every state is instead a closed-form pose:
## a function of time applied to the mesh parts, recomputed from their captured
## rest transforms on every call to advance().
##
## Recomputing from rest rather than accumulating onto the current transform is
## the whole trick. An accumulating animator drifts, and a creature that has
## walked for ten minutes ends up a metre in the air, slowly rolling. There is a
## test that walks for thirty simulated seconds and checks it has not.
##
## The machine is gameplay-agnostic: it knows nothing about desires, actions or
## the world. The body asks for a state and the machine decides whether the
## request wins. See creature_action_states.gd for the translation from the
## mind's vocabulary into this one.

## Looping states. They persist until something else is requested.
const IDLE := &"idle"
const WALK := &"walk"
const SLEEP := &"sleep"

## One-shot states. They play for their duration and then fall back.
const EAT := &"eat"
const ATTACK := &"attack"
const HURT := &"hurt"
const CELEBRATE := &"celebrate"
const PLAY := &"play"

const STATES: Array[StringName] = [IDLE, WALK, SLEEP, EAT, ATTACK, HURT, CELEBRATE, PLAY]

@export var tunables: CreatureAnimatorTunables = null
## Drive the animation from _process as well as from explicit advance() calls.
##
## Off by default, because the normal wiring is a body that ticks the animator
## from its own frame loop: an animator that also self-ticks advances the pose
## twice per frame and everything silently runs at double speed. Turn it on only
## for an animator nothing else drives. Set it before the node enters the tree —
## _ready() is what registers the callback.
@export var auto_advance: bool = false

var _root: Node3D = null
var _root_rest: Transform3D = Transform3D.IDENTITY
## Parts riding on the neck: head and eyes. They are siblings in the body's
## hierarchy, so they only stay attached to each other if they are rotated
## together about a shared pivot.
var _head_parts: Array[Node3D] = []
var _head_rest: Array[Transform3D] = []

var _state: StringName = IDLE
var _time: float = 0.0
## Cycle phase in radians, kept wrapped so it stays precise over a long life.
var _phase: float = 0.0
var _speed: float = 0.0


## Attaches the animator to the node holding the procedural mesh parts, and
## captures the rest pose every state is expressed relative to.
##
## Safe to call again — a rebuilt body simply re-captures. Re-configuring the
## same root puts it back to rest first, or the current animated pose would be
## captured as the new rest and the rest would drift a little every call. Note
## that the pose is applied to the visual parts only: the collision shape is a
## sibling of this root, so the physics capsule stays put while the creature bobs.
func configure(body_root: Node3D) -> void:
	if body_root == _root:
		_restore_rest()
	_root = body_root
	_head_parts.clear()
	_head_rest.clear()
	if _root == null:
		return
	_root_rest = _root.transform
	var minimum_height: float = _tune().head_part_min_height
	for child: Node in _root.get_children():
		var part: Node3D = child as Node3D
		if part == null:
			continue
		if part.position.y >= minimum_height:
			_head_parts.append(part)
			_head_rest.append(part.transform)
	_apply_pose()


## Puts the parts back exactly where configure() found them. Parts are checked
## for validity because a rebuilt body keeps its root and replaces its children.
func _restore_rest() -> void:
	if not is_instance_valid(_root):
		return
	_root.transform = _root_rest
	for i in _head_parts.size():
		if is_instance_valid(_head_parts[i]):
			_head_parts[i].transform = _head_rest[i]


## The body asks for a state; the animator decides whether it gets it.
##
## Priority only defends a one-shot that is still playing. Looping states yield
## to anything, otherwise a sleeping creature could never be woken and a walking
## one could never stop.
func request_state(state: StringName) -> void:
	if not STATES.has(state):
		# An unknown state keeps whatever is playing. Falling back to idle here
		# would let one bad name from a caller cancel a real animation.
		return
	if state == _state:
		# Deliberately not a restart. The body requests a state every frame it
		# wants one, so restarting would leave a one-shot permanently at time
		# zero and it would never finish.
		return
	if _is_one_shot(_state) and _time < _tune().duration_for(_state):
		if _tune().priority_for(state) <= _tune().priority_for(_state):
			return
	_enter(state)


func current_state() -> StringName:
	return _state


func time_in_state() -> float:
	return _time


## How many parts are being treated as head. Exposed so a test can catch the
## height heuristic in configure() silently matching nothing after the body's
## geometry changes.
func head_part_count() -> int:
	return _head_parts.size()


## Blends between idle and walk by how fast the body is actually moving.
##
## Only touches the locomotion pair, plus sleep. If it could set any state, the
## body reporting zero speed every frame while the creature slept would knock it
## awake immediately. Sleep is the one non-locomotion state it may leave, and
## only for real movement: otherwise nothing short of an explicit request ever
## ends a sleep, and a creature that dozed off walks around asleep forever.
func set_locomotion_speed(speed: float) -> void:
	_speed = maxf(speed, 0.0)
	# Derived from _locomotion_state() rather than the threshold directly, so
	# "moving" means exactly one thing in this file.
	var moving: bool = _locomotion_state() == WALK
	if _state == SLEEP:
		if not moving:
			return
	elif _state != IDLE and _state != WALK:
		return
	request_state(_locomotion_state())


## Advances the state machine and reposes the body. Called explicitly rather
## than only from the frame loop so the whole machine is testable headless.
func advance(delta: float) -> void:
	var step: float = maxf(delta, 0.0)
	_time += step
	_phase = fmod(_phase + TAU * _cycle_rate() * step, TAU)
	if _is_one_shot(_state) and _time >= _tune().duration_for(_state):
		_enter(_locomotion_state())
	_apply_pose()


func _ready() -> void:
	# Not registering the callback at all is what makes double-advancing
	# impossible, rather than merely unlikely, for the usual body-driven wiring.
	set_process(auto_advance)


func _process(delta: float) -> void:
	if auto_advance:
		advance(delta)


func _enter(state: StringName) -> void:
	_state = state
	_time = 0.0
	# The cycle phase deliberately survives the transition: resetting it snaps
	# the body mid-stride every time idle and walk swap over.


func _is_one_shot(state: StringName) -> bool:
	return _tune().duration_for(state) > 0.0


## Where a one-shot lands when it finishes, and what the locomotion blend picks.
func _locomotion_state() -> StringName:
	return WALK if _speed >= _tune().walk_speed_threshold else IDLE


## Cycles per second for the current looping motion.
func _cycle_rate() -> float:
	var tune: CreatureAnimatorTunables = _tune()
	match _state:
		WALK:
			return tune.walk_frequency * _speed_factor()
		SLEEP:
			return tune.sleep_frequency
		PLAY:
			return tune.play_frequency
	return tune.idle_frequency


func _speed_factor() -> float:
	var tune: CreatureAnimatorTunables = _tune()
	var reference: float = maxf(tune.walk_reference_speed, 0.001)
	return clampf(_speed / reference, tune.walk_rate_min, tune.walk_rate_max)


## Builds the pose for the current state and writes it to the mesh parts.
##
## Every term is a bounded sinusoid of phase or of progress through a one-shot,
## and one-shot terms are enveloped so they are zero at both ends. That is what
## guarantees the body returns exactly to rest instead of creeping.
func _apply_pose() -> void:
	if _root == null:
		return
	var tune: CreatureAnimatorTunables = _tune()

	var bob: float = 0.0
	var forward: float = 0.0
	var pitch: float = 0.0
	var yaw: float = 0.0
	var roll: float = 0.0
	# Positive squashes the body down and spreads it sideways.
	var squash: float = 0.0
	var head_nod: float = 0.0

	# Progress through a one-shot, and a sine envelope that starts and ends at
	# zero so the pose is continuous across the transition either side.
	var duration: float = tune.duration_for(_state)
	var progress: float = clampf(_time / duration, 0.0, 1.0) if duration > 0.0 else 0.0
	var envelope: float = sin(PI * progress)

	match _state:
		IDLE:
			bob = sin(_phase) * tune.idle_bob
			head_nod = -cos(_phase) * tune.idle_head_nod
		WALK:
			# Two bobs per stride, and the roll a quarter cycle out of step with
			# them, which is what reads as weight shifting from foot to foot.
			bob = absf(sin(_phase)) * tune.walk_bob
			roll = cos(_phase) * tune.walk_roll
			pitch = tune.walk_lean
			head_nod = sin(_phase) * tune.walk_head_nod
		SLEEP:
			bob = -tune.sleep_sink + sin(_phase) * tune.sleep_breath
			roll = tune.sleep_roll
			head_nod = tune.sleep_head_dip
		EAT:
			squash = envelope * tune.eat_squash
			bob = -envelope * tune.eat_sink
			head_nod = envelope * tune.eat_head_dip
		ATTACK:
			forward = envelope * tune.attack_lunge
			pitch = envelope * tune.attack_pitch
			head_nod = envelope * tune.attack_head_thrust
		HURT:
			forward = -envelope * tune.hurt_recoil
			pitch = -envelope * tune.hurt_pitch
			roll = envelope * sin(TAU * progress * tune.hurt_shakes) * tune.hurt_roll
		CELEBRATE:
			bob = absf(sin(PI * progress * tune.celebrate_hops)) * tune.celebrate_hop_height
			yaw = TAU * progress * tune.celebrate_spins
		PLAY:
			# Enveloped like every other one-shot. The bounce is a free-running
			# cycle, so without the fade the pose is caught mid-hop at both ends
			# and snaps there.
			bob = absf(sin(_phase)) * envelope * tune.play_bob
			roll = cos(_phase) * envelope * tune.play_roll
			head_nod = sin(_phase) * envelope * tune.play_head_nod

	var basis: Basis = Basis.from_euler(Vector3(pitch, yaw, roll))
	basis = basis.scaled(Vector3(1.0 + squash * 0.5, 1.0 - squash, 1.0 + squash * 0.5))
	# Local +Z is forward: creature.gd aims with atan2(direction.x, direction.z)
	# and puts the eyes at positive z.
	_root.transform = _root_rest * Transform3D(basis, Vector3(0.0, bob, forward))

	var head_basis: Basis = Basis.from_euler(Vector3(head_nod, 0.0, 0.0))
	var pivot: Vector3 = Vector3(0.0, tune.head_pivot_height, 0.0)
	var head_swing: Transform3D = Transform3D(head_basis, pivot - head_basis * pivot)
	for i in _head_parts.size():
		_head_parts[i].transform = head_swing * _head_rest[i]


## Tunables, defaulted on first use so the animator works with no wiring at all.
func _tune() -> CreatureAnimatorTunables:
	if tunables == null:
		tunables = CreatureAnimatorTunables.new()
	return tunables
