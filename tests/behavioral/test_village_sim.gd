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
## Long enough for the moisture comparison to accumulate several harvests per
## farmer, short enough that running the village twice costs a quarter of the
## acceptance run.
const MOISTURE_RUN_SECONDS := 300.0
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
	# Moisture now gates the harvest, so the run has to prove the village still
	# feeds itself once every field has dried out. Health is the other half of the
	# same regression: a village that quietly starves is one that is losing health.
	var lowest_health: float = INF
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
				lowest_health = minf(lowest_health, villager.health)
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
	gut.p("   t(s) |  pop | food  | wood  | houses | fields | moist | desire")
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
	gut.p("field moisture at the end: %.3f mean over %d fields. Lowest health seen: %.3f" % [
		_mean_moisture(), _village.fields().size(), lowest_health
	])
	gut.p("harvest now yields %.2f food from these fields, against %.2f from soaked ones" % [
		_village.harvest_yield(_village.fields()[0]),
		_village.tunables.harvest_food,
	])

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
	# The moisture regression. Nobody cast water for twenty minutes, so the founding
	# field must be bone dry by now — which means the population and store figures
	# above were earned at the dry floor rather than coasting on the moisture the
	# village was built with. If this ever reads wet, the run stopped testing it.
	#
	# The founding field rather than the mean: fields raised late in the run start
	# wet and are still drying, so a mean would move with how fast the village grew.
	assert_lt(_village.field_moisture(_village.fields()[0]), 0.01,
		"the founding field should be dry by t=%.0f, or the floor was never exercised"
			% SIM_SECONDS)
	# What lowest_health is actually instrumentation for. Every write to health goes
	# through maxf/minf/clampf against health_min and health_max, so [0,1] is
	# structural and NaN is already covered by nan_step — asserting either proves
	# nothing. The bound worth asserting is the gameplay one: a village quietly
	# starving at the dry harvest floor shows up here as a low reading long before it
	# shows up as a death, and the line for "seriously hurt" is a wound one cast of
	# heal could not put right. Taken from the miracle rather than picked, because
	# that dose is what the player actually has to hand.
	#
	# If this fails, raise harvest_dry_yield_fraction — same advice as the moisture
	# assertions above. A village that has to be watered to stay healthy makes water
	# a chore the player must keep up with rather than a blessing cast to do better.
	var mendable: float = MiracleLibrary.new().by_id(&"heal").magnitude
	assert_gt(lowest_health, _village.tunables.health_max - mendable,
		"the dry harvest floor left somebody at health %.3f, worse than one heal mends"
			% lowest_health)
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


