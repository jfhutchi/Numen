extends GutTest
## Phase 5 acceptance tests for the creature's animation state machine.
##
## Everything here runs on explicit advance() calls with no frame loop and no
## await. Headless physics runs in real time, so a test that walked the creature
## for thirty seconds through _process would cost thirty seconds of wall clock;
## driven directly it costs milliseconds.

const ANIMATOR := preload("res://src/creature/body/creature_animator.gd")
const TUNABLES := preload("res://src/creature/body/creature_animator_tunables.gd")
const ACTION_STATES := preload("res://src/creature/body/creature_action_states.gd")
const OPINIONS := preload("res://src/creature/mind/opinion_store.gd")

## Fine enough to land on a state change promptly, coarse enough to keep the
## step counts small.
const STEP: float = 0.05

## Where the mock body's head sits at rest.
const HEAD_REST := Vector3(0.0, 2.7, 0.25)

## Step used when a test has to catch the last frame of a one-shot. The last
## frame a one-shot poses is one step short of its end, where the sine envelope
## is still sin(PI * step / duration) rather than zero — small enough at this
## step size that the residual pose is a couple of centimetres.
const FINE_STEP: float = 0.005
## What that residue is allowed to be: root probes, then the head on its neck.
const REST_TOLERANCE: float = 0.06
const HEAD_TOLERANCE: float = 0.02
## Across the state boundary the fallback's own idle bob adds to the residue.
const BOUNDARY_TOLERANCE: float = 0.12

var _tunables: CreatureAnimatorTunables
var _animator: CreatureAnimator
var _body: Node3D


func before_each() -> void:
	_tunables = TUNABLES.new()
	_body = _build_body()
	autofree(_body)
	_animator = ANIMATOR.new()
	_animator.tunables = _tunables
	_animator.configure(_body)
	autofree(_animator)


## A stand-in for what creature.gd builds: torso, head and two eyes, at the same
## heights. If those heights ever change, the head-detection heuristic in
## configure() has to be retuned, and this mock is what makes that visible.
func _build_body() -> Node3D:
	var root := Node3D.new()
	root.name = "Body"

	var torso := MeshInstance3D.new()
	torso.position = Vector3(0.0, 1.3, 0.0)
	root.add_child(torso)

	var head := MeshInstance3D.new()
	head.position = HEAD_REST
	root.add_child(head)

	for side: float in [-0.26, 0.26]:
		var eye := MeshInstance3D.new()
		eye.position = Vector3(side, 2.85, 0.78)
		root.add_child(eye)

	return root


func _head() -> Node3D:
	return _body.get_child(1) as Node3D


## Advances until the state changes or the budget runs out. Returns the seconds
## spent, which is the number the duration assertions are really about.
func _run_until_state_leaves(state: StringName, budget_seconds: float) -> float:
	var elapsed: float = 0.0
	while _animator.current_state() == state and elapsed < budget_seconds:
		_animator.advance(STEP)
		elapsed += STEP
	return elapsed


## How far apart two poses of the body root are, measured at probe points spread
## over it. Comparing origins alone would miss a roll or a squash, which is most
## of what a snapping pose actually does.
func _pose_shift(a: Transform3D, b: Transform3D) -> float:
	var worst: float = 0.0
	for probe: Vector3 in [HEAD_REST, Vector3(0.5, 1.3, 0.0), Vector3(0.0, 0.0, 0.5)]:
		worst = maxf(worst, (a * probe).distance_to(b * probe))
	return worst


# --- Transition rules ---------------------------------------------------------

func test_one_shot_plays_for_its_full_duration_then_falls_back() -> void:
	_animator.request_state(ANIMATOR.EAT)
	assert_eq(_animator.current_state(), ANIMATOR.EAT, "the request should have been accepted")

	var duration: float = _tunables.duration_for(ANIMATOR.EAT)
	var elapsed: float = _run_until_state_leaves(ANIMATOR.EAT, 10.0)

	gut.p("eat ran %.2fs (duration %.2fs), then -> %s" % [
		elapsed, duration, _animator.current_state()
	])
	assert_between(elapsed, duration, duration + STEP + 0.001,
		"a one-shot must play its whole duration and not a step longer")
	assert_eq(_animator.current_state(), ANIMATOR.IDLE,
		"a finished one-shot should fall back to idle when the body is not moving")


func test_looping_states_do_not_expire() -> void:
	_animator.request_state(ANIMATOR.SLEEP)
	for i in 400:
		_animator.advance(STEP)
	gut.p("after %.1fs of sleep the state is %s" % [400 * STEP, _animator.current_state()])
	assert_eq(_animator.current_state(), ANIMATOR.SLEEP,
		"sleep loops; nothing should have timed it out")


