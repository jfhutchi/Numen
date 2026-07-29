extends GutTest
## Phase 4 keystone. The reason this project exists: the creature must visibly
## change what it does because of how the player treated it.

const HARNESS := preload("res://tests/behavioral/sim_harness.gd")
const TUNABLES := preload("res://src/creature/mind/mind_tunables.gd")

const EAT := &"eat"
const VILLAGER := &"villager"
const FOOD_PILE := &"food_pile"

var _harness: MindSimHarness


func before_each() -> void:
	var tunables: MindTunables = TUNABLES.new()
	# Re-induce on every example. The production schedule exists to save frame
	# budget, and here it would only blur which trial changed the creature's mind.
	tunables.reinduce_every = 1
	_harness = HARNESS.new(tunables, 20260729)


func after_each() -> void:
	_harness.dispose()


func _populate() -> void:
	_harness.add_ring(VILLAGER, 3, 6.0)
	_harness.add_ring(FOOD_PILE, 3, 8.0)
	_harness.mind.hunger = 0.95
	_harness.mind.set_position(Vector3.ZERO)


func test_creature_unlearns_punished_behavior() -> void:
	_populate()

	# Let it look around so its beliefs reflect what these things actually are.
	# A creature that has not observed anything holds every attribute at 0.5 and
	# cannot tell a person from a pile of bread.
	for i in 6:
		_harness.mind.perceive()

	var baseline_villager: float = _harness.probability_of(EAT, VILLAGER)
	var baseline_food: float = _harness.probability_of(EAT, FOOD_PILE)

	gut.p("baseline  P(eat villager)=%.4f  P(eat food_pile)=%.4f" % [
		baseline_villager, baseline_food
	])
	assert_gt(baseline_villager, 0.0,
		"the creature must start willing to eat villagers, or there is nothing to unlearn")

	# 15 trials. Eating a person is punished; eating food relieves hunger, which
	# is its own reward and needs no player.
	gut.p("trial | P(eat villager) | P(eat food_pile) | opinion(villager) | opinion(food)")
	for trial in 15:
		_harness.mind.hunger = 0.95
		var villagers: Array[WorldObject] = _harness.world.query_near(
			Vector3.ZERO, 100.0, [VILLAGER]
		)
		var foods: Array[WorldObject] = _harness.world.query_near(
			Vector3.ZERO, 100.0, [FOOD_PILE]
		)

		_harness.mind.perform(_option(EAT, villagers[trial % villagers.size()]))
		_harness.mind.apply_player_feedback(-1.0)

		_harness.mind.apply_intrinsic_feedback(
			&"Hunger", EAT, foods[trial % foods.size()], 0.85
		)

		gut.p("%5d | %15.4f | %16.4f | %17.3f | %12.3f" % [
			trial + 1,
			_harness.probability_of(EAT, VILLAGER),
			_harness.probability_of(EAT, FOOD_PILE),
			_harness.opinion_of(EAT, VILLAGER),
			_harness.opinion_of(EAT, FOOD_PILE),
		])

	var final_villager: float = _harness.probability_of(EAT, VILLAGER)
	var final_food: float = _harness.probability_of(EAT, FOOD_PILE)

	gut.p("final     P(eat villager)=%.4f (%.1f%% of baseline)" % [
		final_villager, 100.0 * final_villager / maxf(baseline_villager, 0.000001)
	])
	gut.p("final     P(eat food_pile)=%.4f (%.1f%% of baseline)" % [
		final_food, 100.0 * final_food / maxf(baseline_food, 0.000001)
	])

	assert_lt(final_villager, baseline_villager * 0.10,
		"eating villagers should have collapsed to under a tenth of baseline")

	# Expressed as "not suppressed" rather than "identical" on purpose. The
	# options share one softmax, so driving villager-eating down necessarily
	# lifts everything else. What must be true is that punishment stayed
	# specific — the creature learned "not people", not "not eating".
	assert_gte(final_food, baseline_food,
		"punishing villagers must not put the creature off food as well")

	assert_lt(_harness.opinion_of(EAT, VILLAGER), -0.2,
		"the learned opinion of eating people should be clearly negative")
	assert_gt(_harness.opinion_of(EAT, FOOD_PILE), 0.2,
		"and eating food should still look like a good idea")


func test_learning_generalises_to_a_villager_it_has_never_met() -> void:
	# The per-type prior earning its keep (ADR-005). Without it the creature
	# only learns "not *that* person" and happily eats the next one.
	_populate()
	for i in 6:
		_harness.mind.perceive()

	var villagers: Array[WorldObject] = _harness.world.query_near(Vector3.ZERO, 100.0, [VILLAGER])
	for trial in 12:
		_harness.mind.perform(_option(EAT, villagers[trial % villagers.size()]))
		_harness.mind.apply_player_feedback(-1.0)

	var stranger: WorldObject = _harness.add(VILLAGER, Vector3(4.0, 0.0, 4.0))
	var belief: PackedFloat32Array = _harness.mind.beliefs.belief_for(stranger)
	var expectation: float = _harness.mind.opinions.predict(&"Hunger", EAT, belief)

	gut.p("opinion of eating a never-before-seen villager: %.3f" % expectation)
	assert_lt(expectation, -0.2,
		"a creature that learned not to eat people should not need to be taught again per person")


