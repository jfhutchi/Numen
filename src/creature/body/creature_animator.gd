class_name CreatureAnimator
extends Node
## The creature's animation state machine.
##
## The body is procedural geometry built in code — a torso, a head with a snout
## and a jaw, four two-segment legs, a tail — so there is no skeleton, no
## imported clips and nothing an AnimationPlayer could drive. Every state is
## instead a closed-form pose: a function of time applied to the rig's named
## parts, recomputed from their captured rest transforms on every call to
## advance().
##
## Recomputing from rest rather than accumulating onto the current transform is
## the whole trick. An accumulating animator drifts, and a creature that has
## walked for ten minutes ends up a metre in the air, slowly rolling. There is a
## test that walks for thirty simulated seconds and checks it has not.
##
## Parts are always rotated about their own origin, because the rig puts each
## origin on the joint it turns about (see creature.gd build_rig). That is what
## keeps this file free of a pivot table: a hip node is at the hip, so rotating
## it swings the leg from the hip, and the knee hanging off it comes along.
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

## Names the rig hands its parts over under. The body owns the geometry; these
## are the only names the two files have to agree on, and bind_parts() ignores
## anything else it is given (the eyes, for instance, ride the head and need no
## pose of their own).
const PART_TORSO := &"torso"
const PART_HEAD := &"head"
const PART_JAW := &"jaw"
const PART_EAR_LEFT := &"ear_left"
const PART_EAR_RIGHT := &"ear_right"
const PART_TAIL := &"tail"

## Hips and shoulders. The order is load-bearing: LEG_PHASE and SHINS are indexed
## alongside it.
const LEGS: Array[StringName] = [
	&"leg_front_left", &"leg_front_right", &"leg_rear_left", &"leg_rear_right"
]
## Knees, one per entry of LEGS.
const SHINS: Array[StringName] = [
	&"shin_front_left", &"shin_front_right", &"shin_rear_left", &"shin_rear_right"
]
## The gait. Diagonal pairs — front-left with rear-right — swing together, half a
## cycle away from the other pair. That is a trot, and it is what reads as a
## four-legged animal walking; legs moving in unison read as hopping, and legs at
## four different phases read as a shuffle.
const LEG_PHASE: Array[float] = [0.0, PI, PI, 0.0]

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
## The rig's articulated parts by name, and the rest pose each is posed relative
## to. Named rather than found by height or by child order: the old height
## heuristic could not tell a front leg from a rear one, and there is no gait
## without that.
var _parts: Dictionary[StringName, Node3D] = {}
var _rest: Dictionary[StringName, Transform3D] = {}

## Set when the body is a rigged, animated mesh. When present the state machine
## drives baked clips instead of posing primitives by hand — see _drive_clips().
var _player: AnimationPlayer = null
var _clip_names: Dictionary[StringName, String] = {}

var _state: StringName = IDLE
var _time: float = 0.0
## Cycle phase in radians, kept wrapped so it stays precise over a long life.
var _phase: float = 0.0
var _speed: float = 0.0


## Attaches the animator to the node holding the procedural rig, and captures the
## root's rest transform, which whole-body motion is expressed relative to.
##
## Safe to call again — a rebuilt body simply re-captures. Re-configuring the
## same root puts it back to rest first, or the current animated pose would be
## captured as the new rest and the rest would drift a little every call. Note
## that the pose is applied to the visual parts only: the collision shape is a
## sibling of this root, so the physics capsule stays put while the creature bobs.
##
## Any previously bound parts are dropped, because they belonged to the rig being
## replaced. Follow this with bind_parts().
func configure(body_root: Node3D) -> void:
	if body_root == _root:
		_restore_rest()
	_root = body_root
	_parts.clear()
	_rest.clear()
	if _root == null:
		return
	_root_rest = _root.transform
	_apply_pose()


