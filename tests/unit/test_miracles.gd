extends GutTest
## Phase 3b acceptance: prayer power, the influence ring, and the five miracles.
##
## Every rule here is one the player will discover by being refused, so each is
## proved with the real numbers rather than a shrug.

const REGISTRY := preload("res://src/world/object_registry.gd")

## Stand-in for the village. The whole point of the duck-typed `village` in
## miracle_effects.gd is that the one property the effects actually reach for is
## enough — and the store is the real VillageStore, so a deposit that the live
## village would reject is rejected here too.
class StubVillage:
	extends RefCounted
	var store := VillageStore.new()


var _tunables: MiracleTunables
var _library: MiracleLibrary
var _power: PrayerPower
var _influence: Influence
var _caster: MiracleCaster
var _registry: Node
var _village: StubVillage
var _effects: MiracleEffects


func before_each() -> void:
	_tunables = MiracleTunables.new()
	_library = MiracleLibrary.new()
	_power = PrayerPower.new(_tunables)
	_influence = Influence.new(_tunables, Vector3.ZERO)
	_influence.set_belief(20.0)

	_registry = REGISTRY.new()
	autofree(_registry)
	_village = StubVillage.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260729
	_effects = MiracleEffects.new(_registry, rng, _village)

	_caster = MiracleCaster.new(_power, _influence, _library)
	_caster.bind_effects(_effects)


# --- prayer power -----------------------------------------------------------


func test_prayer_power_accrues_from_worshippers_over_time() -> void:
	_power.set_current(0.0)
	gut.p("second | worshippers | pool")
	var previous: float = _power.current()
	for second in 8:
		_power.accrue(6, 1.0)
		gut.p("%6d | %11d | %6.2f" % [second + 1, 6, _power.current()])
		assert_gt(_power.current(), previous, "eight seconds of prayer should raise the pool")
		previous = _power.current()

	var expected: float = 8.0 * 6.0 * _tunables.prayer_per_worshipper
	gut.p("expected %.2f, got %.2f" % [expected, _power.current()])
	assert_almost_eq(_power.current(), expected, 0.0001,
		"income should be worshippers x rate x seconds")


func test_prayer_power_is_capped_and_an_empty_village_earns_nothing() -> void:
	for tick in 400:
		_power.accrue(20, 1.0)
	gut.p("pool after 400 s of 20 worshippers: %.2f (maximum %.2f)" % [
		_power.current(), _power.maximum
	])
	assert_eq(_power.current(), _power.maximum, "the pool must stop at its ceiling")

	var held: float = _power.current()
	_power.accrue(0, 10.0)
	# Regression: a paused or rewound clock must not drain the player's power.
	_power.accrue(6, -5.0)
	_power.accrue(-6, 5.0)
	gut.p("after no worshippers, negative delta and negative count: %.2f" % _power.current())
	assert_eq(_power.current(), held, "nobody praying is not the same as power leaking away")


func test_prayer_power_never_goes_negative() -> void:
	_power.set_current(10.0)
	var before: float = _power.current()

	var oversized: bool = _power.spend(1000.0)
	gut.p("spend(1000) with %.2f in the pool -> %s, pool now %.2f" % [
		before, str(oversized), _power.current()
	])
	assert_false(oversized, "a spend larger than the pool must fail")
	assert_eq(_power.current(), before, "and must spend nothing at all")

	# A negative cost would otherwise be free power.
	var negative: bool = _power.spend(-50.0)
	gut.p("spend(-50) -> %s, pool now %.2f" % [str(negative), _power.current()])
	assert_false(negative, "a negative spend must be refused, not credited")
	assert_eq(_power.current(), before)

	for attempt in 20:
		_power.spend(7.5)
		assert_gte(_power.current(), 0.0, "the pool went negative on attempt %d" % attempt)
	gut.p("pool after 20 x spend(7.5) from %.2f: %.2f" % [before, _power.current()])
	assert_gte(_power.current(), 0.0)


func test_prayer_power_roundtrips() -> void:
	_power.set_current(37.5)
	var restored := PrayerPower.new(_tunables)
	restored.from_dict(JSON.parse_string(JSON.stringify(_power.to_dict())))
	gut.p("saved %.4f, restored %.4f" % [_power.current(), restored.current()])
	assert_eq(restored.current(), _power.current())
	assert_eq(restored.maximum, _power.maximum)


