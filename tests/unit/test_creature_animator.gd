extends GutTest
## Acceptance tests for the creature's animation state machine.
##
## Everything here runs on explicit advance() calls with no frame loop and no
## await. Headless physics runs in real time, so a test that walked the creature
## for thirty seconds through _process would cost thirty seconds of wall clock;
## driven directly it costs milliseconds.
##
## The rig under test is the real one, built by Creature.build_rig(). A mock body
## was the old arrangement and it drifted out of step with the real geometry
## silently — which is how the animator ended up with a head-by-height heuristic
## that could not tell a front leg from a rear one.

const CREATURE := preload("res://src/creature/body/creature.gd")
const ANIMATOR := preload("res://src/creature/body/creature_animator.gd")
const TUNABLES := preload("res://src/creature/body/creature_animator_tunables.gd")
const ACTION_STATES := preload("res://src/creature/body/creature_action_states.gd")
const OPINIONS := preload("res://src/creature/mind/opinion_store.gd")

## Fine enough to land on a state change promptly, coarse enough to keep the
## step counts small.
const STEP: float = 0.05

## Step used when a test has to catch the last frame of a one-shot. The last
## frame a one-shot poses is one step short of its end, where the sine envelope
## is still sin(PI * step / duration) rather than zero — small enough at this
## step size that the residual pose is a couple of centimetres.
const FINE_STEP: float = 0.005
## What that residue is allowed to be: root probes, then each articulated part
## measured at the end of a one-metre lever.
const REST_TOLERANCE: float = 0.06
const PART_TOLERANCE: float = 0.03
## Across the state boundary the fallback's own idle bob adds to the residue.
const BOUNDARY_TOLERANCE: float = 0.12

var _tunables: CreatureAnimatorTunables
var _animator: CreatureAnimator
var _body: Node3D
var _parts: Dictionary[StringName, Node3D]
## The rig exactly as it was built, captured before the animator has touched it.
## Tests that ask "is this part back where it started" need the real rest pose,
## not whatever idle happens to be doing on frame zero.
var _rest_pose: Dictionary[StringName, Transform3D]


func before_each() -> void:
	_tunables = TUNABLES.new()
	_body = Node3D.new()
	_body.name = "Body"
	# In the tree so global_position works: the rig nests knees under hips and
	# ears under the head, and the drift test needs the composed result.
	add_child_autofree(_body)
	_parts = CREATURE.build_rig(_body)
	_rest_pose.clear()
	for key: StringName in _parts:
		_rest_pose[key] = _parts[key].transform

	_animator = ANIMATOR.new()
	_animator.tunables = _tunables
	_animator.configure(_body)
	_animator.bind_parts(_parts)
	autofree(_animator)


func _part(key: StringName) -> Node3D:
	return _parts.get(key)


func _head() -> Node3D:
	return _part(ANIMATOR.PART_HEAD)


func _rest(key: StringName) -> Transform3D:
	return _rest_pose[key]


## Advances until the state changes or the budget runs out. Returns the seconds
## spent, which is the number the duration assertions are really about.
func _run_until_state_leaves(state: StringName, budget_seconds: float) -> float:
	var elapsed: float = 0.0
	while _animator.current_state() == state and elapsed < budget_seconds:
		_animator.advance(STEP)
		elapsed += STEP
	return elapsed


## How far apart two poses of the body root are, measured at probe points spread
## over the rig. Comparing origins alone would miss a roll or a squash, which is
## most of what a snapping pose actually does.
func _pose_shift(a: Transform3D, b: Transform3D) -> float:
	var probes: Array[Vector3] = [
		CREATURE.NECK,
		Vector3(CREATURE.LEG_SPREAD_X, CREATURE.HIP_HEIGHT, CREATURE.FRONT_LEG_Z),
		CREATURE.TAIL_BASE,
	]
	var worst: float = 0.0
	for probe: Vector3 in probes:
		worst = maxf(worst, (a * probe).distance_to(b * probe))
	return worst


