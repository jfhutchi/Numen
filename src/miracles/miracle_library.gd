class_name MiracleLibrary
extends RefCounted
## The five miracles the player can cast, as one table.
##
## An instance rather than a static table on purpose. Gesture bindings are
## writable (the $P template names belong to the gesture module, not here), and a
## process-wide static would let one screen's rebinding leak into the next test
## or the next save. Constructing five Resources is free.

var _miracles: Array[Miracle] = []


func _init() -> void:
	# Costs are ordered by how much the player should hesitate, not by how
	# impressive the effect looks. Water is cheap because a farming village needs
	# it constantly; lightning is dear because it should be a decision, not a
	# reflex. Alignment weights are the Phase 6 input: the two miracles that feed
	# and mend people pull hardest toward good, lightning hardest the other way.
	#
	# The gesture template is spelled out for every one of them, and must stay
	# that way. Miracle._init falls back to the id when the template is left off,
	# which binds `food` to a template named "food" — a name the recogniser can
	# never return, since GestureTemplates calls its five shapes spiral, chevron,
	# wave, circle and bolt. Every gesture cast then dies at the lookup with no
	# error anywhere. The names are copied rather than imported from
	# GestureTemplates on purpose: the binding is the one thing a designer may
	# want to change, and neither module should have to compile for the other.
	_miracles = [
		Miracle.new(
			&"food", "Food", 12.0, 6.0, 6.0, 0.35,
			"Drops a scattering of food piles for the village to gather.",
			&"spiral"
		),
		Miracle.new(
			&"wood", "Wood", 18.0, 8.0, 4.0, 0.15,
			"Grows trees, or fills a nearby store with timber.",
			&"chevron"
		),
		Miracle.new(
			&"water", "Water", 8.0, 10.0, 1.0, 0.25,
			"Waters every field in reach so the harvest comes in.",
			&"wave"
		),
		Miracle.new(
			&"heal", "Heal", 25.0, 8.0, 0.5, 0.60,
			"Mends the hurt villagers and creatures standing nearby.",
			&"circle"
		),
		Miracle.new(
			&"lightning", "Lightning", 40.0, 5.0, 1.0, -0.75,
			"Strikes the ground. Everything close enough burns.",
			&"bolt"
		),
	]


func all() -> Array[Miracle]:
	return _miracles


func by_id(miracle_id: StringName) -> Miracle:
	for miracle: Miracle in _miracles:
		if miracle.id == miracle_id:
			return miracle
	return null


## The miracle a recognised gesture template invokes, or null if none is bound.
##
## A linear scan rather than a cached dictionary because gesture_template is
## writable: a cache built at construction would answer with the old binding
## after the gesture module renamed a template, and that failure looks exactly
## like a broken recogniser.
func by_gesture(template_name: StringName) -> Miracle:
	if template_name == &"":
		return null
	for miracle: Miracle in _miracles:
		if miracle.gesture_template == template_name:
			return miracle
	return null


func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for miracle: Miracle in _miracles:
		out.append(miracle.id)
	return out
