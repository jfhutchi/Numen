class_name OpinionStore
extends RefCounted
## One learned decision tree per (desire, action) pair, over object attributes,
## predicting the feedback the creature expects.
##
## Trees are re-induced on a schedule rather than per example. Induction is the
## expensive part of the whole mind and one more example barely moves a tree, so
## rebuilding on every slap would burn the frame budget to change nothing.

## Actions the creature can take. Not all apply to every desire — see
## ACTIONS_FOR_DESIRE.
const EAT := &"eat"
const ATTACK := &"attack"
const PICK_UP := &"pick_up"
const THROW := &"throw"
const GIVE_TO_VILLAGE := &"give_to_village"
const WATER_FIELD := &"water_field"
const HEAL := &"heal"
const PLAY_WITH := &"play_with"
const SLEEP := &"sleep"
const FOLLOW_PLAYER := &"follow_player"
const IMITATE := &"imitate"
const DEFECATE := &"defecate"
const DANCE := &"dance"

const ALL_ACTIONS: Array[StringName] = [
	EAT, ATTACK, PICK_UP, THROW, GIVE_TO_VILLAGE, WATER_FIELD, HEAL,
	PLAY_WITH, SLEEP, FOLLOW_PLAYER, IMITATE, DEFECATE, DANCE,
]

## Which actions each desire will consider. Keeps candidate enumeration to a
## handful of pairs per tick instead of every action against every object.
const ACTIONS_FOR_DESIRE: Dictionary = {
	&"Hunger": [EAT, PICK_UP],
	&"Tiredness": [SLEEP],
	&"Anger": [ATTACK, THROW],
	&"Compassion": [GIVE_TO_VILLAGE, HEAL, WATER_FIELD],
	&"Boredom": [PLAY_WITH, DANCE, THROW],
	&"Curiosity": [PICK_UP, IMITATE, EAT],
	&"Fear": [FOLLOW_PLAYER],
}


class Opinion:
	extends RefCounted
	var experiences: Array = []
	var tree: Id3.TreeNode = null
	var since_induction: int = 0


var _opinions: Dictionary[StringName, Opinion] = {}
var _tunables: MindTunables


func _init(tunables: MindTunables = null) -> void:
	_tunables = tunables if tunables != null else MindTunables.new()


static func key_for(desire: StringName, action: StringName) -> StringName:
	return StringName("%s|%s" % [desire, action])


func opinion_for(desire: StringName, action: StringName) -> Opinion:
	var key: StringName = key_for(desire, action)
	var existing: Variant = _opinions.get(key)
	if existing != null:
		return existing
	var created := Opinion.new()
	_opinions[key] = created
	return created


## Records what happened when the creature acted on something with these
## believed attributes.
func add_experience(
	desire: StringName,
	action: StringName,
	attributes: PackedFloat32Array,
	feedback: float,
	weight: float = 1.0
) -> void:
	var opinion: Opinion = opinion_for(desire, action)
	opinion.experiences.append(Id3.Experience.new(attributes, feedback, weight))
	if opinion.experiences.size() > _tunables.max_experiences:
		_evict(opinion)
	opinion.since_induction += 1
	if opinion.tree == null or opinion.since_induction >= _tunables.reinduce_every:
		reinduce(desire, action)


## Expected feedback from doing `action` to something believed to be
## `attributes`. Zero when the creature has no opinion yet — neutral, not
## confident, so an inexperienced creature explores rather than avoiding.
func predict(desire: StringName, action: StringName, attributes: PackedFloat32Array) -> float:
	var opinion: Opinion = opinion_for(desire, action)
	if opinion.tree != null and not opinion.experiences.is_empty():
		return Id3.predict(opinion.tree, attributes, _tunables)
	return _predict_across_desires(action, attributes)


## What the creature expects from this action generally, pooled over every
## desire that has an opinion about it.
##
## Trees are per (desire, action) as specified, but knowledge of *what a thing
## is to do to* has to survive the motive changing. A creature that was slapped
## for eating people while hungry must not eat one out of curiosity an hour
## later just because curiosity keeps its notes in a different drawer — which is
## exactly what happened before this fallback existed.
func _predict_across_desires(action: StringName, attributes: PackedFloat32Array) -> float:
	var sum: float = 0.0
	var count: int = 0
	var suffix: String = "|%s" % action
	for key: StringName in _opinions:
		if not String(key).ends_with(suffix):
			continue
		var other: Opinion = _opinions[key]
		if other.tree != null and not other.experiences.is_empty():
			sum += Id3.predict(other.tree, attributes, _tunables)
			count += 1
	return sum / float(count) if count > 0 else 0.0


func decision_path(
	desire: StringName, action: StringName, attributes: PackedFloat32Array
) -> Array[Dictionary]:
	var opinion: Opinion = opinion_for(desire, action)
	if opinion.tree == null:
		return []
	return Id3.decision_path(opinion.tree, attributes, _tunables)


func experience_count(desire: StringName, action: StringName) -> int:
	return opinion_for(desire, action).experiences.size()


func reinduce(desire: StringName, action: StringName) -> void:
	var opinion: Opinion = opinion_for(desire, action)
	opinion.tree = Id3.induce(opinion.experiences, ObjectAttributes.COUNT, _tunables)
	opinion.since_induction = 0


## Drops the least informative experience: the oldest member of whichever
## feedback class is currently over-represented. Evicting the plain oldest would
## throw away the rare bad experience that actually taught the creature
## something, just because good ones are more common.
func _evict(opinion: Opinion) -> void:
	var counts: Dictionary = {}
	for experience: Id3.Experience in opinion.experiences:
		var cls: int = Id3.class_of(experience.feedback, _tunables.feedback_class_threshold)
		counts[cls] = int(counts.get(cls, 0)) + 1

	var majority: int = -1
	var most: int = -1
	for cls: int in counts:
		if int(counts[cls]) > most:
			most = int(counts[cls])
			majority = cls

	for i in opinion.experiences.size():
		var experience: Id3.Experience = opinion.experiences[i]
		if Id3.class_of(experience.feedback, _tunables.feedback_class_threshold) == majority:
			opinion.experiences.remove_at(i)
			return
	opinion.experiences.remove_at(0)


func to_dict() -> Dictionary:
	var data: Dictionary = {}
	for key: StringName in _opinions:
		var opinion: Opinion = _opinions[key]
		var experiences: Array = []
		for experience: Id3.Experience in opinion.experiences:
			experiences.append({
				"a": Array(experience.attributes),
				"f": experience.feedback,
				"w": experience.weight,
			})
		data[String(key)] = {"experiences": experiences, "tree": Id3.to_dict(opinion.tree)}
	return data


func from_dict(data: Dictionary) -> void:
	_opinions.clear()
	for key: String in data:
		var opinion := Opinion.new()
		var stored: Dictionary = data[key]
		for row: Dictionary in stored.get("experiences", []):
			var attributes := PackedFloat32Array()
			var values: Array = row.get("a", [])
			attributes.resize(values.size())
			for i in values.size():
				attributes[i] = float(values[i])
			opinion.experiences.append(
				Id3.Experience.new(attributes, float(row.get("f", 0.0)), float(row.get("w", 1.0)))
			)
		var tree_data: Dictionary = stored.get("tree", {})
		opinion.tree = Id3.from_dict(tree_data) if not tree_data.is_empty() else null
		_opinions[StringName(key)] = opinion