## How far one part's pose has moved from a reference, measured at the end of a
## one-metre lever on each axis. That turns a residual angle into metres instead
## of having to be teased out of an euler triple — which for the tail, whose rest
## pose is already a big rotation, cannot be read off .rotation at all.
func _part_gap(a: Transform3D, b: Transform3D) -> float:
	var worst: float = 0.0
	for probe: Vector3 in [Vector3.DOWN, Vector3.FORWARD, Vector3.RIGHT]:
		worst = maxf(worst, (a * probe).distance_to(b * probe))
	return worst


## How far a live part has moved from its captured rest pose.
func _from_rest(key: StringName) -> float:
	return _part_gap(_part(key).transform, _rest(key))


## Sideways lean of the tail: the x component of the direction it points, which is
## monotonic in the sway angle whatever the tail is also doing vertically.
func _tail_sway() -> float:
	return _part(ANIMATOR.PART_TAIL).transform.basis.y.x


## Pearson correlation of two equal-length samples. Zero when either is flat,
## which for these tests means "that leg never moved".
func _correlation(a: Array, b: Array) -> float:
	var n: int = mini(a.size(), b.size())
	if n == 0:
		return 0.0
	var mean_a: float = 0.0
	var mean_b: float = 0.0
	for i in n:
		mean_a += a[i]
		mean_b += b[i]
	mean_a /= n
	mean_b /= n
	var covariance: float = 0.0
	var variance_a: float = 0.0
	var variance_b: float = 0.0
	for i in n:
		var da: float = a[i] - mean_a
		var db: float = b[i] - mean_b
		covariance += da * db
		variance_a += da * da
		variance_b += db * db
	if variance_a <= 0.0 or variance_b <= 0.0:
		return 0.0
	return covariance / sqrt(variance_a * variance_b)


## Samples every leg's hip angle over a stretch of walking.
func _sample_legs(steps: int, step: float) -> Array[Array]:
	var series: Array[Array] = [[], [], [], []]
	for i in steps:
		_animator.advance(step)
		for leg in ANIMATOR.LEGS.size():
			series[leg].append(_part(ANIMATOR.LEGS[leg]).rotation.x)
	return series


## Counts direction changes of the tail's sway over a stretch of time.
func _count_tail_reversals(seconds: float) -> int:
	var reversals: int = 0
	var rising: bool = true
	var previous: float = _tail_sway()
	var elapsed: float = 0.0
	while elapsed < seconds:
		_animator.advance(FINE_STEP)
		elapsed += FINE_STEP
		var current: float = _tail_sway()
		if rising and current < previous:
			reversals += 1
			rising = false
		elif not rising and current > previous:
			rising = true
		previous = current
	return reversals


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


func test_hurt_interrupts_a_walk_and_idle_does_not_interrupt_a_meal() -> void:
	# The two priority rules the body actually depends on, stated plainly.
	_animator.set_locomotion_speed(7.0)
	_animator.advance(STEP)
	assert_eq(_animator.current_state(), ANIMATOR.WALK)
	_animator.request_state(ANIMATOR.HURT)
	gut.p("slapped mid-walk -> %s" % _animator.current_state())
	assert_eq(_animator.current_state(), ANIMATOR.HURT, "a slap must land while the creature walks")

	_animator.advance(10.0)
	_animator.set_locomotion_speed(0.0)
	_animator.request_state(ANIMATOR.EAT)
	_animator.advance(STEP)
	_animator.request_state(ANIMATOR.IDLE)
	gut.p("idle requested mid-meal -> %s" % _animator.current_state())
	assert_eq(_animator.current_state(), ANIMATOR.EAT, "idle must never cut a meal short")


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


# --- The gait -----------------------------------------------------------------

func test_the_rig_supplies_every_part_the_animator_articulates() -> void:
	# The animator poses whatever it was handed and cannot notice a part it never
	# got, so a renamed leg would be a silently stiff leg. This is the guard.
	var articulated: Array[StringName] = [
		ANIMATOR.PART_TORSO, ANIMATOR.PART_HEAD, ANIMATOR.PART_JAW,
		ANIMATOR.PART_EAR_LEFT, ANIMATOR.PART_EAR_RIGHT, ANIMATOR.PART_TAIL,
	]
	articulated.append_array(ANIMATOR.LEGS)
	articulated.append_array(ANIMATOR.SHINS)
	for key: StringName in articulated:
		assert_true(_animator.has_part(key), "the animator was never given '%s'" % key)
	gut.p("%d parts bound, %d of them articulated" % [
		_animator.part_count(), articulated.size()
	])