## Hands the animator the rig's named parts and captures their rest transforms.
##
## Keys are the PART_* constants and the LEGS/SHINS entries; unknown keys are
## kept but never posed, and a part the animator wants but is not given is simply
## not animated. That asymmetry is why the tests assert has_part() for everything
## the walk cycle touches — a typo in one name is otherwise a silently stiff leg.
func bind_parts(parts: Dictionary) -> void:
	_restore_rest()
	_parts.clear()
	_rest.clear()
	for key: StringName in parts:
		var part: Node3D = parts[key] as Node3D
		if part == null:
			continue
		_parts[key] = part
		_rest[key] = part.transform
	_apply_pose()


## Puts the rig back exactly where it was captured. Parts are checked for
## validity because a rebuilt body keeps its root and frees its old children.
func _restore_rest() -> void:
	if not is_instance_valid(_root):
		return
	_root.transform = _root_rest
	for key: StringName in _parts:
		if is_instance_valid(_parts[key]):
			_parts[key].transform = _rest[key]


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


## Whether the rig handed over a part under this name. Exposed so a test can
## catch the body and the animator disagreeing about what a leg is called, which
## the animator itself cannot notice.
func has_part(key: StringName) -> bool:
	return _parts.has(key)


func part_count() -> int:
	return _parts.size()


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
	if _player != null:
		_drive_clips()
	else:
		_apply_pose()


## Binds a rigged body's AnimationPlayer, so the state machine plays baked clips
## rather than posing primitives.
##
## This is the only difference between the two bodies the creature can wear. The
## state machine above — which state is legal, how long a one-shot lasts, what
## interrupts what, how fast the cycle runs — is identical either way, because
## that logic is about *when* to animate and has nothing to do with *how*.
##
## `mapping` is state -> clip name. Names are resolved against the player once,
## here, rather than on every frame: glTF importers prefix clips with the
## armature name ("AnimalArmature|Walk"), so the lookup has to try both forms and
## doing that 60 times a second would be silly.
func bind_animation_player(player: AnimationPlayer, mapping: Dictionary) -> void:
	_player = player
	_clip_names.clear()
	if player == null:
		return
	var available: PackedStringArray = player.get_animation_list()
	for state: StringName in mapping:
		var wanted: String = String(mapping[state])
		for candidate: String in available:
			if candidate == wanted or candidate.get_slice("|", 1) == wanted:
				_clip_names[state] = candidate
				break
	# A rigged body must not also be posed by hand: the procedural pass writes the
	# same transforms the skeleton owns and the two fight each other every frame.
	_parts.clear()


func has_animation_player() -> bool:
	return _player != null


## The clip this state resolves to, or "" when the rig has nothing for it.
func clip_for(state: StringName) -> String:
	return _clip_names.get(state, "")


## Plays the clip for the current state, looping the sustained ones and letting
## one-shots run once. Locomotion speed scales playback so a walk cycle matches
## the ground the creature is covering instead of skating over it.
func _drive_clips() -> void:
	var clip: String = _clip_names.get(_state, "")
	if clip.is_empty():
		# No clip for this state: fall back to whatever idle resolves to rather
		# than freezing on the last frame of something unrelated.
		clip = _clip_names.get(IDLE, "")
		if clip.is_empty():
			return

	if _player.current_animation != clip:
		_player.play(clip)
	var animation: Animation = _player.get_animation(clip)
	if animation != null:
		animation.loop_mode = (
			Animation.LOOP_NONE if _is_one_shot(_state) else Animation.LOOP_LINEAR
		)
	_player.speed_scale = _speed_factor() if _state == WALK else 1.0


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


## Cycles per second for the current looping motion. The gait rides on this, so
## a creature moving faster takes more strides per second rather than sliding.
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