# --- influence --------------------------------------------------------------


func test_influence_radius_grows_with_belief_and_clamps_at_both_ends() -> void:
	var ring := Influence.new(_tunables, Vector3.ZERO)
	gut.p("belief | radius")
	var previous: float = -1.0
	for belief: float in [0.0, 5.0, 10.0, 20.0, 30.0, 40.0]:
		ring.set_belief(belief)
		gut.p("%6.1f | %6.2f" % [belief, ring.radius])
		assert_gt(ring.radius, previous, "more belief must never shrink the ring")
		previous = ring.radius

	ring.set_belief(0.0)
	assert_eq(ring.radius, _tunables.influence_min_radius,
		"a god with no believers keeps the minimum ring")
	ring.set_belief(-100.0)
	gut.p("radius at belief -100: %.2f (floor %.2f)" % [
		ring.radius, _tunables.influence_min_radius
	])
	assert_eq(ring.radius, _tunables.influence_min_radius, "belief cannot go below nothing")

	ring.set_belief(100000.0)
	gut.p("radius at belief 100000: %.2f (ceiling %.2f)" % [
		ring.radius, _tunables.influence_max_radius
	])
	assert_eq(ring.radius, _tunables.influence_max_radius,
		"belief past the ceiling must stop buying radius")


func test_influence_is_measured_flat_and_ignores_height() -> void:
	# Regression. The ring is a circle painted on the ground and the island rises
	# 24 m; measured in 3D, a hilltop well inside the painted circle would refuse
	# miracles with no visible reason why.
	var ring := Influence.new(_tunables, Vector3.ZERO)
	ring.set_belief(0.0)
	var hilltop := Vector3(ring.radius - 1.0, 24.0, 0.0)
	gut.p("radius %.2f, point at %.1f m out and %.1f m up: contained=%s" % [
		ring.radius, hilltop.x, hilltop.y, str(ring.contains(hilltop))
	])
	assert_true(ring.contains(hilltop), "height must not push a point out of the ring")
	assert_false(ring.contains(Vector3(ring.radius + 1.0, 0.0, 0.0)))


# --- the library ------------------------------------------------------------


func test_the_five_miracles_have_distinct_ids_costs_and_gestures() -> void:
	var miracles: Array[Miracle] = _library.all()
	assert_eq(miracles.size(), 5, "there are five miracles")

	var seen_ids: Array[StringName] = []
	var seen_costs: Array[float] = []
	var seen_gestures: Array[StringName] = []
	gut.p("id | cost | radius | magnitude | alignment | gesture")
	for miracle: Miracle in miracles:
		gut.p("%-9s | %4.0f | %6.1f | %9.1f | %9.2f | %s" % [
			miracle.id, miracle.prayer_cost, miracle.effect_radius,
			miracle.magnitude, miracle.alignment_weight, miracle.gesture_template
		])
		assert_false(seen_ids.has(miracle.id), "duplicate id %s" % miracle.id)
		assert_false(seen_costs.has(miracle.prayer_cost),
			"%s shares a cost with another miracle" % miracle.id)
		assert_false(seen_gestures.has(miracle.gesture_template),
			"%s shares a gesture with another miracle" % miracle.id)
		assert_gt(miracle.prayer_cost, 0.0, "%s should cost something" % miracle.id)
		assert_ne(miracle.display_name, "", "%s needs a name to show" % miracle.id)
		assert_ne(miracle.description, "", "%s needs a description" % miracle.id)
		seen_ids.append(miracle.id)
		seen_costs.append(miracle.prayer_cost)
		seen_gestures.append(miracle.gesture_template)

	var expected_order: Array[StringName] = [&"food", &"wood", &"water", &"heal", &"lightning"]
	assert_eq(seen_ids, expected_order)