func test_diagonal_leg_pairs_swing_together_and_against_the_other_pair() -> void:
	# The test that proves it walks rather than shuffles. A trot: front-left moves
	# with rear-right, and both against front-right and rear-left. Correlation
	# rather than eyeballed peaks, because for a sinusoidal pair the correlation
	# IS the cosine of the phase offset, so its sign is the whole claim.
	_animator.set_locomotion_speed(7.0)
	var series: Array[Array] = _sample_legs(240, 0.01)

	var pairs: Array = [
		["front-left/rear-right", 0, 3, 1.0],
		["front-right/rear-left", 1, 2, 1.0],
		["front-left/front-right", 0, 1, -1.0],
		["front-left/rear-left", 0, 2, -1.0],
		["rear-right/front-right", 3, 1, -1.0],
	]
	for pair: Array in pairs:
		var label: String = pair[0]
		var correlation: float = _correlation(series[pair[1]], series[pair[2]])
		var offset: float = rad_to_deg(acos(clampf(correlation, -1.0, 1.0)))
		gut.p("%-24s correlation %+.4f -> phase offset %6.1f deg" % [label, correlation, offset])
		if float(pair[3]) > 0.0:
			assert_gt(correlation, 0.98, "%s should be in phase — that is the diagonal pair" % label)
			assert_lt(offset, 10.0, "%s is not close enough to zero phase offset" % label)
		else:
			assert_lt(correlation, -0.98, "%s should be in antiphase, not shuffling" % label)
			assert_gt(offset, 170.0, "%s is not close enough to half a cycle apart" % label)


func test_every_leg_actually_swings() -> void:
	# Guards the correlation test above, which a rig with four frozen legs would
	# otherwise pass by way of _correlation() returning zero.
	_animator.set_locomotion_speed(7.0)
	var series: Array[Array] = _sample_legs(240, 0.01)
	for i in ANIMATOR.LEGS.size():
		var lowest: float = INF
		var highest: float = -INF
		for value: float in series[i]:
			lowest = minf(lowest, value)
			highest = maxf(highest, value)
		gut.p("%-16s swings %+.3f .. %+.3f rad" % [ANIMATOR.LEGS[i], lowest, highest])
		assert_gt(highest - lowest, _tunables.walk_leg_swing,
			"%s barely moves" % ANIMATOR.LEGS[i])


func test_leg_swing_and_knee_bend_stay_within_their_bounds() -> void:
	# A leg swung too far rotates its thigh up through the torso and the paw comes
	# out of the creature's own ribs. Run at the top of the rate clamp, where the
	# cycle is fastest and any accumulation would show soonest.
	_animator.set_locomotion_speed(20.0)
	var worst_swing: float = 0.0
	var worst_bend: float = 0.0
	var backwards_knee: float = 0.0
	for i in 600:
		_animator.advance(0.02)
		for leg in ANIMATOR.LEGS.size():
			worst_swing = maxf(worst_swing, absf(_part(ANIMATOR.LEGS[leg]).rotation.x))
			var bend: float = _part(ANIMATOR.SHINS[leg]).rotation.x
			worst_bend = maxf(worst_bend, bend)
			backwards_knee = minf(backwards_knee, bend)

	gut.p("worst hip swing %.4f rad (bound %.2f), worst knee bend %.4f rad (bound %.2f)" % [
		worst_swing, _tunables.walk_leg_swing, worst_bend, _tunables.walk_knee_bend
	])
	assert_lte(worst_swing, _tunables.walk_leg_swing + 0.001, "the hip swung past its amplitude")
	assert_lte(worst_bend, _tunables.walk_knee_bend + 0.001, "the knee bent past its amplitude")
	assert_gte(backwards_knee, -0.001, "the knee bent the wrong way, which reads as a broken leg")
	assert_lt(_tunables.walk_leg_swing, 0.7,
		"a swing this wide puts the thigh inside the torso whatever the animator does")