func test_a_starving_villager_dies_and_the_same_famine_spares_a_healed_one() -> void:
	# The whole justification for the heal miracle: healing has to be the difference
	# between a corpse and a survivor, not a number that goes up. Two villagers, the
	# same famine, and the only difference is that one of them gets mended.
	#
	# Advanced by hand rather than through simulate() on purpose: the village's own
	# farmers refill an emptied store within nine seconds (the famine test above
	# measures it), so there is no way to hold a real famine open through the loop.
	_populate()
	var tunables: VillageTunables = _village.tunables
	var doomed: Villager = _village.villagers()[0]
	var saved: Villager = _village.villagers()[1]
	doomed.needs[Villager.FOOD] = 1.0
	saved.needs[Villager.FOOD] = 1.0
	assert_eq(doomed.health, 1.0, "villagers should start hale")

	# The real miracle's magnitude, so this proves the shipped heal saves a life
	# rather than proving that some large enough number would.
	var dose: float = MiracleLibrary.new().by_id(&"heal").magnitude
	# Cast when the villager is visibly dying rather than on a schedule, which is
	# also when a player would reach for it.
	var cast_below: float = 0.25
	var casts: int = 0
	var restored: float = 0.0
	var died_at: float = -1.0
	var rows: Array[String] = []

	for second in int(tunables.starve_seconds * 1.5):
		doomed.advance(1.0)
		saved.advance(1.0)
		var elapsed: float = float(second + 1)
		if died_at < 0.0 and not doomed.alive:
			died_at = elapsed
		if saved.alive and saved.health < cast_below:
			# Through the village's own seam, exactly as the miracle reaches it.
			var mended: int = _village.heal_villagers_near(saved.position, 2.0, dose)
			casts += 1
			restored += float(mended)
		if second % 20 == 0:
			rows.append("%6.0f | %8.3f | %8.3f | %5d" % [
				elapsed, doomed.health, saved.health, casts
			])

	gut.p("   t(s) | unhealed |   healed | casts")
	for row: String in rows:
		gut.p(row)
	gut.p("unhealed died at t=%.0fs, against starve_seconds of %.0f" % [
		died_at, tunables.starve_seconds
	])
	gut.p("healed survived the whole %.0fs on %d casts of %.2f, ending at health %.3f" % [
		tunables.starve_seconds * 1.5, casts, dose, saved.health
	])

	assert_false(doomed.alive, "a villager at maximum hunger has to die of it")
	assert_between(died_at, tunables.starve_seconds - 2.0, tunables.starve_seconds + 2.0,
		"death should land on starve_seconds, which is now a drain rate rather than a stopwatch")
	assert_true(saved.alive, "and healing has to be the thing that prevents that")
	assert_gt(casts, 0, "the test never actually healed anybody")
	assert_gt(saved.health, 0.0)
	assert_almost_eq(restored, float(casts), 0.0001,
		"every cast should have found exactly the one hurt villager in range")

	# Death has to go through the one existing path. _reap() runs inside simulate(),
	# so one step settles it: the roster, the registry and the counter all move
	# together, and no second way to die has been added alongside them.
	var claims_before: int = _village.store.claim_count()
	var population_before: int = _village.population()
	_village.simulate(STEP)
	gut.p("after reaping: pop %d -> %d, deaths %d, outstanding claims %d -> %d" % [
		population_before, _village.population(), int(_village.deaths_total),
		claims_before, _village.store.claim_count()
	])
	assert_eq(int(_village.deaths_total), 1, "the death should have been reported and reaped")
	assert_false(_village.villagers().has(doomed), "and the corpse taken off the roster")
	assert_true(_village.villagers().has(saved))
	assert_eq(doomed.heal(1.0), 0.0, "healing must not resurrect somebody already reaped")


func test_a_dry_field_yields_measurably_less_food_than_a_wet_one() -> void:
	# Moisture has to reach the store, not just a number on a field. Two identical
	# villages over the same five minutes, differing only in how wet their fields
	# are; growth is pinned off so the two are feeding the same eight mouths and the
	# difference in the larder is the difference in the harvest.
	var tunables := TUNABLES.new()
	var dry: Dictionary = _run_with_moisture(0.0)
	var wet: Dictionary = _run_with_moisture(1.0)
	var margin: float = tunables.harvest_food * (1.0 - tunables.harvest_dry_yield_fraction)

	gut.p("fields | per harvest | food banked over %.0fs | pop | dead" % MOISTURE_RUN_SECONDS)
	gut.p("dry    | %11.2f | %20.1f | %3d | %4d" % [
		dry["yield"], dry["food"], dry["population"], dry["deaths"]
	])
	gut.p("wet    | %11.2f | %20.1f | %3d | %4d" % [
		wet["yield"], wet["food"], wet["population"], wet["deaths"]
	])
	gut.p("watering was worth %.1f food, at least one extra harvest (%.1f) being the bar" % [
		float(wet["food"]) - float(dry["food"]), margin
	])

	assert_almost_eq(float(dry["yield"]),
		tunables.harvest_food * tunables.harvest_dry_yield_fraction, 0.0001,
		"a bone-dry field should pay the floor fraction of a full harvest")
	assert_almost_eq(float(wet["yield"]), tunables.harvest_food, 0.0001,
		"and a soaked one the whole of it")
	assert_gt(float(wet["food"]) - float(dry["food"]), margin,
		"a wet village must bank measurably more food than a dry one")

	# The floor is what keeps a neglected village merely poorer rather than doomed:
	# eight unwatered villagers still have to come out of five minutes fed, housed
	# and all present. If this ever fails, raise harvest_dry_yield_fraction — the
	# alternative is a game where forgetting to cast water is a death sentence.
	assert_gt(float(dry["food"]), 0.0,
		"a village nobody ever waters still has to bank food, or water is a chore")
	assert_eq(int(dry["population"]), tunables.starting_population,
		"and must not have starved anybody at the dry floor")
	assert_eq(int(wet["population"]), tunables.starting_population,
		"growth was pinned off, so the two villages fed the same eight mouths")