func test_alignment_weights_split_the_kind_miracles_from_the_cruel_one() -> void:
	# Phase 6 drives the player's alignment from this, so the signs matter more
	# than the magnitudes.
	for id: StringName in [&"food", &"wood", &"water", &"heal"]:
		var miracle: Miracle = _library.by_id(id)
		assert_gt(miracle.alignment_weight, 0.0, "%s should read as kind" % id)
	var lightning: Miracle = _library.by_id(&"lightning")
	gut.p("heal %+.2f vs lightning %+.2f" % [
		_library.by_id(&"heal").alignment_weight, lightning.alignment_weight
	])
	assert_lt(lightning.alignment_weight, 0.0, "lightning is the evil one")


func test_every_gesture_the_recogniser_can_return_casts_its_own_miracle() -> void:
	# Regression, and the one that proves the gesture-to-miracle path exists at
	# all. The library used to leave gesture_template defaulting to the miracle
	# id, so it advertised templates called "food" and "lightning" — names the
	# recogniser can never return, since the gesture module's five shapes are
	# spiral, chevron, wave, circle and bolt. Every gesture cast died at the
	# lookup, silently, and no test noticed because they all asked for "lightning".
	var template_names: Array = GestureTemplates.all().keys()
	assert_eq(template_names.size(), 5, "the gesture module should expose five templates")

	var reached: Array[StringName] = []
	gut.p("template | miracle | cost")
	for template_name: StringName in template_names:
		var miracle: Miracle = _library.by_gesture(template_name)
		assert_not_null(miracle, "no miracle answers the '%s' gesture" % template_name)
		if miracle == null:
			continue
		gut.p("%-8s | %-9s | %4.0f" % [template_name, miracle.id, miracle.prayer_cost])
		# The gesture module keeps its own table of what each shape casts. The two
		# have to agree, or drawing a chevron summons the wrong miracle.
		var expected_id: StringName = GestureTemplates.MIRACLES[template_name]
		assert_eq(miracle.id, expected_id,
			"'%s' should cast %s" % [template_name, expected_id])
		assert_false(reached.has(miracle.id), "%s is bound to two templates" % miracle.id)
		reached.append(miracle.id)

	assert_eq(reached.size(), _library.all().size(),
		"every miracle should be reachable by drawing something")


func test_gesture_lookup_is_by_template_name_and_survives_rebinding() -> void:
	assert_eq(_library.by_gesture(&"bolt").id, &"lightning")
	assert_null(_library.by_gesture(&"lightning"),
		"the lookup is by template name, not by miracle id")
	assert_null(_library.by_gesture(&"scribble"), "an unbound template maps to nothing")
	assert_null(_library.by_gesture(&""))

	# The gesture module owns the template names, so rebinding must take effect
	# immediately rather than after a cache nobody knows to invalidate.
	_library.by_id(&"food").gesture_template = &"scribble"
	assert_eq(_library.by_gesture(&"scribble").id, &"food")
	assert_null(_library.by_gesture(&"spiral"), "the old binding must be gone")


# --- casting rules ----------------------------------------------------------


func test_casting_inside_the_ring_is_allowed_and_outside_is_refused() -> void:
	_power.set_current(100.0)
	var inside := Vector3(_influence.radius * 0.5, 3.0, 0.0)
	var outside := Vector3(_influence.radius + 20.0, 0.0, 0.0)

	var allowed: Dictionary = _caster.try_cast(&"food", inside)
	gut.p("cast at %.1f m (radius %.1f): ok=%s reason='%s'" % [
		inside.length(), _influence.radius, str(allowed["ok"]), allowed["reason"]
	])
	assert_true(allowed["ok"], "a cast well inside the ring must be allowed")

	var refused: Dictionary = _caster.try_cast(&"food", outside)
	gut.p("cast at %.1f m (radius %.1f): ok=%s reason='%s'" % [
		outside.length(), _influence.radius, str(refused["ok"]), refused["reason"]
	])
	assert_false(refused["ok"])
	assert_true(str(refused["reason"]).contains("influence"),
		"the refusal has to tell the player it was out of reach, not just fail")


func test_an_unknown_miracle_is_refused_by_name() -> void:
	var result: Dictionary = _caster.try_cast(&"meteor", Vector3.ZERO)
	gut.p("try_cast(meteor): ok=%s reason='%s'" % [str(result["ok"]), result["reason"]])
	assert_false(result["ok"])
	assert_true(str(result["reason"]).contains("meteor"),
		"the reason should name what was asked for")


