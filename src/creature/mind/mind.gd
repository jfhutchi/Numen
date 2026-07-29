class_name CreatureMind
extends RefCounted
## The creature's mind: beliefs, desires, opinions, and the choice between them.
##
## Deliberately a RefCounted with no scene dependency. It reads the world through
## anything exposing `query_near(centre, radius, types)` — the live registry in
## game, a bare instance of the same class in tests. That seam is why the whole
## learning system runs headless (ADR-003).

signal acted(option: Dictionary)
signal feedback_received(record: Dictionary)

## One candidate the creature is weighing up.
class Option:
	extends RefCounted
	var desire: StringName
	var action: StringName
	var object: WorldObject
	var desire_level: float = 0.0
	var opinion: float = 0.0
	var distance: float = 0.0
	var score: float = 0.0
	var probability: float = 0.0

	func describe() -> String:
		return "%s(%s) for %s" % [
			action, "self" if object == null else str(object), desire
		]


var tunables: MindTunables
var beliefs: BeliefTable
var desires: Desires
var opinions: OpinionStore

## Internal state, all in [0,1].
var hunger: float = 0.5
var fatigue: float = 0.2
var damage: float = 0.0
var idle: float = 0.3
var age_seconds: float = 0.0
## Exponential moving average of the moral weight of what it has done.
var alignment: float = 0.0

var _world: Object = null
var _position: Vector3 = Vector3.ZERO
var _rng := RandomNumberGenerator.new()
## Actions awaiting a verdict from the player: {desire, action, attributes, time}.
var _pending: Array[Dictionary] = []
var _recent_feedback: Array[Dictionary] = []
var _last_options: Array[Option] = []
var _last_choice: Option = null
var _clock: float = 0.0


func _init(mind_tunables: MindTunables = null, seed_value: int = 0) -> void:
	tunables = mind_tunables if mind_tunables != null else MindTunables.new()
	beliefs = BeliefTable.new(tunables)
	desires = Desires.new(tunables)
	opinions = OpinionStore.new(tunables)
	_rng.seed = seed_value


func bind_world(world: Object, at: Vector3 = Vector3.ZERO) -> void:
	_world = world
	_position = at


func set_position(at: Vector3) -> void:
	_position = at


func position() -> Vector3:
	return _position


func now() -> float:
	return _clock


func advance_clock(delta: float) -> void:
	_clock += delta
	age_seconds += delta


## The situation vector every desire perceptron reads.
func situation() -> PackedFloat32Array:
	var inputs := PackedFloat32Array()
	inputs.resize(Desires.INPUT_COUNT)
	inputs[Desires.IN_HUNGER] = hunger
	inputs[Desires.IN_FATIGUE] = fatigue
	inputs[Desires.IN_DAMAGE] = damage
	inputs[Desires.IN_IDLE] = idle
	inputs[Desires.IN_FOOD_NEAR] = _proximity([&"food_pile", &"wheat_field"])
	inputs[Desires.IN_VILLAGER_NEAR] = _proximity([&"villager"])
	inputs[Desires.IN_THREAT_NEAR] = _proximity([&"enemy_villager", &"creature"])
	return inputs


## Everything within perception range, with beliefs updated by having looked.
func perceive() -> Array[WorldObject]:
	if _world == null:
		return []
	var seen: Array[WorldObject] = _world.query_near(_position, tunables.perception_radius)
	for object: WorldObject in seen:
		beliefs.observe_truth(object)
	return seen


## Scores every (action, object) pair the creature's strongest desires suggest,
## and assigns each a selection probability.
func evaluate_options() -> Array[Option]:
	var inputs: PackedFloat32Array = situation()
	var levels: Dictionary[StringName, float] = desires.intensities(inputs)
	var top: Array[StringName] = desires.strongest(inputs, tunables.top_desires)
	var visible: Array[WorldObject] = perceive()

	var options: Array[Option] = []
	for desire: StringName in top:
		var actions: Array = OpinionStore.ACTIONS_FOR_DESIRE.get(desire, [])
		for action: StringName in actions:
			for object: WorldObject in visible:
				var option := Option.new()
				option.desire = desire
				option.action = action
				option.object = object
				option.desire_level = levels[desire]
				var belief: PackedFloat32Array = beliefs.belief_for(object)
				option.opinion = opinions.predict(desire, action, belief)
				option.distance = _position.distance_to(object.current_position())
				option.score = (
					option.desire_level
					* option.opinion
					/ (1.0 + option.distance / maxf(tunables.distance_falloff, 0.001))
				)
				options.append(option)

	_assign_probabilities(options)
	_last_options = options
	return options