func test_lower_priority_request_cannot_interrupt_a_one_shot() -> void:
	var timeline: Array[String] = []
	_animator.request_state(ANIMATOR.EAT)
	_animator.advance(STEP)
	timeline.append("eat requested -> %s" % _animator.current_state())

	_animator.request_state(ANIMATOR.WALK)
	timeline.append("walk requested -> %s" % _animator.current_state())
	assert_eq(_animator.current_state(), ANIMATOR.EAT, "walk must not interrupt a meal")

	_animator.request_state(ANIMATOR.IDLE)
	timeline.append("idle requested -> %s" % _animator.current_state())
	assert_eq(_animator.current_state(), ANIMATOR.EAT, "nor should idle")

	_animator.request_state(ANIMATOR.PLAY)
	timeline.append("play requested -> %s" % _animator.current_state())
	assert_eq(_animator.current_state(), ANIMATOR.EAT, "nor should a lower-priority one-shot")

	_animator.set_locomotion_speed(9.0)
	timeline.append("speed 9.0 -> %s" % _animator.current_state())
	assert_eq(_animator.current_state(), ANIMATOR.EAT,
		"the body reporting movement must not cancel an action either")

	for line: String in timeline:
		gut.p(line)


func test_higher_priority_request_does_interrupt_a_one_shot() -> void:
	_animator.request_state(ANIMATOR.EAT)
	_animator.advance(STEP * 3)
	assert_gt(_animator.time_in_state(), 0.0)

	_animator.request_state(ANIMATOR.HURT)
	gut.p("hurt requested %.2fs into eat -> %s (t=%.2f)" % [
		STEP * 3, _animator.current_state(), _animator.time_in_state()
	])
	assert_eq(_animator.current_state(), ANIMATOR.HURT, "being hurt outranks eating")
	assert_eq(_animator.time_in_state(), 0.0, "the interrupting state should start from zero")

	# Nothing is queued: the interrupted meal is gone, not resumed.
	var elapsed: float = _run_until_state_leaves(ANIMATOR.HURT, 10.0)
	gut.p("hurt ran %.2fs, then -> %s" % [elapsed, _animator.current_state()])
	assert_eq(_animator.current_state(), ANIMATOR.IDLE,
		"an interrupted one-shot is dropped, not resumed")


func test_repeating_a_request_does_not_restart_the_one_shot() -> void:
	# Regression. The body asks for a state every frame it wants one. Treating a
	# repeat as a fresh request pins the one-shot at time zero and it never ends.
	_animator.request_state(ANIMATOR.EAT)
	var elapsed: float = 0.0
	while _animator.current_state() == ANIMATOR.EAT and elapsed < 10.0:
		# Re-requested before the step, the way a body would: it wants to eat, so
		# it says so, every frame, until it stops wanting to.
		_animator.request_state(ANIMATOR.EAT)
		_animator.advance(STEP)
		elapsed += STEP

	var duration: float = _tunables.duration_for(ANIMATOR.EAT)
	gut.p("eat, re-requested every step, ran %.2fs (duration %.2fs)" % [elapsed, duration])
	assert_between(elapsed, duration, duration + STEP + 0.001,
		"re-requesting a one-shot every step made it immortal")


func test_a_finished_one_shot_falls_back_to_walk_when_the_body_is_moving() -> void:
	_animator.set_locomotion_speed(7.0)
	assert_eq(_animator.current_state(), ANIMATOR.WALK)

	_animator.request_state(ANIMATOR.ATTACK)
	var elapsed: float = _run_until_state_leaves(ANIMATOR.ATTACK, 10.0)
	gut.p("attack ran %.2fs while moving at 7.0 m/s, then -> %s" % [
		elapsed, _animator.current_state()
	])
	assert_eq(_animator.current_state(), ANIMATOR.WALK,
		"the fallback must read the current speed, not assume a standstill")


func test_unknown_states_are_ignored() -> void:
	_animator.request_state(ANIMATOR.WALK)
	_animator.request_state(&"backflip")
	assert_eq(_animator.current_state(), ANIMATOR.WALK,
		"a bad state name should leave the animation alone, not blank it")


# --- Locomotion blend ---------------------------------------------------------

func test_locomotion_speed_crosses_between_idle_and_walk_at_the_threshold() -> void:
	var threshold: float = _tunables.walk_speed_threshold
	var samples: Array[float] = [
		0.0, threshold - 0.01, threshold, threshold + 0.01, 7.0, 0.0
	]
	var expected: Array[StringName] = [
		ANIMATOR.IDLE, ANIMATOR.IDLE, ANIMATOR.WALK, ANIMATOR.WALK,
		ANIMATOR.WALK, ANIMATOR.IDLE
	]

	for i in samples.size():
		_animator.set_locomotion_speed(samples[i])
		_animator.advance(STEP)
		gut.p("speed %5.2f -> %s" % [samples[i], _animator.current_state()])
		assert_eq(_animator.current_state(), expected[i],
			"speed %.2f against threshold %.2f" % [samples[i], threshold])