func test_an_unrecognised_gesture_is_refused_and_a_bound_one_casts() -> void:
	_power.set_current(100.0)
	var bad: Dictionary = _caster.cast_from_gesture(&"squiggle", Vector3.ZERO)
	gut.p("cast_from_gesture(squiggle): ok=%s reason='%s'" % [str(bad["ok"]), bad["reason"]])
	assert_false(bad["ok"])

	# Drawn as the player draws it: the recogniser returns a template name, never
	# a miracle id.
	var good: Dictionary = _caster.cast_from_gesture(&"wave", Vector3.ZERO)
	gut.p("cast_from_gesture(wave): ok=%s id=%s" % [str(good["ok"]), good["id"]])
	assert_true(good["ok"])
	assert_eq(good["id"], &"water")


func test_a_successful_cast_deducts_exactly_its_cost() -> void:
	_power.set_current(100.0)
	var cost: float = _library.by_id(&"heal").prayer_cost
	var before: float = _power.current()
	var result: Dictionary = _caster.try_cast(&"heal", Vector3.ZERO)
	gut.p("pool %.4f -> %.4f, cost %.4f" % [before, _power.current(), cost])
	assert_true(result["ok"])
	assert_eq(_power.current(), before - cost, "the pool should fall by exactly the cost")
	assert_eq(float(result["cost"]), cost)
	assert_eq(float(result["remaining"]), _power.current())


func test_a_refused_cast_deducts_nothing() -> void:
	# Three refusals, each for a different reason, none of them costing a penny.
	_power.set_current(100.0)
	var before: float = _power.current()

	var out_of_reach: Dictionary = _caster.try_cast(&"lightning", Vector3(500.0, 0.0, 0.0))
	gut.p("after out-of-ring refusal: %.10f (was %.10f) reason='%s'" % [
		_power.current(), before, out_of_reach["reason"]
	])
	assert_false(out_of_reach["ok"])
	assert_eq(_power.current(), before, "an out-of-ring refusal must not cost anything")

	var unknown: Dictionary = _caster.try_cast(&"meteor", Vector3.ZERO)
	assert_false(unknown["ok"])
	assert_eq(_power.current(), before, "an unknown miracle must not cost anything")

	# Ten is enough for water at 8 and nowhere near lightning at 40, so the same
	# pool proves both halves of can_afford.
	_power.set_current(10.0)
	var broke_before: float = _power.current()
	var too_dear: Dictionary = _caster.try_cast(&"lightning", Vector3.ZERO)
	gut.p("after unaffordable refusal: %.10f (was %.10f) reason='%s'" % [
		_power.current(), broke_before, too_dear["reason"]
	])
	assert_false(too_dear["ok"])
	assert_eq(_power.current(), broke_before,
		"a refused cast must leave the pool byte-identical")
	assert_false(_caster.can_afford(&"lightning"))
	assert_true(_caster.can_afford(&"water"))


func test_the_effect_handler_runs_only_on_a_successful_cast() -> void:
	# The caster must stay usable with no world at all, and must not apply an
	# effect it just refused.
	var calls: Array[StringName] = []
	var recorder := MiracleCaster.new(_power, _influence, _library)
	recorder.effect_handler = func(miracle: Miracle, at: Vector3) -> Vector3:
		calls.append(miracle.id)
		return at

	_power.set_current(100.0)
	recorder.try_cast(&"water", Vector3.ZERO)
	recorder.try_cast(&"water", Vector3(500.0, 0.0, 0.0))
	recorder.try_cast(&"meteor", Vector3.ZERO)

	var expected: Array[StringName] = [&"water"]
	gut.p("effect handler saw: %s" % [calls])
	assert_eq(calls, expected, "only the allowed cast should have reached the world")


# --- effects on the world ---------------------------------------------------