func test_faster_locomotion_produces_a_faster_gait() -> void:
	var seconds: float = 6.0
	var slow: int = _count_gait_cycles(3.0, seconds)
	var fast: int = _count_gait_cycles(20.0, seconds)
	gut.p("over %.0fs: %d gait cycles at 3 m/s, %d at 20 m/s (rate clamp %.2f..%.2f of %.2f Hz)" % [
		seconds, slow, fast, _tunables.walk_rate_min, _tunables.walk_rate_max,
		_tunables.walk_frequency
	])
	assert_gt(slow, 0, "the gait froze at walking pace")
	assert_gt(float(fast), float(slow) * 1.8,
		"running should take visibly more strides per second than plodding")


## Counts strides by watching the front-left hip cross from swing into stance.
func _count_gait_cycles(speed: float, seconds: float) -> int:
	_animator.set_locomotion_speed(speed)
	var leg: Node3D = _part(ANIMATOR.LEGS[0])
	var previous: float = leg.rotation.x
	var cycles: int = 0
	var elapsed: float = 0.0
	while elapsed < seconds:
		_animator.advance(0.01)
		elapsed += 0.01
		var current: float = leg.rotation.x
		if previous <= 0.0 and current > 0.0:
			cycles += 1
		previous = current
	return cycles


func test_walking_sways_the_tail_and_bobs_the_body() -> void:
	_animator.set_locomotion_speed(7.0)
	var worst_sway: float = 0.0
	var worst_bob: float = 0.0
	for i in 200:
		_animator.advance(0.01)
		worst_sway = maxf(worst_sway, _from_rest(ANIMATOR.PART_TAIL))
		worst_bob = maxf(worst_bob, absf(_body.transform.origin.y))
	gut.p("walking: tail moves up to %.3f m at a metre of lever, body bobs %.3f m" % [
		worst_sway, worst_bob
	])
	assert_gt(worst_sway, 0.05, "the tail should sway as it walks")
	assert_gt(worst_bob, _tunables.walk_bob * 0.5, "the body should bob as it walks")


# --- Per-state articulation ---------------------------------------------------

func test_eating_opens_and_closes_the_jaw_then_leaves_it_shut() -> void:
	var jaw: Node3D = _part(ANIMATOR.PART_JAW)
	_animator.request_state(ANIMATOR.EAT)

	var widest: float = 0.0
	var opened: bool = false
	var chewed: bool = false
	while _animator.current_state() == ANIMATOR.EAT:
		_animator.advance(FINE_STEP)
		var angle: float = jaw.rotation.x
		widest = maxf(widest, angle)
		if angle > _tunables.eat_jaw_open * 0.5:
			opened = true
		elif opened and angle < _tunables.eat_jaw_open * 0.1:
			# Open, then shut again: that is a chew rather than a gape.
			chewed = true

	gut.p("eat: jaw opened to %.3f rad (bound %.2f), chewed %s, ends %.5f m from rest" % [
		widest, _tunables.eat_jaw_open, chewed, _from_rest(ANIMATOR.PART_JAW)
	])
	assert_gt(widest, _tunables.eat_jaw_open * 0.5, "the jaw never really opened")
	assert_lte(widest, _tunables.eat_jaw_open + 0.001, "the jaw opened past its bound")
	assert_true(chewed, "the jaw opened and stayed open; eating should chew")
	assert_lt(_from_rest(ANIMATOR.PART_JAW), 0.001, "the jaw was left hanging open")


func test_eating_puts_the_head_down() -> void:
	var head: Node3D = _head()
	_animator.request_state(ANIMATOR.EAT)
	var deepest: float = 0.0
	var lowest: float = 0.0
	while _animator.current_state() == ANIMATOR.EAT:
		_animator.advance(FINE_STEP)
		deepest = maxf(deepest, head.rotation.x)
		lowest = minf(lowest, _body.transform.origin.y)
	gut.p("eat: head dipped %.3f rad (dip %.2f), body sank %.3f m (sink %.2f)" % [
		deepest, _tunables.eat_head_dip, lowest, _tunables.eat_sink
	])
	# Positive rotation about X noses the head down and forward.
	assert_gt(deepest, _tunables.eat_head_dip * 0.8, "the head never went down to the food")
	assert_lt(lowest, -_tunables.eat_sink * 0.8, "the body should stoop with it")


