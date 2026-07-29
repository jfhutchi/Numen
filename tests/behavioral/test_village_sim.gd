extends GutTest
## Phase 2 acceptance. Twenty minutes of village life, headless, in about a
## second of wall clock — which is only possible because the village exposes
## simulate(delta) and never depends on the frame loop.

const ISLAND := preload("res://src/world/island.gd")
const REGISTRY := preload("res://src/world/object_registry.gd")
const VILLAGE := preload("res://src/village/village.gd")
const TUNABLES := preload("res://src/village/village_tunables.gd")

const SEED := 20260729
## Twenty minutes of simulated time.
const SIM_SECONDS := 1200.0
## Step size. Matches the default decision interval, so the round-robin advances
## once per step and the run costs six thousand steps rather than sixty thousand.
const STEP := 0.2

var _island: Node3D
var _registry: Node
var _village: Node3D


func before_all() -> void:
	# Generated once: the heightmap is the most expensive thing in this file and
	# nothing in the village writes to it. Freed by hand in after_all because
	# GUT's autofree queue is per test, not per script.
	_island = ISLAND.new()
	_island.generate(SEED)


func after_all() -> void:
	if _island != null and is_instance_valid(_island):
		_island.free()
		_island = null


func before_each() -> void:
	_registry = REGISTRY.new()
	autofree(_registry)
	_village = VILLAGE.new()
	# The test drives the clock itself. Left on, _physics_process would also
	# advance the village between tests and the run would stop being reproducible.
	_village.auto_simulate = false
	add_child_autofree(_village)


func test_a_village_of_eight_grows_past_twelve_in_twenty_minutes() -> void:
	_populate()
	var store: VillageStore = _village.store
	var start_population: int = _village.population()

	var steps: int = int(SIM_SECONDS / STEP)
	var sample_every: int = int(5.0 / STEP)
	var print_every: int = int(120.0 / STEP)

	var lowest_population: int = start_population
	var lowest_food: float = INF
	var lowest_wood: float = INF
	# Step at which stock first went negative, or -1. Recorded rather than
	# asserted inside the loop: twelve thousand assertions would bury the run log
	# and say nothing a step index does not.
	var negative_step: int = -1
	var nan_step: int = -1
	var needs_seen: Dictionary = {}
	var desires_seen: Dictionary = {}
	var rows: Array[String] = []

	for step in steps:
		_village.simulate(STEP)

		var food: float = store.stock_of(VillageStore.FOOD)
		var wood: float = store.stock_of(VillageStore.WOOD)
		lowest_food = minf(lowest_food, food)
		lowest_wood = minf(lowest_wood, wood)
		lowest_population = mini(lowest_population, _village.population())
		if negative_step < 0 and (food < 0.0 or wood < 0.0):
			negative_step = step
		if nan_step < 0 and (is_nan(food) or is_nan(wood)):
			nan_step = step

		if step % sample_every == 0:
			desires_seen[_village.current_desire()] = true
			var people: Array = _village.villagers()
			for villager: Villager in people:
				if nan_step < 0 and _has_nan(villager):
					nan_step = step
				var seen: Dictionary = needs_seen.get(villager.object.id, {})
				# A villager that has not had a decision turn yet has no need at
				# all, and counting that empty string would make "wanted more than
				# one thing" pass on the strength of never having wanted anything.
				if villager.current_need != &"":
					seen[villager.current_need] = true
				needs_seen[villager.object.id] = seen

		if step % print_every == 0:
			rows.append(_row(float(step) * STEP))

	rows.append(_row(SIM_SECONDS))
	gut.p("   t(s) |  pop | food  | wood  | houses | fields | desire")
	for row: String in rows:
		gut.p(row)

	var final_population: int = _village.population()
	gut.p("population %d -> %d (%d births, %d deaths), %d acts of worship, %d at the temple" % [
		start_population, final_population,
		int(_village.births_total), int(_village.deaths_total),
		int(_village.worship_total), int(_village.worshipper_count())
	])
	gut.p("store: food %.1f, wood %.1f. Low water: food %.1f, wood %.1f" % [
		store.stock_of(VillageStore.FOOD), store.stock_of(VillageStore.WOOD),
		lowest_food, lowest_wood
	])
	gut.p("desires observed over the run: %s" % [desires_seen.keys()])

	assert_eq(start_population, 8, "the village should start with eight")
	assert_gte(final_population, 12, "twenty minutes should grow the village past twelve")
	assert_eq(negative_step, -1, "store levels must never go negative, checked every step")
	assert_eq(nan_step, -1, "no NaN may appear in villager or store state")
	assert_gte(lowest_food, 0.0)
	assert_gte(lowest_wood, 0.0)

	# No starvation deadlock: the village kept working the whole time rather
	# than stalling in a state where nobody could act.
	assert_gt(lowest_population, 0, "the village must not die out")
	assert_gte(lowest_population, start_population / 2,
		"a halved population would mean the food loop failed, not that it was tested")
	assert_gt(store.stock_of(VillageStore.FOOD), 0.0, "it should still be feeding itself")
	assert_gt(int(_village.worship_total), 0,
		"worship should have happened, or Phase 3 has nothing to draw on")
	assert_gt(_village.houses().size(), 2, "growth needs housing, and housing is built")
	# An indicator that names one need for twenty minutes is not reporting the
	# village, it is stuck on a need nobody can act on.
	assert_gt(desires_seen.size(), 1,
		"the village wanted the same thing for twenty minutes: %s" % [desires_seen.keys()])

	# Nothing stuck. Anyone old enough to have had a turn must have walked
	# somewhere and wanted more than one thing.
	var settled: int = 0
	var people: Array = _village.villagers()
	for villager: Villager in people:
		if villager.age_seconds < 120.0:
			continue
		settled += 1
		assert_gt(villager.distance_travelled, 5.0,
			"%s has not moved in %.0f seconds" % [villager.describe(), villager.age_seconds])
		assert_gt(villager.decisions_made, 1, "%s never got a turn" % villager.describe())
		var seen: Dictionary = needs_seen.get(villager.object.id, {})
		assert_gt(seen.size(), 1,
			"%s only ever wanted %s" % [villager.describe(), seen.keys()])
	gut.p("checked %d villagers older than two minutes for movement and need changes" % settled)
	assert_gt(settled, 4, "expected most of the village to be older than two minutes")

	# Claims are held by villagers on errands, so there can never be more of them
	# than there are villagers. More would mean an errand ended without releasing.
	assert_lte(store.claim_count(), final_population,
		"outstanding reservations outnumber the villagers holding them")


