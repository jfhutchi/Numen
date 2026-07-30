extends GutTest
## The genre's central mechanic: lead the creature somewhere, do a thing, and it
## learns from having watched you.
##
## Until this test existed the path was reachable only by accident — one hardcoded
## call fired whenever a thrown object was released, with no check that the
## creature could see it and every lesson filed under Curiosity whatever it was
## about. docs/design/fidelity.md calls this the largest gap between NUMEN and the
## thing it is a successor to.

const CREATURE := preload("res://src/creature/body/creature.gd")
const REGISTRY := preload("res://src/world/object_registry.gd")
const ISLAND := preload("res://src/world/island.gd")
const TUNABLES := preload("res://src/creature/mind/mind_tunables.gd")

var _registry: Node
var _island: Node3D
var _creature: Creature


func before_each() -> void:
	_registry = REGISTRY.new()
	autofree(_registry)
	_island = ISLAND.new()
	add_child_autofree(_island)
	_island.generate(20260729)

	_creature = CREATURE.new()
	_creature.prefer_rigged_body = false
	add_child_autofree(_creature)
	var tunables: MindTunables = TUNABLES.new()
	tunables.reinduce_every = 1
	_creature.configure(_registry, _island, tunables, 4242)
	_creature.global_position = Vector3.ZERO
	_creature.mind.set_position(Vector3.ZERO)


## What the creature expects from doing `action` to `object` right now.
func _opinion(action: StringName, object: WorldObject) -> float:
	var desire: StringName = OpinionStore.desire_for_action(action)
	return _creature.mind.opinions.predict(
		desire, action, _creature.mind.beliefs.belief_for(object)
	)


func test_being_shown_a_kindness_teaches_the_creature_to_expect_good_of_it() -> void:
	_creature.set_leash(Creature.LEASH_LEARNING)
	var villager: WorldObject = _registry.add(&"villager", Vector3(3.0, 0.0, 0.0))

	var before: float = _opinion(&"heal", villager)
	for i in 6:
		assert_true(_creature.witness(&"heal", villager, 0.7), "the lesson should land")
	var after: float = _opinion(&"heal", villager)

	gut.p("opinion of healing a villager: %.3f -> %.3f over 6 demonstrations" % [before, after])
	assert_gt(after, before, "watching the player heal should raise its expectation")
	assert_gt(after, 0.2, "and leave it clearly positive")


func test_the_lesson_is_filed_under_the_desire_that_owns_the_action() -> void:
	# Every lesson used to go to Curiosity whatever it was about, which made the
	# Mind Inspector's account of why the creature acted a fiction.
	_creature.set_leash(Creature.LEASH_LEARNING)
	var villager: WorldObject = _registry.add(&"villager", Vector3(3.0, 0.0, 0.0))
	_creature.witness(&"heal", villager, 0.7)

	var owner: StringName = OpinionStore.desire_for_action(&"heal")
	gut.p("heal is filed under %s" % owner)
	assert_eq(owner, &"Compassion", "healing belongs with Compassion, not Curiosity")
	assert_gt(_creature.mind.opinions.experience_count(owner, &"heal"), 0,
		"the experience should be recorded against the owning desire")


func test_the_creature_learns_nothing_from_what_it_cannot_see() -> void:
	# The whole reason the learning leash exists is that being led somewhere and
	# shown a thing is different from it happening elsewhere on the island.
	_creature.set_leash(Creature.LEASH_LEARNING)
	var far: WorldObject = _registry.add(
		&"villager", Vector3(_creature.mind.tunables.perception_radius * 4.0, 0.0, 0.0)
	)

	assert_false(_creature.witness(&"heal", far, 0.7), "it cannot see that far")
	assert_eq(_creature.mind.opinions.experience_count(&"Compassion", &"heal"), 0,
		"nothing should have been learned from an event out of sight")


func test_the_leash_of_learning_teaches_harder_than_idle_watching() -> void:
	var near := Vector3(3.0, 0.0, 0.0)

	_creature.set_leash(Creature.LEASH_LEARNING)
	var shown: WorldObject = _registry.add(&"villager", near)
	_creature.witness(&"heal", shown, 0.7)
	var demonstrated: float = _opinion(&"heal", shown)

	before_each()
	_creature.set_leash(Creature.LEASH_NONE)
	var glimpsed: WorldObject = _registry.add(&"villager", near)
	_creature.witness(&"heal", glimpsed, 0.7)
	var imitated: float = _opinion(&"heal", glimpsed)

	gut.p("one demonstration %.3f vs one glimpse %.3f" % [demonstrated, imitated])
	assert_gt(demonstrated, imitated,
		"being shown deliberately should teach more than happening to notice")


func test_imitation_needs_the_creature_closer_than_demonstration() -> void:
	# Off the leash it is only glancing over, so the same event at the same distance
	# should teach on the leash and not off it.
	var edge: float = _creature.mind.tunables.perception_radius * 0.8
	var object: WorldObject = _registry.add(&"villager", Vector3(edge, 0.0, 0.0))

	_creature.set_leash(Creature.LEASH_LEARNING)
	assert_true(_creature.witness(&"heal", object, 0.7),
		"on the leash it should learn at %.1f m" % edge)

	before_each()
	var same: WorldObject = _registry.add(&"villager", Vector3(edge, 0.0, 0.0))
	_creature.set_leash(Creature.LEASH_NONE)
	assert_false(_creature.witness(&"heal", same, 0.7),
		"off the leash %.1f m should be too far to pick anything up" % edge)


func test_conviction_accumulates_rather_than_arriving_all_at_once() -> void:
	# Learning used to be one-shot: a single experience made a pure ID3 leaf, so
	# one demonstration produced an opinion of exactly its face value and the
	# creature was instantly certain. It read as a light switch.
	_creature.set_leash(Creature.LEASH_LEARNING)
	var villager: WorldObject = _registry.add(&"villager", Vector3(3.0, 0.0, 0.0))

	var curve: Array[float] = []
	for i in 8:
		_creature.witness(&"heal", villager, 1.0)
		curve.append(_opinion(&"heal", villager))

	gut.p("opinion after each of 8 identical lessons: %s" % [
		curve.map(func(v: float) -> String: return "%.2f" % v)
	])
	assert_lt(curve[0], 0.6, "one lesson should not produce total conviction")
	assert_gt(curve[curve.size() - 1], curve[0], "conviction should grow with evidence")
	assert_lt(curve[curve.size() - 1], 1.01, "and never exceed the evidence itself")
