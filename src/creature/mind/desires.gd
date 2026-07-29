class_name Desires
extends RefCounted
## The creature's motivations, one single-layer perceptron each.
##
## Weights start as instinct rather than at zero. A newborn that had to discover
## that hunger relates to eating would spend its whole childhood starving, and
## the interesting learning is not "what is hunger" — it is what to do about it.
## Feedback then reshapes these over the creature's life.

const HUNGER := &"Hunger"
const TIREDNESS := &"Tiredness"
const ANGER := &"Anger"
const COMPASSION := &"Compassion"
const BOREDOM := &"Boredom"
const CURIOSITY := &"Curiosity"
const FEAR := &"Fear"

const ALL: Array[StringName] = [
	HUNGER, TIREDNESS, ANGER, COMPASSION, BOREDOM, CURIOSITY, FEAR
]

## Input vector layout, shared by every desire perceptron.
const IN_HUNGER := 0
const IN_FATIGUE := 1
const IN_DAMAGE := 2
const IN_FOOD_NEAR := 3
const IN_VILLAGER_NEAR := 4
const IN_THREAT_NEAR := 5
const IN_IDLE := 6
const INPUT_COUNT := 7

## Instinct: which input each desire is born paying attention to, and how much.
const INSTINCTS: Dictionary = {
	HUNGER: {IN_HUNGER: 4.0, IN_FOOD_NEAR: 0.8},
	TIREDNESS: {IN_FATIGUE: 4.0},
	ANGER: {IN_THREAT_NEAR: 2.0, IN_DAMAGE: 2.5},
	COMPASSION: {IN_VILLAGER_NEAR: 1.6},
	BOREDOM: {IN_IDLE: 3.0},
	CURIOSITY: {IN_IDLE: 1.5, IN_VILLAGER_NEAR: 0.6},
	FEAR: {IN_THREAT_NEAR: 3.0, IN_DAMAGE: 1.5},
}

var _units: Dictionary[StringName, Perceptron] = {}
var _tunables: MindTunables


func _init(tunables: MindTunables = null) -> void:
	_tunables = tunables if tunables != null else MindTunables.new()
	for desire: StringName in ALL:
		var unit := Perceptron.new(INPUT_COUNT, 0.0)
		# Negative bias so a desire sits near zero until its inputs speak up,
		# rather than every drive idling at 0.5 and the creature dithering.
		unit.bias = -2.0
		var instincts: Dictionary = INSTINCTS.get(desire, {})
		for index: int in instincts:
			unit.set_weight(index, float(instincts[index]))
		_units[desire] = unit


func unit(desire: StringName) -> Perceptron:
	return _units.get(desire)


## Intensity of every desire for the creature's current situation.
func intensities(inputs: PackedFloat32Array) -> Dictionary[StringName, float]:
	var result: Dictionary[StringName, float] = {}
	for desire: StringName in ALL:
		result[desire] = _units[desire].evaluate(inputs)
	return result


## The strongest `count` desires, strongest first.
func strongest(inputs: PackedFloat32Array, count: int) -> Array[StringName]:
	var scored: Array = []
	var levels: Dictionary[StringName, float] = intensities(inputs)
	for desire: StringName in ALL:
		scored.append({"desire": desire, "level": levels[desire]})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["level"]) > float(b["level"])
	)
	var top: Array[StringName] = []
	for i in mini(count, scored.size()):
		top.append(scored[i]["desire"])
	return top


## Nudges a desire toward or away from firing in this situation.
##
## The rate decays with age, so a young creature swings hard on one experience
## and an old one is set in its ways.
func reinforce(
	desire: StringName, inputs: PackedFloat32Array, feedback: float, age_seconds: float
) -> void:
	var unit_for_desire: Perceptron = _units.get(desire)
	if unit_for_desire == null:
		return
	var current: float = unit_for_desire.evaluate(inputs)
	# Deliberately a small nudge. Desires are drives, not choices: being slapped
	# for eating the wrong thing should change *what* the creature eats, which
	# lives in its opinions, not whether it gets hungry at all. An earlier version
	# nudged by 0.5 and fifteen punishments extinguished Hunger outright — the
	# creature stopped considering food and its hard-won opinion about villagers
	# stopped being consulted.
	var target: float = clampf(current + feedback * 0.15, 0.0, 1.0)
	var rate: float = _tunables.desire_learning_rate / (
		1.0 + age_seconds / maxf(_tunables.desire_rate_age_halflife, 0.001)
	)
	unit_for_desire.learn(inputs, target, rate)


func to_dict() -> Dictionary:
	var data: Dictionary = {}
	for desire: StringName in _units:
		data[String(desire)] = _units[desire].to_dict()
	return data


func from_dict(data: Dictionary) -> void:
	for key: String in data:
		var desire := StringName(key)
		if _units.has(desire):
			_units[desire].from_dict(data[key])