func test_the_village_works_its_way_out_of_an_empty_larder() -> void:
	# Starvation must be possible without being terminal. Drained through the
	# public path, so the store is genuinely empty rather than poked into a state
	# it could not reach on its own.
	_populate()
	var store: VillageStore = _village.store
	store.commit(store.reserve(VillageStore.FOOD, store.available(VillageStore.FOOD)))
	assert_eq(store.stock_of(VillageStore.FOOD), 0.0, "the larder should start empty")

	var recovered_at: float = -1.0
	for step in int(400.0 / STEP):
		_village.simulate(STEP)
		if recovered_at < 0.0 and store.stock_of(VillageStore.FOOD) > 0.0:
			recovered_at = float(step) * STEP

	gut.p("famine: first food banked at t=%.1fs, after 400s pop %d (%d dead), food %.1f" % [
		recovered_at, _village.population(), int(_village.deaths_total),
		store.stock_of(VillageStore.FOOD)
	])
	assert_gt(recovered_at, 0.0, "somebody should have gone to work and banked food")
	assert_lt(recovered_at, 120.0, "and well before anyone could starve")
	assert_gt(store.stock_of(VillageStore.FOOD), 0.0)
	assert_gte(_village.population(), 4, "a famine should not empty the village")


func test_only_a_slice_of_the_population_decides_on_a_tick() -> void:
	# The project's tick-budget bar. A village of two hundred must cost the same
	# per frame as a village of eight; it just takes longer to come round again.
	var tunables: VillageTunables = TUNABLES.new()
	tunables.villagers_per_decision_tick = 2
	_populate(tunables)

	assert_eq(_total_decisions(), 0, "populate should not have anyone deciding yet")
	_village.simulate(1.0 / tunables.decisions_per_second)

	gut.p("one decision tick over %d villagers: %d decided" % [
		_village.population(), _total_decisions()
	])
	assert_eq(_total_decisions(), 2, "exactly the slice, not the whole village")

	_village.simulate(1.0 / tunables.decisions_per_second)
	assert_eq(_total_decisions(), 4, "and the next tick moves on to the next two")


func test_the_creature_sees_the_village_through_the_object_registry() -> void:
	# Phase 4's perception already works. The village must appear in it with the
	# types the creature has attributes for, and must not grow a second
	# perception path of its own.
	_populate()
	assert_eq(_count(&"villager"), _village.population(), "every villager is registered")
	assert_eq(_count(&"store"), 1, "one storehouse at the village centre")
	assert_gte(_count(&"house"), 2)
	assert_gte(_count(&"wheat_field"), 2)

	for step in int(300.0 / STEP):
		_village.simulate(STEP)

	gut.p("after 300s: %d villagers, %d houses, %d fields registered" % [
		_count(&"villager"), _count(&"house"), _count(&"wheat_field")
	])
	assert_eq(_count(&"villager"), _village.population(),
		"births and deaths must keep the registry in step")

	var people: Array = _village.villagers()
	for villager: Villager in people:
		assert_eq(villager.object.current_position(), villager.position,
			"the registry record should follow the villager, not its spawn point")

	for object: WorldObject in _registry.all():
		if object.type == &"villager":
			continue
		var ground: float = _island.height_at(object.position.x, object.position.z)
		assert_gt(ground, 0.0, "%s was built below the waterline" % object)