func test_sleep_sinks_the_body_folds_the_knees_and_stills_the_tail() -> void:
	_animator.request_state(ANIMATOR.SLEEP)
	var lowest: float = 0.0
	var worst_tail: float = 0.0
	for i in 300:
		_animator.advance(0.02)
		lowest = minf(lowest, _body.transform.origin.y)
		worst_tail = maxf(worst_tail, _from_rest(ANIMATOR.PART_TAIL))

	var folds: Array[float] = []
	for key: StringName in ANIMATOR.SHINS:
		folds.append(_part(key).rotation.x)
	gut.p("sleep: body sank to %.3f m, knees folded %s, tail moved %.5f m" % [
		lowest, folds, worst_tail
	])
	assert_lt(lowest, -_tunables.sleep_sink * 0.9, "a sleeping creature should sink")
	for fold: float in folds:
		assert_gt(fold, _tunables.sleep_leg_fold * 0.9, "the knees should fold to lie down")
	assert_lt(worst_tail, 0.001, "a sleeping creature's tail should be still")
	assert_gt(_head().rotation.x, _tunables.sleep_head_dip * 0.9, "the head should rest low")


func test_idle_breathes_and_twitches_an_ear() -> void:
	var torso: Node3D = _part(ANIMATOR.PART_TORSO)
	_animator.request_state(ANIMATOR.IDLE)

	var widest_breath: float = 0.0
	var worst_flick: float = 0.0
	var still_frames: int = 0
	var frames: int = 1200
	for i in frames:
		_animator.advance(0.01)
		widest_breath = maxf(widest_breath, absf(torso.scale.x - 1.0))
		var flick: float = _from_rest(ANIMATOR.PART_EAR_LEFT)
		worst_flick = maxf(worst_flick, flick)
		if flick < 0.001:
			still_frames += 1

	gut.p("idle over %.0fs: girth varies %.4f, ear flicks to %.3f m, still %d of %d frames" % [
		frames * 0.01, widest_breath, worst_flick, still_frames, frames
	])
	assert_gt(widest_breath, _tunables.idle_breath * 0.5, "an idle creature should breathe")
	assert_gt(worst_flick, 0.05, "an idle creature should twitch its ears")
	assert_gt(still_frames, frames / 2,
		"the ears wave constantly; a twitch is meant to be occasional")


func test_attack_lunges_forward_and_thrusts_the_head() -> void:
	_animator.request_state(ANIMATOR.ATTACK)
	var furthest: float = 0.0
	var thrust: float = 0.0
	while _animator.current_state() == ANIMATOR.ATTACK:
		_animator.advance(FINE_STEP)
		furthest = maxf(furthest, _body.transform.origin.z)
		thrust = maxf(thrust, _head().rotation.x)
	gut.p("attack: lunged %.3f m forward (lunge %.2f), head thrust %.3f rad" % [
		furthest, _tunables.attack_lunge, thrust
	])
	# Forward is +Z, the direction creature.gd steers toward.
	assert_gt(furthest, _tunables.attack_lunge * 0.8, "the lunge should carry the body forward")
	assert_gt(thrust, _tunables.attack_head_thrust * 0.8, "and throw the head at the target")


func test_hurt_recoils_backwards_and_flattens_the_ears() -> void:
	_animator.request_state(ANIMATOR.HURT)
	var furthest: float = 0.0
	var worst_ear: float = 0.0
	var recoiled_head: float = 0.0
	while _animator.current_state() == ANIMATOR.HURT:
		_animator.advance(FINE_STEP)
		furthest = minf(furthest, _body.transform.origin.z)
		worst_ear = maxf(worst_ear, _from_rest(ANIMATOR.PART_EAR_LEFT))
		recoiled_head = minf(recoiled_head, _head().rotation.x)
	gut.p("hurt: recoiled %.3f m (recoil %.2f), ears moved %.3f m, head back %.3f rad" % [
		furthest, _tunables.hurt_recoil, worst_ear, recoiled_head
	])
	assert_lt(furthest, -_tunables.hurt_recoil * 0.8, "a flinch should carry the body backwards")
	assert_gt(worst_ear, 0.1, "the ears should go flat when it is hit")
	assert_lt(recoiled_head, -_tunables.hurt_head_recoil * 0.8, "the head should be thrown back")