## Builds the pose for the current state and writes it to the rig.
##
## Every term is a bounded sinusoid of phase or of progress through a one-shot,
## and one-shot terms are enveloped so they are zero at both ends. That is what
## guarantees the body returns exactly to rest instead of creeping.
func _apply_pose() -> void:
	if _root == null:
		return
	var tune: CreatureAnimatorTunables = _tune()

	# Whole-body terms, applied to the rig root.
	var bob: float = 0.0
	var forward: float = 0.0
	var pitch: float = 0.0
	var yaw: float = 0.0
	var roll: float = 0.0
	# Positive squashes the body down and spreads it sideways.
	var squash: float = 0.0

	# Per-part terms. Anything a state leaves at zero returns exactly to rest,
	# which is why nothing has to be explicitly cleared between states.
	var breath: float = 0.0
	var head_nod: float = 0.0
	var jaw_open: float = 0.0
	# Positive splays both ears outward.
	var ear_flick: float = 0.0
	var tail_sway: float = 0.0
	var tail_lift: float = 0.0
	var leg_swing: float = 0.0
	var knee_bend: float = 0.0
	# A constant crouch added to every knee, for lying down.
	var knee_fold: float = 0.0

	# Progress through a one-shot, and a sine envelope that starts and ends at
	# zero so the pose is continuous across the transition either side.
	var duration: float = tune.duration_for(_state)
	var progress: float = clampf(_time / duration, 0.0, 1.0) if duration > 0.0 else 0.0
	var envelope: float = sin(PI * progress)

	match _state:
		IDLE:
			bob = sin(_phase) * tune.idle_bob
			breath = sin(_phase) * tune.idle_breath
			head_nod = -cos(_phase) * tune.idle_head_nod
			# A quarter cycle out of step with the breathing, so the two do not
			# look mechanically linked. Not a slower term: anything on a fraction
			# of _phase jumps when the phase wraps at TAU.
			tail_sway = cos(_phase) * tune.idle_tail_sway
			ear_flick = _ear_twitch()
		WALK:
			# Two bobs per stride, and the roll a quarter cycle out of step with
			# them, which is what reads as weight shifting from foot to foot.
			bob = absf(sin(_phase)) * tune.walk_bob
			roll = cos(_phase) * tune.walk_roll
			pitch = tune.walk_lean
			head_nod = sin(_phase) * tune.walk_head_nod
			leg_swing = tune.walk_leg_swing
			knee_bend = tune.walk_knee_bend
			tail_sway = sin(_phase) * tune.walk_tail_sway
		SLEEP:
			bob = -tune.sleep_sink + sin(_phase) * tune.sleep_breath
			roll = tune.sleep_roll
			breath = sin(_phase) * tune.sleep_breath
			head_nod = tune.sleep_head_dip
			# Folded knees, and no tail at all: a sleeping animal is still.
			knee_fold = tune.sleep_leg_fold
		EAT:
			squash = envelope * tune.eat_squash
			bob = -envelope * tune.eat_sink
			head_nod = envelope * tune.eat_head_dip
			# Chews: whole cycles of a raised cosine, so the jaw both opens and
			# shuts and is closed again at either end of the meal.
			jaw_open = (
				envelope * tune.eat_jaw_open
				* 0.5 * (1.0 - cos(TAU * progress * tune.eat_chews))
			)
		ATTACK:
			forward = envelope * tune.attack_lunge
			pitch = envelope * tune.attack_pitch
			head_nod = envelope * tune.attack_head_thrust
			jaw_open = envelope * tune.attack_jaw_open
			ear_flick = -envelope * tune.attack_ear_pin
		HURT:
			forward = -envelope * tune.hurt_recoil
			pitch = -envelope * tune.hurt_pitch
			roll = envelope * sin(TAU * progress * tune.hurt_shakes) * tune.hurt_roll
			head_nod = -envelope * tune.hurt_head_recoil
			ear_flick = envelope * tune.hurt_ear_flatten
			tail_lift = -envelope * tune.hurt_tail_tuck
		CELEBRATE:
			bob = absf(sin(PI * progress * tune.celebrate_hops)) * tune.celebrate_hop_height
			yaw = TAU * progress * tune.celebrate_spins
			tail_lift = envelope * tune.celebrate_tail_lift
			tail_sway = envelope * sin(TAU * progress * tune.celebrate_wags) * tune.celebrate_tail_wag
		PLAY:
			# Enveloped like every other one-shot. The bounce is a free-running
			# cycle, so without the fade the pose is caught mid-hop at both ends
			# and snaps there.
			bob = absf(sin(_phase)) * envelope * tune.play_bob
			roll = cos(_phase) * envelope * tune.play_roll
			head_nod = sin(_phase) * envelope * tune.play_head_nod
			tail_sway = sin(_phase * 2.0) * envelope * tune.play_tail_wag

	var basis: Basis = Basis.from_euler(Vector3(pitch, yaw, roll))
	basis = basis.scaled(Vector3(1.0 + squash * 0.5, 1.0 - squash, 1.0 + squash * 0.5))
	# Local +Z is forward: creature.gd aims with atan2(direction.x, direction.z)
	# and builds the head at positive z.
	_root.transform = _root_rest * Transform3D(basis, Vector3(0.0, bob, forward))

	_pose(PART_HEAD, Vector3(head_nod, 0.0, 0.0))
	_pose(PART_JAW, Vector3(jaw_open, 0.0, 0.0))
	# Mirrored, so a flick throws both ears outward rather than sideways.
	_pose(PART_EAR_LEFT, Vector3(0.0, 0.0, -ear_flick))
	_pose(PART_EAR_RIGHT, Vector3(0.0, 0.0, ear_flick))
	_pose(PART_TAIL, Vector3(tail_lift, tail_sway, 0.0))
	_breathe(breath)

	for i in LEGS.size():
		var leg_phase: float = _phase + LEG_PHASE[i]
		# Positive rotation about local X swings the paw backwards, so the first
		# half of each leg's cycle is its stance and the second half its swing.
		_pose(LEGS[i], Vector3(sin(leg_phase) * leg_swing, 0.0, 0.0))
		# The knee flexes only while the paw is off the ground, coming forward,
		# and only ever one way. A knee that bends both ways reads as broken.
		var bend: float = maxf(0.0, -sin(leg_phase)) * knee_bend
		_pose(SHINS[i], Vector3(bend + knee_fold, 0.0, 0.0))