func test_the_village_never_asks_for_something_nobody_can_do() -> void:
	# The indicator is ranked by the same score the villagers maximise, feasibility
	# included, so whatever it names must be something at least one villager could
	# go and do. Procreate is the one that used to stick: pinned at the population
	# ceiling nobody may breed, yet the need keeps climbing for everyone, and the
	# indicator read "procreate" for the rest of the run.
	var tunables: VillageTunables = TUNABLES.new()
	tunables.max_population = tunables.starting_population
	# Refreshed every step so the desire under test is the one the village just
	# computed, not one up to a second stale. simulate() refreshes after deciding,
	# so what is read here is exactly the state the ranking saw.
	tunables.desire_refresh_seconds = STEP
	_populate(tunables)

	var impossible_at: float = -1.0
	var impossible_desire: StringName = &""
	var desires_seen: Dictionary = {}
	for step in int(300.0 / STEP):
		_village.simulate(STEP)
		var desire: StringName = _village.current_desire()
		desires_seen[desire] = true
		if impossible_at < 0.0 and not _anyone_can(desire):
			impossible_at = float(step) * STEP
			impossible_desire = desire

	gut.p("at the population ceiling the village asked for: %s" % [desires_seen.keys()])
	assert_eq(int(_village.births_total), 0, "the ceiling should have stopped every birth")
	assert_eq(impossible_at, -1.0,
		"the village asked for '%s' at t=%.1fs, and not one villager could act on it" % [
			impossible_desire, impossible_at
		])


func test_a_villager_the_hand_puts_down_gets_up_again() -> void:
	# The divine hand hangs a physics body on the villager's record when it picks
	# one up and never takes it off again (src/hand/hand.gd never clears
	# WorldObject.node), so the villager has to hand itself back. Until it did, a
	# villager that was picked up and put down stood there until it starved.
	_populate()
	var villager: Villager = _village.villagers()[0]
	for step in int(60.0 / STEP):
		_village.simulate(STEP)

	# Exactly what hand.gd does on grab: a frozen kinematic body on the record.
	var body := RigidBody3D.new()
	add_child_autoqfree(body)
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = true
	var carried_to: Vector3 = _village.centre_position() + Vector3(18.0, 6.0, -12.0)
	body.global_position = carried_to
	villager.object.node = body

	for step in int(5.0 / STEP):
		_village.simulate(STEP)
	assert_lt(villager.position.distance_to(carried_to), 0.001,
		"a villager in the hand follows the body, not its own feet")

	# And on release: unfrozen, left where it was let go with no throw behind it,
	# which is a villager set down rather than flung.
	body.freeze = false
	body.linear_velocity = Vector3.ZERO

	var walked: float = villager.distance_travelled
	var needs_seen: Dictionary = {}
	for step in int(300.0 / STEP):
		_village.simulate(STEP)
		if villager.current_need != &"":
			needs_seen[villager.current_need] = true

	gut.p("put down at %v: walked %.1fm since, wanted %s" % [
		carried_to, villager.distance_travelled - walked, needs_seen.keys()
	])
	assert_true(villager.alive, "being put down should not be fatal")
	assert_null(villager.object.node, "the villager takes its body back once it has settled")
	assert_gt(villager.distance_travelled, walked + 5.0, "and walks off under its own steam")
	assert_almost_eq(villager.position.y,
		_village.ground_height(villager.position.x, villager.position.z), 0.01,
		"on the ground rather than wherever the hand let go")
	assert_gt(needs_seen.size(), 1, "and gets on with wanting more than one thing")


func _populate(tunables: VillageTunables = null) -> void:
	if tunables != null:
		_village.tunables = tunables
	_village.populate(_island, _registry, SEED)


func _row(at: float) -> String:
	var store: VillageStore = _village.store
	return "%7.0f | %4d | %5.1f | %5.1f | %6d | %6d | %s" % [
		at, _village.population(),
		store.stock_of(VillageStore.FOOD), store.stock_of(VillageStore.WOOD),
		_village.houses().size(), _village.fields().size(),
		_village.current_desire(),
	]


func _total_decisions() -> int:
	var total: int = 0
	var people: Array = _village.villagers()
	for villager: Villager in people:
		total += villager.decisions_made
	return total


## Whether anyone in the village could act on this need right now.
func _anyone_can(need: StringName) -> bool:
	var people: Array = _village.villagers()
	for villager: Villager in people:
		if villager.feasibility_of(need) > 0.0:
			return true
	return false


func _count(type: StringName) -> int:
	return _registry.query_near(Vector3.ZERO, 100000.0, [type]).size()


func _has_nan(villager: Villager) -> bool:
	if is_nan(villager.position.x) or is_nan(villager.position.y) or is_nan(villager.position.z):
		return true
	for need: StringName in Villager.NEEDS:
		if is_nan(float(villager.needs[need])):
			return true
	return false