func test_celebrate_bounces_and_wags_the_tail_faster_than_idle() -> void:
	var window: float = _tunables.duration_for(ANIMATOR.CELEBRATE)
	var idle_wags: int = _count_tail_reversals(window)

	_animator.request_state(ANIMATOR.CELEBRATE)
	var highest: float = 0.0
	var worst_tail: float = 0.0
	var wags: int = 0
	var rising: bool = true
	var previous: float = _tail_sway()
	while _animator.current_state() == ANIMATOR.CELEBRATE:
		_animator.advance(FINE_STEP)
		highest = maxf(highest, _body.transform.origin.y)
		worst_tail = maxf(worst_tail, _from_rest(ANIMATOR.PART_TAIL))
		var current: float = _tail_sway()
		if rising and current < previous:
			wags += 1
			rising = false
		elif not rising and current > previous:
			rising = true
		previous = current

	gut.p("celebrate: hopped to %.3f m, tail moved %.3f m, %d wags against %d over the same %.1fs idle" % [
		highest, worst_tail, wags, idle_wags, window
	])
	assert_gt(highest, _tunables.celebrate_hop_height * 0.5, "the pet response should bounce")
	assert_gt(worst_tail, 0.2, "the pet response should wag the tail")
	assert_gt(wags, idle_wags, "the tail should wag faster than it idles")


# --- The body actually moves --------------------------------------------------

func test_reconfiguring_the_same_body_does_not_move_the_rest_pose() -> void:
	# configure() advertises itself as safe to call again. Re-capturing while the
	# body is mid-pose would make the current animated transform the new rest, and
	# every call would leave the creature a little further from where it started.
	_animator.request_state(ANIMATOR.SLEEP)
	for i in 20:
		_animator.advance(STEP)
	gut.p("sunk into sleep at %s, head %.3f m off its rest" % [
		_body.transform.origin, _from_rest(ANIMATOR.PART_HEAD)
	])
	assert_lt(_body.transform.origin.y, -0.1, "sleep should have sunk the body first")
	assert_gt(_from_rest(ANIMATOR.PART_HEAD), 0.1, "and dipped the head")

	_animator.configure(_body)
	_animator.bind_parts(_parts)
	_animator.request_state(ANIMATOR.IDLE)
	_animator.advance(STEP)

	gut.p("after re-configuring and returning to idle: %s, head %.4f m off rest" % [
		_body.transform.origin, _from_rest(ANIMATOR.PART_HEAD)
	])
	assert_true(_animator.has_part(ANIMATOR.PART_HEAD), "the head binding was lost")
	assert_lt(_pose_shift(_body.transform, Transform3D.IDENTITY), _tunables.idle_bob + 0.001,
		"re-configuring captured the sleeping pose as the new rest")
	assert_lt(_from_rest(ANIMATOR.PART_HEAD), _tunables.idle_head_nod + 0.001,
		"re-configuring captured the dipped head as the new rest")


func test_the_rig_parts_move() -> void:
	_animator.set_locomotion_speed(7.0)
	_animator.advance(STEP)
	var root_before: Transform3D = _body.transform
	var head_before: Transform3D = _head().transform
	var leg: Node3D = _part(ANIMATOR.LEGS[0])
	var leg_before: Transform3D = leg.transform

	for i in 8:
		_animator.advance(STEP)

	gut.p("root origin %s -> %s" % [root_before.origin, _body.transform.origin])
	gut.p("head moved %.4f m, front-left hip moved %.4f m (at a metre of lever)" % [
		_part_gap(_head().transform, head_before), _part_gap(leg.transform, leg_before)
	])
	assert_false(_body.transform.is_equal_approx(root_before), "the body should be walking")
	assert_false(_head().transform.is_equal_approx(head_before), "the head should be bobbing")
	assert_false(leg.transform.is_equal_approx(leg_before), "the legs should be swinging")