func test_watering_a_field_raises_its_moisture_and_its_harvest() -> void:
	_populate()
	var tunables: VillageTunables = _village.tunables
	var field: WorldObject = _village.fields()[0]
	assert_almost_eq(_village.field_moisture(field), tunables.field_moisture_initial, 0.0001,
		"fields are ploughed wet")

	# Dried out by the clock rather than by poking the number: this is the state a
	# village nobody waters is genuinely in after the decay has run its course.
	var dry_seconds: float = tunables.field_moisture_initial \
		/ tunables.field_moisture_decay_per_second
	for step in int(dry_seconds / STEP):
		_village.simulate(STEP)
	var dry_moisture: float = _village.field_moisture(field)
	var dry_yield: float = _village.harvest_yield(field)

	var dose: float = MiracleLibrary.new().by_id(&"water").magnitude
	var spot: Vector3 = field.current_position()
	var watered: int = _village.water_fields_near(spot, 1.0, dose)
	var again: int = _village.water_fields_near(spot, 1.0, dose)

	gut.p("field over %.0fs of decay: moisture %.3f -> %.3f, harvest %.2f -> %.2f" % [
		dry_seconds, tunables.field_moisture_initial, dry_moisture,
		dry_yield, _village.harvest_yield(field)
	])
	gut.p("water of %.2f: %d field(s) took it, a second cast changed %d" % [dose, watered, again])

	# almost_eq rather than eq: two thousand subtractions of 0.0005 leave residue of
	# the order of 1e-16, and the floor clamp only catches it once it goes negative.
	assert_almost_eq(dry_moisture, 0.0, 0.0001,
		"decay should have taken the field all the way down")
	assert_almost_eq(dry_yield,
		tunables.harvest_food * tunables.harvest_dry_yield_fraction, 0.0001)
	assert_eq(watered, 1, "the one field under the cast should have taken water")
	assert_gt(_village.field_moisture(field), dry_moisture)
	assert_gt(_village.harvest_yield(field), dry_yield,
		"and the point of watering is that the next harvest is bigger")
	assert_eq(again, 0, "a field already soaked must report that nothing changed")

	# A field record the village does not own is not the village's to water. Without
	# the guard, water_field would happily invent a moisture entry for it.
	var stray := WorldObject.new(999999, &"wheat_field", spot)
	var on_stray: float = _village.water_field(stray, 1.0)
	gut.p("watering a field record the village does not own added %.2f" % on_stray)
	assert_eq(on_stray, 0.0)
	assert_eq(_village.field_moisture(stray), 0.0)
	assert_eq(_village.water_field(null, 1.0), 0.0)
	assert_eq(_village.water_field(field, -5.0), 0.0, "a negative cast must not dry a field out")