func test_locomotion_speed_does_not_wake_a_sleeping_creature() -> void:
	# Regression. The body reports its speed every physics frame. An earlier
	# version let that set any state, so a sleeping creature was knocked to idle
	# on the very next frame and the sleep animation never played at all.
	_animator.request_state(ANIMATOR.SLEEP)
	for i in 100:
		_animator.set_locomotion_speed(0.0)
		_animator.advance(STEP)
	assert_eq(_animator.current_state(), ANIMATOR.SLEEP,
		"reporting a standstill must not replace sleep with idle")

	# But an explicit request still wins: looping states have no immunity.
	_animator.request_state(ANIMATOR.WALK)
	assert_eq(_animator.current_state(), ANIMATOR.WALK,
		"a looping state must still yield to a direct request")


func test_movement_wakes_a_sleeping_creature() -> void:
	# The other half of the rule above. Sleep is immune to a reported standstill,
	# but not to actually moving: with no way out but an explicit request, a
	# creature that dozed off would walk around asleep for the rest of its life.
	_animator.request_state(ANIMATOR.SLEEP)
	for speed: float in [0.0, _tunables.walk_speed_threshold - 0.01]:
		_animator.set_locomotion_speed(speed)
		_animator.advance(STEP)
		gut.p("asleep, speed %.2f -> %s" % [speed, _animator.current_state()])
		assert_eq(_animator.current_state(), ANIMATOR.SLEEP,
			"speed %.2f is a standstill; it must not wake the creature" % speed)

	_animator.set_locomotion_speed(7.0)
	gut.p("asleep, speed 7.00 -> %s" % _animator.current_state())
	assert_eq(_animator.current_state(), ANIMATOR.WALK,
		"a creature moving at walking pace is not asleep any more")


# --- The body actually moves --------------------------------------------------

func test_configure_finds_the_head_and_the_eyes() -> void:
	gut.p("head parts found: %d of %d body parts" % [
		_animator.head_part_count(), _body.get_child_count()
	])
	assert_eq(_animator.head_part_count(), 3,
		"head and two eyes should ride the neck; the torso should not")


func test_reconfiguring_the_same_body_does_not_move_the_rest_pose() -> void:
	# configure() advertises itself as safe to call again. Re-capturing while the
	# body is mid-pose would make the current animated transform the new rest, and
	# every call would leave the creature a little further from where it started.
	_animator.request_state(ANIMATOR.SLEEP)
	for i in 20:
		_animator.advance(STEP)
	gut.p("sunk into sleep at %s" % _body.transform.origin)
	assert_lt(_body.transform.origin.y, -0.1, "sleep should have sunk the body first")

	_animator.configure(_body)
	_animator.request_state(ANIMATOR.IDLE)
	_animator.advance(STEP)

	gut.p("after re-configuring and returning to idle: %s" % _body.transform.origin)
	assert_eq(_animator.head_part_count(), 3, "the head parts should still be found")
	assert_lt(_pose_shift(_body.transform, Transform3D.IDENTITY), _tunables.idle_bob + 0.001,
		"re-configuring captured the sleeping pose as the new rest")


func test_the_mesh_parts_move() -> void:
	_animator.set_locomotion_speed(7.0)
	_animator.advance(STEP)
	var root_before: Transform3D = _body.transform
	var head_before: Transform3D = _head().transform

	for i in 8:
		_animator.advance(STEP)

	gut.p("root origin %s -> %s" % [root_before.origin, _body.transform.origin])
	gut.p("head origin %s -> %s" % [head_before.origin, _head().transform.origin])
	assert_false(_body.transform.is_equal_approx(root_before), "the body should be walking")
	assert_false(_head().transform.is_equal_approx(head_before), "the head should be bobbing")


func test_a_long_walk_does_not_drift() -> void:
	# The regression this whole module is arranged around. Poses are recomputed
	# from the captured rest transforms every step; an animator that instead
	# accumulated onto the current transform would leave the creature metres
	# above the island after a couple of minutes of walking.
	_animator.set_locomotion_speed(7.0)

	var furthest_root: float = 0.0
	var furthest_head: float = 0.0
	var steps: int = 1500
	var fine_step: float = 0.02

	for i in steps:
		_animator.advance(fine_step)
		furthest_root = maxf(furthest_root, _body.transform.origin.length())
		furthest_head = maxf(furthest_head, _head().transform.origin.distance_to(HEAD_REST))

	gut.p("after %.0fs of walking: furthest root offset %.4f m, furthest head offset %.4f m" % [
		steps * fine_step, furthest_root, furthest_head
	])
	assert_gt(furthest_root, 0.0, "a walk that never moves the body is not a walk")
	assert_lt(furthest_root, _tunables.walk_bob + 0.01,
		"the body wandered further than the walk bob allows — it is drifting")
	assert_lt(furthest_head, 0.15, "the head drifted off the neck")

	# And it settles back to rest when it stops.
	_animator.set_locomotion_speed(0.0)
	for i in 250:
		_animator.advance(fine_step)
	gut.p("standing still, root origin %s" % _body.transform.origin)
	assert_lt(_body.transform.origin.length(), _tunables.idle_bob + 0.001,
		"an idle creature should sit within a breath of its rest pose")