func test_food_miracle_spawns_food_piles_near_the_target() -> void:
	_power.set_current(100.0)
	var target := Vector3(10.0, 2.0, -4.0)
	var miracle: Miracle = _library.by_id(&"food")
	var before: int = _registry.query_near(target, miracle.effect_radius, [&"food_pile"]).size()

	var result: Dictionary = _caster.try_cast(&"food", target)
	var after: int = _registry.query_near(target, miracle.effect_radius, [&"food_pile"]).size()
	var summary: Dictionary = result["effect"]

	gut.p("food_pile objects within %.1f m of the target: %d -> %d (spawned %d)" % [
		miracle.effect_radius, before, after, (summary["spawned"] as Array).size()
	])
	assert_true(result["ok"])
	assert_eq(after, before + int(miracle.magnitude), "the miracle should leave real food behind")
	assert_eq((summary["spawned"] as Array).size(), int(miracle.magnitude))

	for id: int in summary["spawned"]:
		var object: WorldObject = _registry.get_object(id)
		assert_not_null(object, "a spawned pile should be in the registry")
		assert_lte(Vector2(object.position.x - target.x, object.position.z - target.z).length(),
			miracle.effect_radius, "food landed outside the miracle's own radius")


func test_wood_grows_trees_but_fills_the_village_store_when_one_is_standing_there() -> void:
	_power.set_current(200.0)
	var miracle: Miracle = _library.by_id(&"wood")

	var forest_spot := Vector3(20.0, 0.0, 0.0)
	var grown: Dictionary = _caster.try_cast(&"wood", forest_spot)["effect"]
	var trees: int = _registry.query_near(forest_spot, miracle.effect_radius, [&"tree"]).size()
	gut.p("with no store nearby: %d trees grown, village holds %.1f wood" % [
		trees, _village.store.stock_of(VillageStore.WOOD)
	])
	assert_eq(trees, int(miracle.magnitude), "with nowhere to put it, wood becomes trees")
	assert_eq((grown["spawned"] as Array).size(), trees)
	assert_eq(float(grown["deposited"]), 0.0)
	assert_eq(_village.store.stock_of(VillageStore.WOOD), 0.0,
		"a forest 20 m from the village is not a delivery")

	# Registered with a record and no node, which is exactly how village.gd
	# registers its storehouse. An effect that reached through WorldObject.node
	# would find nothing here, and that was the bug.
	var storehouse: WorldObject = _registry.add(&"store", Vector3(-20.0, 0.0, 0.0))
	var delivered: Dictionary = _caster.try_cast(&"wood", storehouse.position)["effect"]
	gut.p("with the storehouse in the blast: deposited %.1f, village holds %.1f, trees %d" % [
		float(delivered["deposited"]), _village.store.stock_of(VillageStore.WOOD),
		_registry.query_near(storehouse.position, miracle.effect_radius, [&"tree"]).size()
	])
	assert_eq(_village.store.stock_of(VillageStore.WOOD), miracle.magnitude,
		"the timber should have landed in the village's own stock")
	assert_eq(float(delivered["deposited"]), miracle.magnitude)
	assert_eq((delivered["spawned"] as Array).size(), 0,
		"no forest should sprout on top of the village")
	assert_true((delivered["affected"] as Array).has(storehouse.id))


func test_wood_falls_back_to_trees_when_there_is_no_village_to_take_it() -> void:
	# The registry-only wiring: a world with a store record in it but no village
	# behind the store has nowhere to put timber, so the miracle must still leave
	# something real rather than quietly depositing into nothing.
	var miracle: Miracle = _library.by_id(&"wood")
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var villageless := MiracleEffects.new(_registry, rng, null)
	_registry.add(&"store", Vector3.ZERO)

	var summary: Dictionary = villageless.apply(miracle, Vector3.ZERO)
	var trees: int = _registry.query_near(Vector3.ZERO, miracle.effect_radius, [&"tree"]).size()
	gut.p("no village attached: deposited %.1f, %d trees grown" % [
		float(summary["deposited"]), trees
	])
	assert_eq(float(summary["deposited"]), 0.0, "there is no store behind the record to fill")
	assert_eq(trees, int(miracle.magnitude), "so the timber has to become a forest instead")


