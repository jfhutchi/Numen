class_name ObjectAttributes
extends RefCounted
## Ground truth about what things in the world actually are.
##
## The creature never reads this directly. It observes objects and its beliefs
## drift toward these values — see belief_table.gd. Keeping truth and belief
## apart is the whole point: a creature that already knew everything would have
## nothing to learn.

const NAMES: Array[StringName] = [
	&"nutritious",
	&"edible",
	&"wooden",
	&"heavy",
	&"alive",
	&"friendly",
	&"useful_for_building",
	&"dangerous",
	&"throwable",
	&"mine",
]

const COUNT := 10

## Per type, in NAMES order.
const TRUTH: Dictionary = {
	#                    nutr  edib  wood  heav  aliv  frie  buil  dang  thro  mine
	&"villager":        [0.70, 0.85, 0.00, 0.35, 1.00, 0.90, 0.00, 0.10, 0.80, 1.00],
	&"enemy_villager":  [0.70, 0.85, 0.00, 0.35, 1.00, 0.05, 0.00, 0.60, 0.80, 0.00],
	&"food_pile":       [0.95, 1.00, 0.00, 0.15, 0.00, 0.50, 0.00, 0.00, 0.90, 1.00],
	&"wheat_field":     [0.80, 0.70, 0.10, 0.90, 0.30, 0.50, 0.00, 0.00, 0.05, 1.00],
	&"tree":            [0.05, 0.05, 1.00, 0.80, 0.30, 0.50, 0.90, 0.00, 0.30, 1.00],
	&"rock":            [0.00, 0.00, 0.00, 0.95, 0.00, 0.50, 0.70, 0.15, 0.55, 1.00],
	&"house":           [0.00, 0.00, 0.70, 1.00, 0.00, 0.60, 0.20, 0.00, 0.02, 1.00],
	&"store":           [0.60, 0.40, 0.60, 1.00, 0.00, 0.60, 0.20, 0.00, 0.02, 1.00],
	&"water":           [0.10, 0.30, 0.00, 0.50, 0.00, 0.50, 0.00, 0.25, 0.10, 0.50],
	&"creature":        [0.30, 0.20, 0.00, 1.00, 1.00, 0.60, 0.00, 0.50, 0.05, 0.50],
	&"player_hand":     [0.00, 0.00, 0.00, 0.00, 1.00, 1.00, 0.00, 0.20, 0.00, 1.00],
}

## What the creature assumes about something it has never encountered: nothing.
const UNKNOWN := 0.5


static func truth_for(type: StringName) -> PackedFloat32Array:
	var row: Variant = TRUTH.get(type)
	if row == null:
		var blank := PackedFloat32Array()
		blank.resize(COUNT)
		blank.fill(UNKNOWN)
		return blank
	return PackedFloat32Array(row)


static func index_of(attribute: StringName) -> int:
	return NAMES.find(attribute)


static func name_of(index: int) -> StringName:
	return NAMES[index] if index >= 0 and index < NAMES.size() else &"?"