func test_learned_state_roundtrips() -> void:
	_populate()
	for i in 6:
		_harness.mind.perceive()

	var villagers: Array[WorldObject] = _harness.world.query_near(Vector3.ZERO, 100.0, [VILLAGER])
	var foods: Array[WorldObject] = _harness.world.query_near(Vector3.ZERO, 100.0, [FOOD_PILE])
	for trial in 10:
		_harness.mind.perform(_option(EAT, villagers[trial % villagers.size()]))
		_harness.mind.apply_player_feedback(-1.0)
		_harness.mind.apply_intrinsic_feedback(&"Hunger", EAT, foods[trial % foods.size()], 0.9)

	var saved: Dictionary = _harness.mind.to_dict()
	var json: String = JSON.stringify(saved)
	assert_gt(json.length(), 0, "learned state should serialise to text")

	var reloaded: CreatureMind = CreatureMind.new(_harness.tunables, 1)
	reloaded.bind_world(_harness.world, _harness.mind.position())
	reloaded.from_dict(JSON.parse_string(json))

	# Same seeded choices over 100 ticks, not merely the same weights on disk.
	var original_sequence: Array[String] = _sequence(_harness.mind, 100)
	var restored_sequence: Array[String] = _sequence(reloaded, 100)

	gut.p("first 6 original: %s" % [original_sequence.slice(0, 6)])
	gut.p("first 6 restored: %s" % [restored_sequence.slice(0, 6)])
	assert_eq(restored_sequence, original_sequence,
		"a reloaded creature must behave exactly like the one that was saved")


func test_alignment_tracks_what_the_creature_is_rewarded_for() -> void:
	_populate()
	for i in 6:
		_harness.mind.perceive()
	var villagers: Array[WorldObject] = _harness.world.query_near(Vector3.ZERO, 100.0, [VILLAGER])

	var start: float = _harness.mind.alignment
	for trial in 20:
		_harness.mind.perform(_option(EAT, villagers[trial % villagers.size()]))
		_harness.mind.apply_player_feedback(-1.0)

	gut.p("alignment %.3f -> %.3f after 20 punishments" % [start, _harness.mind.alignment])
	assert_lt(_harness.mind.alignment, start, "punishment should drag alignment down")


func test_feedback_outside_the_window_is_ignored() -> void:
	# Credit assignment has to have a horizon, or a slap five minutes later
	# would blame whatever the creature happened to do first.
	_populate()
	for i in 6:
		_harness.mind.perceive()
	var villagers: Array[WorldObject] = _harness.world.query_near(Vector3.ZERO, 100.0, [VILLAGER])

	_harness.mind.perform(_option(EAT, villagers[0]))
	assert_eq(_harness.mind.pending_count(), 1)

	_harness.mind.advance_clock(_harness.tunables.feedback_window + 1.0)
	_harness.mind.apply_player_feedback(-1.0)

	assert_eq(_harness.mind.pending_count(), 0, "stale actions should be dropped")
	assert_eq(_harness.mind.opinions.experience_count(&"Hunger", EAT), 0,
		"a slap long after the fact should teach nothing")


func test_demonstration_weighs_more_than_imitation() -> void:
	_populate()
	var food: WorldObject = _harness.world.query_near(Vector3.ZERO, 100.0, [FOOD_PILE])[0]

	_harness.mind.learn_from_demonstration(&"Hunger", EAT, food, 1.0)
	_harness.mind.learn_from_imitation(&"Hunger", EAT, food, 1.0)

	var log: Array[Dictionary] = _harness.mind.recent_feedback()
	assert_eq(log.size(), 2)
	assert_gt(float(log[0]["weight"]), float(log[1]["weight"]),
		"being shown should teach more than merely watching")


## Builds an option by hand, for tests that need to force a specific action
## rather than let the creature pick.
func _option(action: StringName, object: WorldObject) -> CreatureMind.Option:
	var option := CreatureMind.Option.new()
	option.desire = &"Hunger"
	option.action = action
	option.object = object
	return option


func _sequence(mind: CreatureMind, ticks: int) -> Array[String]:
	var out: Array[String] = []
	for i in ticks:
		var choice: CreatureMind.Option = mind.choose()
		out.append("none" if choice == null else "%s:%s" % [
			choice.action, choice.object.type if choice.object != null else "self"
		])
	return out