func test_water_and_heal_reach_exactly_what_is_in_range() -> void:
	# Everything here is registered the way the village registers it: a record and
	# no node. These two miracles report rather than change — see the ponytail
	# notes in miracle_effects.gd — so what is provable is that they pick out the
	# right objects, which is what a moisture or health model would then act on.
	_power.set_current(200.0)
	var water: Miracle = _library.by_id(&"water")
	var heal: Miracle = _library.by_id(&"heal")

	var near_field: WorldObject = _registry.add(&"wheat_field", Vector3(3.0, 0.0, 0.0))
	var far_field: WorldObject = _registry.add(
		&"wheat_field", Vector3(water.effect_radius + 5.0, 0.0, 0.0)
	)
	var near_villager: WorldObject = _registry.add(&"villager", Vector3(-2.0, 0.0, 1.0))
	var far_villager: WorldObject = _registry.add(
		&"villager", Vector3(0.0, 0.0, heal.effect_radius + 5.0)
	)
	var beast: WorldObject = _registry.add(&"creature", Vector3(1.0, 0.0, -1.0))

	var watered: Array = _caster.try_cast(&"water", Vector3.ZERO)["effect"]["affected"]
	var healed: Array = _caster.try_cast(&"heal", Vector3.ZERO)["effect"]["affected"]
	gut.p("water reached %s of the fields, heal reached %s" % [watered.size(), healed.size()])

	assert_true(watered.has(near_field.id), "the field under the cast should have been watered")
	assert_false(watered.has(far_field.id),
		"a field %.0f m out is beyond water's %.0f m reach" % [
			water.effect_radius + 5.0, water.effect_radius
		])
	assert_false(watered.has(near_villager.id), "water is for fields, not for people")

	assert_true(healed.has(near_villager.id), "the hurt villager standing there should be mended")
	assert_true(healed.has(beast.id), "healing your own creature is the point of the miracle")
	assert_false(healed.has(far_villager.id), "a villager outside the radius is out of reach")
	assert_false(healed.has(near_field.id), "heal is for the living")


func test_lightning_destroys_scenery_but_never_erases_a_living_thing() -> void:
	_power.set_current(200.0)

	var tree: WorldObject = _registry.add(&"tree", Vector3(1.0, 0.0, 0.0))
	var pile: WorldObject = _registry.add(&"food_pile", Vector3(0.0, 0.0, 2.0))
	var store: WorldObject = _registry.add(&"store", Vector3(2.0, 0.0, 2.0))
	var far_tree: WorldObject = _registry.add(&"tree", Vector3(0.0, 0.0, 60.0))
	# Erasing this would leave the creature walking about with a dangling
	# self_object_id and nothing in the world able to perceive it.
	var beast: WorldObject = _registry.add(&"creature", Vector3(0.5, 0.0, 0.5))
	var villager: WorldObject = _registry.add(&"villager", Vector3(-1.0, 0.0, -1.0))
	# The village keeps these in _houses/_fields and never filters those arrays by
	# .alive, so burning one would leave it planning around a building that is not
	# there. Same rule as the villager: nothing burns until something owns its
	# teardown.
	var house: WorldObject = _registry.add(&"house", Vector3(-2.0, 0.0, 1.0))
	var field: WorldObject = _registry.add(&"wheat_field", Vector3(1.0, 0.0, -2.0))

	var before: int = _registry.count()
	var summary: Dictionary = _caster.try_cast(&"lightning", Vector3.ZERO)["effect"]
	gut.p("registry %d -> %d objects; removed %s; struck %s" % [
		before, _registry.count(), summary["removed"], summary["affected"]
	])

	assert_null(_registry.get_object(tree.id), "a tree in the blast should be gone")
	assert_null(_registry.get_object(pile.id))
	assert_true((summary["removed"] as Array).has(tree.id))
	assert_true((summary["removed"] as Array).has(pile.id))

	assert_not_null(_registry.get_object(far_tree.id), "a tree 60 m away is not in range")
	assert_false((summary["affected"] as Array).has(far_tree.id))

	for survivor: WorldObject in [store, beast, villager, house, field]:
		assert_not_null(_registry.get_object(survivor.id),
			"lightning erased a %s, whose record another module owns" % survivor.type)
		assert_true((summary["affected"] as Array).has(survivor.id),
			"a %s in the blast should still be reported as struck" % survivor.type)


