class_name MindSimHarness
extends RefCounted
## Headless rig for exercising the creature mind without a scene, a renderer or
## a frame loop.
##
## Built before the mind itself, deliberately: learning needs hundreds of
## iterations to judge, and iterating on it through a game window would be
## unbearable. The world here is a bare object registry — the same class the
## live game uses, just not in the tree — so the mind cannot tell the difference.

const REGISTRY := preload("res://src/world/object_registry.gd")

var world: Node
var mind: CreatureMind
var tunables: MindTunables

## Every action the creature took: {tick, desire, action, type, object_id}.
var action_log: Array[Dictionary] = []


func _init(mind_tunables: MindTunables = null, seed_value: int = 20260729) -> void:
	tunables = mind_tunables if mind_tunables != null else MindTunables.new()
	world = REGISTRY.new()
	mind = CreatureMind.new(tunables, seed_value)
	mind.bind_world(world, Vector3.ZERO)


## Frees the standalone registry. RefCounted harness, Node world.
func dispose() -> void:
	if world != null and is_instance_valid(world):
		world.free()
		world = null


## Puts an object in the world near the creature.
func add(type: StringName, at: Vector3 = Vector3.ZERO) -> WorldObject:
	return world.add(type, at)


## Scatters `count` objects of a type in a ring around the creature.
func add_ring(type: StringName, count: int, radius: float) -> Array[WorldObject]:
	var created: Array[WorldObject] = []
	for i in count:
		var angle: float = TAU * float(i) / float(count)
		created.append(add(type, Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)))
	return created


## Probability the creature would pick this action on this object type right
## now. Read straight off the softmax rather than sampled, so a measurement is
## exact instead of being buried in sampling noise.
func probability_of(action: StringName, type: StringName) -> float:
	var total: float = 0.0
	for option: CreatureMind.Option in mind.evaluate_options():
		if option.action == action and option.object != null and option.object.type == type:
			total += option.probability
	return total


## The creature's learned expectation for acting on a type, averaged over the
## desires that would consider it.
func opinion_of(action: StringName, type: StringName) -> float:
	var sum: float = 0.0
	var count: int = 0
	for option: CreatureMind.Option in mind.evaluate_options():
		if option.action == action and option.object != null and option.object.type == type:
			sum += option.opinion
			count += 1
	return sum / float(count) if count > 0 else 0.0


## Runs one decision: the creature chooses, acts, and the world answers.
##
## `verdict` is called with the chosen option and may return a player feedback
## value, or NAN for "the player said nothing".
func step(tick: int, verdict: Callable = Callable()) -> CreatureMind.Option:
	mind.advance_clock(1.0 / maxf(tunables.decision_hz, 0.001))
	var choice: CreatureMind.Option = mind.choose()
	if choice == null:
		return null

	mind.perform(choice)
	action_log.append({
		"tick": tick,
		"desire": choice.desire,
		"action": choice.action,
		"type": choice.object.type if choice.object != null else &"self",
		"object_id": choice.object.id if choice.object != null else -1,
	})

	if verdict.is_valid():
		var value: float = verdict.call(choice)
		if not is_nan(value):
			mind.apply_player_feedback(value)
	return choice


## How often each (action, type) pair was chosen over the whole log.
func action_counts() -> Dictionary:
	var counts: Dictionary = {}
	for entry: Dictionary in action_log:
		var key: String = "%s(%s)" % [entry["action"], entry["type"]]
		counts[key] = int(counts.get(key, 0)) + 1
	return counts


func clear_log() -> void:
	action_log.clear()