## Picks one option, sampling from the softmax rather than always taking the
## best. Temperature falls with age: the creature explores when young and
## exploits what it has learned when old.
func choose() -> Option:
	var options: Array[Option] = evaluate_options()
	if options.is_empty():
		_last_choice = null
		return null

	var roll: float = _rng.randf()
	var cumulative: float = 0.0
	var chosen: Option = options[options.size() - 1]
	for option: Option in options:
		cumulative += option.probability
		if roll <= cumulative:
			chosen = option
			break

	_last_choice = chosen
	return chosen


## Carries out an option: records it as awaiting the player's verdict, and
## applies whatever the world itself has to say about it.
func perform(option: Option) -> void:
	if option == null:
		return
	var belief: PackedFloat32Array = beliefs.belief_for(option.object) if option.object != null \
		else PackedFloat32Array()
	_pending.append({
		"desire": option.desire,
		"action": option.action,
		"attributes": belief,
		"time": _clock,
	})
	idle = 0.0
	acted.emit({"desire": option.desire, "action": option.action, "object": option.object})


## Explicit player verdict. A pet is +1, a slap -1; both credit whatever the
## creature did recently, weighted down by how long ago it did it.
func apply_player_feedback(value: float) -> void:
	var survivors: Array[Dictionary] = []
	for record: Dictionary in _pending:
		var age: float = _clock - float(record["time"])
		if age > tunables.feedback_window:
			continue
		var decay: float = 1.0 - (age / tunables.feedback_window)
		_credit(record, value * decay, 1.0, "player")
		survivors.append(record)
	_pending = survivors


## Consequences the world delivers by itself: hunger relieved, damage taken, a
## villager's reaction. No player involved.
func apply_intrinsic_feedback(
	desire: StringName, action: StringName, object: WorldObject, value: float
) -> void:
	var belief: PackedFloat32Array = beliefs.belief_for(object) if object != null \
		else PackedFloat32Array()
	_credit(
		{"desire": desire, "action": action, "attributes": belief, "time": _clock},
		value,
		1.0,
		"intrinsic"
	)


## Learning by being shown: the player did this to that object while the
## creature was on the leash of learning. A strong example, but not as strong as
## being told off directly.
func learn_from_demonstration(
	desire: StringName, action: StringName, object: WorldObject, value: float
) -> void:
	_teach(desire, action, object, value, tunables.shown_weight, "shown")


## Learning by imitation: it merely watched something happen. A nudge.
func learn_from_imitation(
	desire: StringName, action: StringName, object: WorldObject, value: float
) -> void:
	_teach(desire, action, object, value, tunables.imitation_weight, "imitated")


func last_options() -> Array[Option]:
	return _last_options


func last_choice() -> Option:
	return _last_choice


func recent_feedback() -> Array[Dictionary]:
	return _recent_feedback


func pending_count() -> int:
	return _pending.size()


## Current softmax temperature, falling from start to end as the creature ages.
func temperature() -> float:
	var decay: float = 1.0 / (
		1.0 + age_seconds / maxf(tunables.temperature_halflife, 0.001)
	)
	return lerpf(tunables.end_temperature, tunables.start_temperature, decay)


func _teach(
	desire: StringName,
	action: StringName,
	object: WorldObject,
	value: float,
	weight: float,
	source: String
) -> void:
	if object != null:
		beliefs.observe_truth(object)
	var belief: PackedFloat32Array = beliefs.belief_for(object) if object != null \
		else PackedFloat32Array()
	_credit(
		{"desire": desire, "action": action, "attributes": belief, "time": _clock},
		value,
		weight,
		source
	)