func test_every_miracle_has_an_effect_that_does_something() -> void:
	# The acceptance criterion that catches a miracle added to the library and
	# never wired into miracle_effects.gd: it would cost power and do nothing.
	#
	# Each arm asserts the specific thing that miracle is for, read back out of the
	# world rather than out of the summary the effect wrote about itself. A count
	# of ids in the report is not evidence: an effect that appends an id and then
	# forgets to act would pass one and fail these. The unmatched arm is the trap
	# for a sixth miracle added without an assertion here.
	gut.p("miracle | handled | spawned | affected | removed | deposited")
	for miracle: Miracle in _library.all():
		var world: Node = REGISTRY.new()
		autofree(world)
		var village := StubVillage.new()
		var villager: WorldObject = world.add(&"villager", Vector3(1.0, 0.0, 0.0))
		var field: WorldObject = world.add(&"wheat_field", Vector3(2.0, 0.0, 1.0))
		var tree: WorldObject = world.add(&"tree", Vector3(3.0, 0.0, -1.0))
		world.add(&"food_pile", Vector3(0.0, 0.0, 2.0))
		world.add(&"store", Vector3(0.5, 0.0, 0.5))

		var rng := RandomNumberGenerator.new()
		rng.seed = 4242
		var effects := MiracleEffects.new(world, rng, village)
		var summary: Dictionary = effects.apply(miracle, Vector3.ZERO)

		gut.p("%-9s | %7s | %7d | %8d | %7d | %9.1f" % [
			miracle.id, str(summary["handled"]),
			(summary["spawned"] as Array).size(),
			(summary["affected"] as Array).size(),
			(summary["removed"] as Array).size(),
			float(summary["deposited"]),
		])
		assert_true(summary["handled"], "%s has no effect wired up" % miracle.id)
		assert_eq(float(summary["alignment_weight"]), miracle.alignment_weight)

		match miracle.id:
			&"food":
				# The one pile that was already there, plus what the miracle left.
				assert_eq(
					world.query_near(Vector3.ZERO, miracle.effect_radius, [&"food_pile"]).size(),
					int(miracle.magnitude) + 1,
					"food should leave real piles in the world")
			&"wood":
				assert_eq(village.store.stock_of(VillageStore.WOOD), miracle.magnitude,
					"wood cast over a storehouse should end up in the village's stock")
			&"water":
				assert_true((summary["affected"] as Array).has(field.id),
					"water should reach the field it was cast over")
			&"heal":
				assert_true((summary["affected"] as Array).has(villager.id),
					"heal should reach the villager it was cast over")
			&"lightning":
				assert_null(world.get_object(tree.id), "lightning should burn the tree")
				assert_not_null(world.get_object(villager.id),
					"and never erase the villager standing next to it")
				assert_true((summary["affected"] as Array).has(villager.id))
			_:
				fail_test(
					"%s is in the library with no assertion here about what it does" % miracle.id
				)


func test_bound_effects_outlive_the_caller_that_built_them() -> void:
	# Regression. A Callable made from a method stores only an object id, so
	# `caster.effect_handler = MiracleEffects.new(...).apply` frees the effects
	# object the moment the caller's reference goes out of scope, and every
	# miracle after that costs power and silently does nothing.
	var caster := MiracleCaster.new(_power, _influence, _library)
	_bind_throwaway_effects(caster)

	_power.set_current(100.0)
	var result: Dictionary = caster.try_cast(&"food", Vector3.ZERO)
	var spawned: int = _registry.query_near(Vector3.ZERO, 6.0, [&"food_pile"]).size()
	gut.p("food piles after casting through a dropped effects object: %d" % spawned)
	assert_true(result["ok"])
	assert_gt(spawned, 0, "the effects object was collected out from under the caster")


## Builds an effects object, binds it, and drops its only other reference on
## return. Deliberately a separate function so the local really does go away.
func _bind_throwaway_effects(caster: MiracleCaster) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	caster.bind_effects(MiracleEffects.new(_registry, rng))


func test_effects_survive_a_missing_registry() -> void:
	# The orchestrator wires this up with get_node_or_null, so a null registry is
	# a state this class can genuinely be constructed in.
	var orphan := MiracleEffects.new(null, null)
	var summary: Dictionary = orphan.apply(_library.by_id(&"food"), Vector3.ZERO)
	assert_false(summary["handled"])
	assert_eq((summary["spawned"] as Array).size(), 0)
	pass_test("a miracle cast with no world attached is a no-op rather than a crash")