func test_a_long_walk_does_not_drift() -> void:
	# The regression this whole module is arranged around. Poses are recomputed
	# from the captured rest transforms every step; an animator that instead
	# accumulated onto the current transform would leave the creature metres
	# above the island after a couple of minutes of walking.
	var rest_world: Dictionary[StringName, Vector3] = {}
	for key: StringName in _parts:
		rest_world[key] = _parts[key].global_position

	_animator.set_locomotion_speed(7.0)

	var furthest_root: float = 0.0
	var furthest_part: float = 0.0
	var furthest_name: StringName = &""
	var worst_slide: float = 0.0
	var steps: int = 1500
	var fine_step: float = 0.02

	for i in steps:
		_animator.advance(fine_step)
		furthest_root = maxf(furthest_root, _body.transform.origin.length())
		for key: StringName in _parts:
			var part: Node3D = _parts[key]
			# Parts are only ever rotated about their own origin, so any change to
			# a local origin at all is the animator having translated something.
			worst_slide = maxf(worst_slide, part.position.distance_to(_rest(key).origin))
			var moved: float = part.global_position.distance_to(rest_world[key])
			if moved > furthest_part:
				furthest_part = moved
				furthest_name = key

	gut.p("after %.0fs of walking: root offset %.4f m, worst part %s at %.4f m, slide %.6f m" % [
		steps * fine_step, furthest_root, furthest_name, furthest_part, worst_slide
	])
	assert_gt(furthest_root, 0.0, "a walk that never moves the body is not a walk")
	assert_lt(furthest_root, _tunables.walk_bob + 0.01,
		"the body wandered further than the walk bob allows — it is drifting")
	assert_lt(worst_slide, 0.0001, "a part was translated; parts may only rotate about their joint")
	assert_lt(furthest_part, 0.6, "a part has wandered away from the body")

	# And it settles back to rest when it stops.
	_animator.set_locomotion_speed(0.0)
	for i in 250:
		_animator.advance(fine_step)
	var settled: float = 0.0
	for key: StringName in _parts:
		settled = maxf(settled, _parts[key].global_position.distance_to(rest_world[key]))
	gut.p("standing still: root origin %s, worst part %.4f m from rest" % [
		_body.transform.origin, settled
	])
	assert_lt(_body.transform.origin.length(), _tunables.idle_bob + 0.001,
		"an idle creature should sit within a breath of its rest pose")
	assert_lt(settled, 0.15, "the rig did not settle back onto the body")


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
		var last_parts: Dictionary[StringName, Transform3D] = {}
		var elapsed: float = 0.0
		while elapsed < 10.0:
			_animator.advance(FINE_STEP)
			elapsed += FINE_STEP
			if _animator.current_state() != state:
				break
			last_body = _body.transform
			for key: StringName in _parts:
				last_parts[key] = _parts[key].transform
		assert_ne(_animator.current_state(), state, "%s never ended" % state)

		# The rig's root sits at the origin, so its rest pose is identity.
		var from_rest: float = _pose_shift(last_body, Transform3D.IDENTITY)
		var across_boundary: float = _pose_shift(last_body, _body.transform)
		var worst_part: float = 0.0
		var worst_name: StringName = &""
		for key: StringName in last_parts:
			var shift: float = _part_gap(last_parts[key], _rest(key))
			if shift > worst_part:
				worst_part = shift
				worst_name = key
		gut.p("%s: last frame %.4f m from rest, worst part %s at %.4f m, %.4f m across the boundary" % [
			state, from_rest, worst_name, worst_part, across_boundary
		])
		assert_lt(from_rest, REST_TOLERANCE,
			"%s had not faded out by its last frame; it snaps back at the end" % state)
		assert_lt(worst_part, PART_TOLERANCE,
			"%s left %s off its rest pose on the last frame" % [state, worst_name])
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


func test_it_survives_a_rig_with_parts_missing() -> void:
	# Nothing guarantees a caller hands over a complete rig, and a half-built one
	# must animate what it has rather than crash the frame loop.
	var sparse: Dictionary[StringName, Node3D] = {}
	sparse[ANIMATOR.PART_HEAD] = _head()
	_animator.bind_parts(sparse)
	_animator.set_locomotion_speed(7.0)
	for i in 20:
		_animator.advance(STEP)
	gut.p("bound %d parts; the head still poses, the legs are left at rest" % _animator.part_count())
	assert_eq(_animator.part_count(), 1)
	assert_false(_animator.has_part(ANIMATOR.LEGS[0]))
	assert_lt(_from_rest(ANIMATOR.LEGS[0]), 0.0001, "an unbound leg must be left alone")
	assert_gt(_from_rest(ANIMATOR.PART_HEAD), 0.0, "the head it was given should still animate")


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