func test_healing_counts_only_the_villagers_it_actually_mends() -> void:
	_populate()
	var people: Array = _village.villagers()
	var centre: Vector3 = _village.centre_position()
	var dose: float = MiracleLibrary.new().by_id(&"heal").magnitude
	var reach: float = 100.0

	var over_the_hale: int = _village.heal_villagers_near(centre, reach, dose)
	people[0].health = 0.3
	people[1].health = 1.0 - dose * 0.5
	var mended: int = _village.heal_villagers_near(centre, reach, dose)

	gut.p("heal over %d hale villagers mended %d; with two hurt it mended %d" % [
		people.size(), over_the_hale, mended
	])
	gut.p("the badly hurt one went 0.300 -> %.3f, the scratched one -> %.3f (capped at 1.0)" % [
		people[0].health, people[1].health
	])
	assert_eq(over_the_hale, 0, "casting heal over a healthy village must report nothing changed")
	assert_eq(mended, 2, "exactly the two who were short of full health")
	assert_almost_eq(people[0].health, 0.3 + dose, 0.0001)
	assert_eq(people[1].health, 1.0, "a partial heal must cap rather than overfill")

	people[2].health = 0.5
	var out_of_reach: int = _village.heal_villagers_near(
		centre + Vector3(500.0, 0.0, 0.0), 10.0, dose
	)
	gut.p("cast 500 m away mended %d, and the hurt villager is still at %.3f" % [
		out_of_reach, people[2].health
	])
	assert_eq(out_of_reach, 0, "a cast nowhere near the village must mend nobody")
	assert_eq(people[2].health, 0.5)


func test_a_real_miracle_reaches_the_real_village() -> void:
	# The seam itself, both halves of it wired together. tests/unit/test_miracles.gd
	# proves MiracleEffects calls a StubVillage whose two signatures are hand-copied
	# from village.gd, and the two tests above prove the village's own methods work
	# when called directly — but nothing ran the two against each other. The only
	# guard on the join is has_method(), which checks a name and neither the arity nor
	# the order of the parameters, so transposing radius and amount on the village
	# side would break both miracles in the game with both suites green.
	_populate()
	var tunables: VillageTunables = _village.tunables
	var library := MiracleLibrary.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	# Wired the way main.gd wires it: the real registry, the real village, no stub
	# anywhere in the chain.
	var effects := MiracleEffects.new(_registry, rng, _village)

	# Cast beside the villager rather than on top of it, so the radius is load
	# bearing: with radius and amount transposed the miracle would reach 0.5 m and
	# mend nobody, which a cast at the villager's own feet would never notice.
	var heal: Miracle = library.by_id(&"heal")
	var hurt: Villager = _village.villagers()[0]
	hurt.health = 0.3
	var beside: Vector3 = hurt.position + Vector3(heal.effect_radius * 0.5, 0.0, 0.0)
	var mended: Dictionary = effects.apply(heal, beside)
	gut.p("heal cast %.1f m from a villager at 0.300: changed %d, health now %.3f" % [
		heal.effect_radius * 0.5, int(mended["changed"]), hurt.health
	])
	assert_eq(int(mended["changed"]), 1,
		"the one hurt villager, counted by the real village rather than by a stub")
	assert_almost_eq(hurt.health, 0.3 + heal.magnitude, 0.0001,
		"and the real villager has to be the thing that got better")
	assert_true((mended["affected"] as Array).has(hurt.object.id),
		"the registry record is what the VFX layer draws, so it has to be reported too")

	# Water needs a field that is not already soaked, and the honest way to get one is
	# the clock. Part-dried rather than all the way down: how dry it is makes no
	# difference to the seam, and the full decay costs two thousand more steps.
	for step in int(60.0 / STEP):
		_village.simulate(STEP)
	var field: WorldObject = _village.fields()[0]
	# Every other field soaked first, so the count can only be the field under the
	# cast however many fields the village raised while this one was drying.
	for other: WorldObject in _village.fields():
		if other != field:
			_village.water_field(other, tunables.field_moisture_initial)
	var dry: float = _village.field_moisture(field)
	var water: Miracle = library.by_id(&"water")
	var over: Vector3 = field.current_position() + Vector3(water.effect_radius * 0.5, 0.0, 0.0)
	var watered: Dictionary = effects.apply(water, over)
	gut.p("water cast %.1f m from a field at moisture %.3f: changed %d, moisture now %.3f" % [
		water.effect_radius * 0.5, dry, int(watered["changed"]), _village.field_moisture(field)
	])
	assert_lt(dry, tunables.field_moisture_initial, "the field should have dried on the clock")
	assert_eq(int(watered["changed"]), 1,
		"the one dry field, counted by the real village rather than by a stub")
	assert_gt(_village.field_moisture(field), dry,
		"and the real field's moisture has to be the thing that rose")
	assert_true((watered["affected"] as Array).has(field.id))