## Rotates one part about its own origin, from its rest pose. Missing parts are
## skipped: the animator poses whatever rig it was given.
func _pose(key: StringName, euler: Vector3) -> void:
	var part: Node3D = _parts.get(key)
	if part == null:
		return
	var rest: Transform3D = _rest[key]
	# Composed onto the rest basis rather than replacing it, so a part with a
	# rest orientation of its own — the tilted ears, the tail's droop — keeps it.
	part.transform = Transform3D(Basis.from_euler(euler) * rest.basis, rest.origin)


## Swells the torso's girth. Not its length: the torso capsule's local Y is the
## body's length, and scaling that makes the creature telescope out of its own
## shoulders.
func _breathe(amount: float) -> void:
	var torso: Node3D = _parts.get(PART_TORSO)
	if torso == null:
		return
	var rest: Transform3D = _rest[PART_TORSO]
	var girth: Basis = Basis.from_scale(Vector3(1.0 + amount, 1.0, 1.0 + amount))
	torso.transform = Transform3D(rest.basis * girth, rest.origin)


## An occasional ear flick rather than a constant wobble: a narrow pulse riding
## on a slow cycle, so the ears are still most of the time.
##
## Deliberately not random. The animator is driven from tests as well as from the
## frame loop and has no seeded RNG of its own, and a global randf() here would
## make the pose irreproducible for the sake of one twitch.
func _ear_twitch() -> float:
	var tune: CreatureAnimatorTunables = _tune()
	var period: float = maxf(tune.idle_ear_twitch_period, 0.001)
	var duty: float = clampf(tune.idle_ear_twitch_duty, 0.001, 1.0)
	var through: float = fmod(_time, period) / period
	if through > duty:
		return 0.0
	return sin(PI * through / duty) * tune.idle_ear_twitch


## Tunables, defaulted on first use so the animator works with no wiring at all.
func _tune() -> CreatureAnimatorTunables:
	if tunables == null:
		tunables = CreatureAnimatorTunables.new()
	return tunables