func _credit(record: Dictionary, value: float, weight: float, source: String) -> void:
	var attributes: PackedFloat32Array = record["attributes"]
	if attributes.is_empty():
		return
	opinions.add_experience(record["desire"], record["action"], attributes, value, weight)
	desires.reinforce(record["desire"], situation(), value, age_seconds)
	alignment = lerpf(alignment, clampf(value, -1.0, 1.0), tunables.alignment_smoothing)

	var entry: Dictionary = {
		"desire": record["desire"],
		"action": record["action"],
		"value": value,
		"weight": weight,
		"source": source,
		"time": _clock,
	}
	_recent_feedback.append(entry)
	while _recent_feedback.size() > 24:
		_recent_feedback.remove_at(0)
	feedback_received.emit(entry)


func _assign_probabilities(options: Array[Option]) -> void:
	if options.is_empty():
		return
	var t: float = maxf(temperature(), 0.001)
	var highest: float = -INF
	var spread: float = 0.0
	for option: Option in options:
		highest = maxf(highest, option.score)
		spread = maxf(spread, absf(option.score))

	# Scores are normalised before the softmax so temperature means the same
	# thing regardless of how strongly the creature currently wants anything.
	#
	# Without this, scores scale with desire intensity — and since punishment
	# also nudges desires down, a well-taught creature slowly became *less*
	# decisive: its opinion of eating villagers stayed at -1.0 while the
	# probability of doing it crept back up toward uniform, because the whole
	# spread was shrinking underneath it. Ranking is unaffected: this is a
	# linear rescale, so a weak desire's options still lose to a strong one's.
	var scale: float = 1.0 / spread if spread > 0.0001 else 1.0

	var total: float = 0.0
	var weights: Array[float] = []
	for option: Option in options:
		# Shifted by the maximum before exponentiating: exp() of a raw score
		# overflows to inf and every probability comes back NaN.
		var weight: float = exp(clampf((option.score - highest) * scale / t, -60.0, 0.0))
		weights.append(weight)
		total += weight

	for i in options.size():
		options[i].probability = weights[i] / total if total > 0.0 else 1.0 / float(options.size())


## How close the nearest object of these types is, as 1 at touching distance
## falling to 0 at the edge of perception.
func _proximity(types: Array) -> float:
	if _world == null:
		return 0.0
	var nearest: WorldObject = _world.nearest(_position, tunables.perception_radius, types)
	if nearest == null:
		return 0.0
	var distance: float = _position.distance_to(nearest.current_position())
	return clampf(1.0 - distance / tunables.perception_radius, 0.0, 1.0)


func to_dict() -> Dictionary:
	return {
		"beliefs": beliefs.to_dict(),
		"desires": desires.to_dict(),
		"opinions": opinions.to_dict(),
		"hunger": hunger,
		"fatigue": fatigue,
		"damage": damage,
		"idle": idle,
		"age": age_seconds,
		"alignment": alignment,
		"clock": _clock,
		# As strings on purpose. These are 64-bit values, and JSON numbers are
		# parsed back as doubles — anything past 2^53 silently loses its low
		# bits, so a reloaded creature resumed from a *nearly* identical
		# generator and diverged within one or two decisions.
		"rng_seed": str(_rng.seed),
		"rng_state": str(_rng.state),
	}


func from_dict(data: Dictionary) -> void:
	beliefs.from_dict(data.get("beliefs", {}))
	desires.from_dict(data.get("desires", {}))
	opinions.from_dict(data.get("opinions", {}))
	hunger = float(data.get("hunger", 0.5))
	fatigue = float(data.get("fatigue", 0.2))
	damage = float(data.get("damage", 0.0))
	idle = float(data.get("idle", 0.3))
	age_seconds = float(data.get("age", 0.0))
	alignment = float(data.get("alignment", 0.0))
	_clock = float(data.get("clock", 0.0))
	_rng.seed = int(str(data.get("rng_seed", "0")))
	# State as well as seed, and in this order: assigning seed resets state, so
	# restoring only the seed would rewind the generator and make a reloaded
	# creature repeat choices it had already made.
	_rng.state = int(str(data.get("rng_state", "0")))