func test_only_a_slice_of_the_population_decides_on_a_tick() -> void:
	# The project's tick-budget bar. Deciding is rationed: only a slice of the
	# population re-scores on any one tick, and everybody else is already walking or
	# working, which costs a float add each.
	#
	# The slice is the larger of villagers_per_decision_tick and
	# decision_slice_fraction of the population. Eight villagers at 0.2 comes to two,
	# which is the floor set below as well, so the slice under test here is exactly
	# two either way. The proportional half is covered at two hundred by
	# tests/behavioral/test_village_crowd.gd, where a flat count would leave each
	# villager standing idle for ten seconds waiting its turn.
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
	return "%7.0f | %4d | %5.1f | %5.1f | %6d | %6d | %5.2f | %s" % [
		at, _village.population(),
		store.stock_of(VillageStore.FOOD), store.stock_of(VillageStore.WOOD),
		_village.houses().size(), _village.fields().size(),
		_mean_moisture(),
		_village.current_desire(),
	]


## Mean moisture over the village's fields. A mean rather than a per-field check
## because what the run has to show is the whole harvest drying up: fields raised
## late start wet and would each need their own baseline.
func _mean_moisture() -> float:
	var fields: Array = _village.fields()
	if fields.is_empty():
		return 0.0
	var total: float = 0.0
	for field: WorldObject in fields:
		total += _village.field_moisture(field)
	return total / float(fields.size())


## Runs a village of its own for MOISTURE_RUN_SECONDS with every field pinned at
## one moisture level, and reports what it banked.
##
## Decay is switched off and growth pinned at the starting population so exactly
## one thing differs between two calls. Without the population pin the wet village
## grows faster, eats more and pays for more births, and the larder stops measuring
## the harvest — the first version of this test compared two villages of different
## sizes and the dry one looked thriftier.
func _run_with_moisture(moisture: float) -> Dictionary:
	var tunables := TUNABLES.new()
	tunables.field_moisture_initial = moisture
	tunables.field_moisture_decay_per_second = 0.0
	tunables.max_population = tunables.starting_population

	# Its own registry as well as its own village: two villages settling the same
	# seeded island land on the same centre, and sharing a registry would have each
	# one's farmers walking to the other's fields.
	var registry: Node = REGISTRY.new()
	autofree(registry)
	var village: Node3D = VILLAGE.new()
	village.auto_simulate = false
	village.tunables = tunables
	add_child_autofree(village)
	village.populate(_island, registry, SEED)

	var store: VillageStore = village.store
	var opening: float = store.stock_of(VillageStore.FOOD)
	for step in int(MOISTURE_RUN_SECONDS / STEP):
		village.simulate(STEP)
	return {
		"food": store.stock_of(VillageStore.FOOD) - opening,
		"population": village.population(),
		"deaths": int(village.deaths_total),
		"yield": village.harvest_yield(village.fields()[0]),
	}


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
	if is_nan(villager.health):
		return true
	for need: StringName in Villager.NEEDS:
		if is_nan(float(villager.needs[need])):
			return true
	return false