func test_one_shots_return_the_body_to_rest() -> void:
	# Every one-shot term is enveloped so it is zero at both ends. Without that
	# the pose snaps on the frame the state ends.
	#
	# The measurement has to be taken on the last frame the one-shot itself
	# posed. advance() applies the fallback pose on the very frame it transitions,
	# so a pose read after the state has changed is the idle pose no matter what
	# the one-shot was doing a moment earlier — which is how this test used to
	# pass without being able to fail.
	for state: StringName in [ANIMATOR.EAT, ANIMATOR.ATTACK, ANIMATOR.HURT,
			ANIMATOR.CELEBRATE, ANIMATOR.PLAY]:
		_animator.request_state(state)
		assert_eq(_animator.current_state(), state, "%s was refused" % state)

		var last_body: Transform3D = _body.transform
		var last_head: Transform3D = _head().transform
		var elapsed: float = 0.0
		while elapsed < 10.0:
			_animator.advance(FINE_STEP)
			elapsed += FINE_STEP
			if _animator.current_state() != state:
				break
			last_body = _body.transform
			last_head = _head().transform
		assert_ne(_animator.current_state(), state, "%s never ended" % state)

		# The mock body's root sits at the origin, so its rest pose is identity.
		var from_rest: float = _pose_shift(last_body, Transform3D.IDENTITY)
		var across_boundary: float = _pose_shift(last_body, _body.transform)
		gut.p("%s: last frame %.4f m from rest, %.4f m of head lift, %.4f m across the boundary" % [
			state, from_rest, last_head.origin.distance_to(HEAD_REST), across_boundary
		])
		assert_lt(from_rest, REST_TOLERANCE,
			"%s had not faded out by its last frame; it snaps back at the end" % state)
		assert_lt(last_head.origin.distance_to(HEAD_REST), HEAD_TOLERANCE,
			"%s left the head off its rest on the last frame" % state)
		assert_lt(across_boundary, BOUNDARY_TOLERANCE,
			"%s jumps as the fallback takes over" % state)


func test_it_survives_being_advanced_with_no_body() -> void:
	# The animator is a plain Node; something will eventually tick it before
	# configure() has run. The state machine should still keep time.
	var bare: CreatureAnimator = ANIMATOR.new()
	autofree(bare)
	bare.tunables = _tunables
	bare.request_state(ANIMATOR.CELEBRATE)
	for i in 10:
		bare.advance(STEP)
	assert_eq(bare.current_state(), ANIMATOR.CELEBRATE)
	assert_almost_eq(bare.time_in_state(), 10 * STEP, 0.0001)


# --- Action mapping -----------------------------------------------------------

func test_every_mind_action_maps_to_a_real_state() -> void:
	for action: StringName in OPINIONS.ALL_ACTIONS:
		var state: StringName = ACTION_STATES.for_action(action)
		gut.p("%-16s -> %s" % [action, state])
		assert_true(ANIMATOR.STATES.has(state),
			"action '%s' maps to '%s', which is not a state" % [action, state])
		# And the animator agrees it is real, rather than silently ignoring it.
		# Advancing well past any duration first expires whatever the previous
		# action left playing, so this measures the mapping and not the priority
		# rules.
		_animator.advance(10.0)
		_animator.request_state(state)
		assert_eq(_animator.current_state(), state,
			"the animator refused the state mapped from '%s'" % action)


func test_unknown_actions_fall_back_to_idle() -> void:
	assert_eq(ACTION_STATES.for_action(&"invent_democracy"), ANIMATOR.IDLE)
	assert_eq(ACTION_STATES.for_action(&""), ANIMATOR.IDLE)


func test_the_obvious_mappings_are_the_obvious_ones() -> void:
	assert_eq(ACTION_STATES.for_action(&"eat"), ANIMATOR.EAT)
	assert_eq(ACTION_STATES.for_action(&"attack"), ANIMATOR.ATTACK)
	assert_eq(ACTION_STATES.for_action(&"sleep"), ANIMATOR.SLEEP)
	assert_eq(ACTION_STATES.for_action(&"play_with"), ANIMATOR.PLAY)
	assert_eq(ACTION_STATES.for_action(&"dance"), ANIMATOR.CELEBRATE)
	assert_eq(ACTION_STATES.for_action(&"follow_player"), ANIMATOR.WALK)
