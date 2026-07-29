class_name BeliefTable
extends RefCounted
## What the creature thinks each object is.
##
## Beliefs are per *instance*, but a new instance is seeded from what the
## creature has learned about that *type*, and observing updates both. See
## ADR-005 — without the type prior nothing generalises: slap the creature for
## eating villager #7 and it eats villager #8 with undiminished enthusiasm,
## because #8 is a brand new object sitting at flat uncertainty.
##
## The prior moves more slowly than instance beliefs, so one strange individual
## does not rewrite the whole category.

var _instances: Dictionary[int, PackedFloat32Array] = {}
var _type_priors: Dictionary[StringName, PackedFloat32Array] = {}
var _tunables: MindTunables


func _init(tunables: MindTunables = null) -> void:
	_tunables = tunables if tunables != null else MindTunables.new()


## The creature's current belief vector for an object, seeded on first sight.
func belief_for(object: WorldObject) -> PackedFloat32Array:
	var existing: Variant = _instances.get(object.id)
	if existing != null:
		return existing
	var seeded: PackedFloat32Array = _seed_from_prior(object.type)
	_instances[object.id] = seeded
	return seeded


## What the creature believes about a type in general.
func prior_for(type: StringName) -> PackedFloat32Array:
	var existing: Variant = _type_priors.get(type)
	if existing != null:
		return existing
	var blank := PackedFloat32Array()
	blank.resize(ObjectAttributes.COUNT)
	blank.fill(ObjectAttributes.UNKNOWN)
	_type_priors[type] = blank
	return blank


## Folds an observation into both the instance belief and the type prior.
func observe(object: WorldObject, observed: PackedFloat32Array) -> void:
	var belief: PackedFloat32Array = belief_for(object)
	var prior: PackedFloat32Array = prior_for(object.type)
	var instance_rate: float = _tunables.belief_learning_rate
	var prior_rate: float = _tunables.type_prior_learning_rate

	for i in mini(observed.size(), ObjectAttributes.COUNT):
		belief[i] = lerpf(belief[i], observed[i], instance_rate)
		prior[i] = lerpf(prior[i], observed[i], prior_rate)

	_instances[object.id] = belief
	_type_priors[object.type] = prior


## Convenience: observe an object as it truly is. Perception in this game is not
## unreliable — the creature's ignorance comes from not having looked yet.
func observe_truth(object: WorldObject) -> void:
	observe(object, ObjectAttributes.truth_for(object.type))


func forget(object_id: int) -> void:
	_instances.erase(object_id)


func known_instance_count() -> int:
	return _instances.size()


func _seed_from_prior(type: StringName) -> PackedFloat32Array:
	var prior: PackedFloat32Array = prior_for(type)
	var seeded := PackedFloat32Array()
	seeded.resize(ObjectAttributes.COUNT)
	var strength: float = _tunables.type_prior_strength
	for i in ObjectAttributes.COUNT:
		seeded[i] = lerpf(ObjectAttributes.UNKNOWN, prior[i], strength)
	return seeded


func to_dict() -> Dictionary:
	var instances: Dictionary = {}
	for id: int in _instances:
		instances[str(id)] = Array(_instances[id])
	var priors: Dictionary = {}
	for type: StringName in _type_priors:
		priors[String(type)] = Array(_type_priors[type])
	return {"instances": instances, "priors": priors}


func from_dict(data: Dictionary) -> void:
	_instances.clear()
	_type_priors.clear()
	var instances: Dictionary = data.get("instances", {})
	for key: String in instances:
		_instances[int(key)] = _to_vector(instances[key])
	var priors: Dictionary = data.get("priors", {})
	for key: String in priors:
		_type_priors[StringName(key)] = _to_vector(priors[key])


func _to_vector(values: Array) -> PackedFloat32Array:
	var vector := PackedFloat32Array()
	vector.resize(values.size())
	for i in values.size():
		vector[i] = float(values[i])
	return vector
