class_name MiracleEffects
extends RefCounted
## The world half of a miracle: what actually happens when one lands.
##
## Split from MiracleCaster so the caster — the rules about cost and reach — can
## be tested with no world at all. Wire the two together with two lines:
##
##     var effects := MiracleEffects.new(
##         get_node_or_null(^"/root/World"), rng, [home_village, rival_village]
##     )
##     caster.bind_effects(effects)
##
## Use bind_effects rather than assigning caster.effect_handler directly: a
## Callable does not keep a RefCounted alive on its own.
##
## Both the registry and the villages arrive as constructor parameters and are only
## ever duck-typed, so the standalone `object_registry.gd` instance the tests build
## works exactly like the live autoload, and a five-line stub works like the real
## village. Never name the autoload directly in here: GDScript resolves `World` at
## compile time and the script then fails to compile anywhere the autoload is
## absent, test runs included. The villages are held as bare Objects for a
## different reason — the same one Villager holds its village that way: naming the
## type would make the two modules cyclically dependent and neither would compile.
##
## Plural, and that is the whole of why: the game has two villages, home and rival,
## and both register their people and fields with the *same* object registry. With
## one village here, water and heal cast over the rival found its fields and
## villagers in the registry and reported them to the VFX layer, while the change
## itself went to the home village's own arrays — so the miracle played and nothing
## happened. Casting kind miracles near the rival is how its belief is earned, so
## that was the main path for both effects.
##
## Effects act on the registry and on the village's own public API, never through
## `WorldObject.node`. Almost nothing in this world has a node: the village
## registers its villagers, houses, fields and storehouse with a record and no
## node at all, and scenery lives in a MultiMesh. An effect that called through
## `node` would be a silent no-op against the actual game.

## What lightning erases outright: scenery and stockpiles, which no other system
## keeps a list of and so nothing else has to be told about.
##
## The obvious way round — listing what is immune and burning the rest — is the
## wrong one. Anything missing from that list would be erased from the registry
## while the system that owns it carried on holding the record: the creature would
## keep a dangling self_object_id, and the village a dead house in `_houses`.
##
## `house` and `wheat_field` are deliberately not here even though they are as
## inert as a tree. The village keeps them in `_houses`/`_fields` and never
## filters those arrays by `.alive`, so burning one would leave the village
## planning around a building that no longer exists. Same rule as the villager:
## nothing gets destroyed until something owns its teardown.
const LIGHTNING_DESTROYS: Array[StringName] = [&"tree", &"rock", &"food_pile"]

## Villagers first, but the creature too — healing your own creature after a
## fight is one of the moments the whole teaching loop is built around.
const HEAL_TYPES: Array[StringName] = [&"villager", &"creature"]

## Key the village stores timber under. Duplicated from VillageStore.WOOD rather
## than imported, so this module compiles with no village module present.
const RESOURCE_WOOD := &"wood"

var registry: Object = null
## Every village whose people, fields and stock these effects may change — home and
## rival alike. Empty when there is none: a unit test, or the world before
## populate(). Every use of it degrades to "do the registry-only thing".
var villages: Array = []
var rng: RandomNumberGenerator


func _init(
	world_registry: Object = null,
	generator: RandomNumberGenerator = null,
	owning_villages: Variant = null
) -> void:
	registry = world_registry
	# One village or a list of them, normalised here so no caller has to care and
	# the single-village wiring the tests use keeps working unchanged.
	if owning_villages is Array:
		for one: Variant in owning_villages:
			if one != null:
				villages.append(one)
	elif owning_villages != null:
		villages.append(owning_villages)
	if generator != null:
		rng = generator
	else:
		# Explicitly seeded even in the fallback. RandomNumberGenerator seeds
		# itself from the system on construction, which would make where a food
		# miracle scatters differ between two runs of the same seeded test.
		rng = RandomNumberGenerator.new()
		rng.seed = 0


## Applies a miracle at a point and reports what it touched.
##
## The return value is the seam Phase 6 and the VFX layer read: ids rather than
## objects, so it serialises and so nothing downstream can quietly hold a
## reference to something the strike just removed.
func apply(miracle: Miracle, at: Vector3) -> Dictionary:
	var spawned: Array[int] = []
	var affected: Array[int] = []
	var removed: Array[int] = []
	var deposited: float = 0.0
	# How many things the miracle genuinely altered, as opposed to reached. Heal and
	# water both touch everything in range and change only what was short of full,
	# so reporting `affected` as the effect would overstate both of them.
	var changed: int = 0
	var handled: bool = true

	if miracle == null or registry == null:
		handled = false
	else:
		match miracle.id:
			&"food":
				spawned = _scatter(&"food_pile", at, miracle.effect_radius, int(miracle.magnitude))
			&"wood":
				var store: WorldObject = _nearest(at, miracle.effect_radius, [&"store"])
				# A storehouse standing in the blast takes the timber straight into
				# the village's stock. Growing a forest on top of the village
				# square instead would be worse than useless.
				if store != null and _deposit_wood(miracle.magnitude, store):
					deposited = miracle.magnitude
					affected.append(store.id)
				else:
					spawned = _scatter(&"tree", at, miracle.effect_radius, int(miracle.magnitude))
			&"water":
				# The ids are what the VFX layer draws. The magnitude is moisture, and
				# the villages are the only things that own any, so the count of fields
				# that were not already soaked has to come back from them.
				for field: WorldObject in _near(at, miracle.effect_radius, [&"wheat_field"]):
					affected.append(field.id)
				changed = _village_change(
					&"water_fields_near", at, miracle.effect_radius, miracle.magnitude
				)
			&"heal":
				# Same shape as water. `affected` includes the creature, so the VFX
				# layer still lights it up, but the count comes from the villages and
				# covers villagers only.
				# ponytail: the creature has no health of its own, so healing it is
				# still only a light show. One `heal()` on the creature's body and a
				# second _village_change-shaped call here when it grows one.
				for hurt: WorldObject in _near(at, miracle.effect_radius, HEAL_TYPES):
					affected.append(hurt.id)
				changed = _village_change(
					&"heal_villagers_near", at, miracle.effect_radius, miracle.magnitude
				)
			&"lightning":
				for victim: WorldObject in _near(at, miracle.effect_radius, []):
					if LIGHTNING_DESTROYS.has(victim.type):
						removed.append(victim.id)
						_remove(victim.id)
					else:
						# Struck, but left standing: something else owns whether it
						# died, and until that system exists the strike only
						# reports what it hit. See LIGHTNING_DESTROYS.
						# ponytail: villagers have health now, so lightning could
						# take it off them — but a strike that kills has to answer
						# for the houses and fields in the same blast, and nothing
						# owns their teardown. Deliberately still report-only.
						affected.append(victim.id)
			_:
				handled = false

	return {
		"id": miracle.id if miracle != null else &"",
		"at": at,
		"handled": handled,
		"spawned": spawned,
		"affected": affected,
		"removed": removed,
		"deposited": deposited,
		"changed": changed,
		"alignment_weight": miracle.alignment_weight if miracle != null else 0.0,
	}


## Places `count` new objects of `type` in a disc around `at`.
##
## The square root on the radius is not decoration: sampling the radius
## uniformly clumps everything into the middle, and a food miracle that drops
## six piles on one spot looks like a bug rather than a blessing.
func _scatter(type: StringName, at: Vector3, radius: float, count: int) -> Array[int]:
	var ids: Array[int] = []
	if count <= 0 or registry == null or not registry.has_method("add"):
		return ids
	for i in count:
		var angle: float = rng.randf() * TAU
		var distance: float = sqrt(rng.randf()) * radius
		# Height comes straight from the cast point. The caller raycasts the
		# ground to find `at`, and re-sampling the island in here would need this
		# class to know about terrain for a difference of centimetres.
		var spot: Vector3 = at + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
		var object: WorldObject = registry.add(type, spot)
		if object != null:
			ids.append(object.id)
	return ids


## Puts timber in the stock of the village that owns `store`. False when no village
## can take it — which is what sends the wood miracle back to growing trees instead.
##
## The owner is matched by record id rather than simply taking the first village
## that has a stock, for the same reason the seam is plural at all: both villages
## register their storehouse with the one registry, so without the match, wood cast
## over the rival's storehouse quietly filled the home village's larder. A village
## that does not answer to storehouse() — a five-line test stub — falls through to
## the first stock that will take it, which is all such a stub ever needed.
func _deposit_wood(amount: float, store: WorldObject) -> bool:
	var owner_stock: Object = null
	var any_stock: Object = null
	for one: Object in villages:
		if one == null:
			continue
		# get() rather than a typed access: the village is duck-typed, and a stub or a
		# village before populate() has no store at all.
		var stock: Object = one.get("store")
		if stock == null or not stock.has_method("add"):
			continue
		if any_stock == null:
			any_stock = stock
		if store != null and one.has_method("storehouse"):
			var record: WorldObject = one.storehouse()
			if record != null and record.id == store.id:
				owner_stock = stock
	var target: Object = owner_stock if owner_stock != null else any_stock
	if target == null:
		return false
	target.add(RESOURCE_WOOD, amount)
	return true


## Asks every village to change something in a disc and reports how much of it
## actually changed, summed. Summed rather than asked of one village because the
## disc is a place, not a faction: a miracle cast between the two settlements
## reaches whatever is in range of it, and each village only ever answers for its
## own people and fields.
##
## Zero when there is no village behind the records — a unit test, or the world
## before populate() — and zero for any village that does not answer to this
## method, which is what keeps the five-line stub villages in the tests working.
## Duck-typed for the reason at the top of this file: naming the village's type
## would make the two modules cyclically dependent.
func _village_change(method: StringName, at: Vector3, radius: float, amount: float) -> int:
	var changed: int = 0
	for one: Object in villages:
		if one == null or not one.has_method(method):
			continue
		changed += int(one.call(method, at, radius, amount))
	return changed


func _near(at: Vector3, radius: float, types: Array) -> Array:
	if registry == null or not registry.has_method("query_near"):
		return []
	return registry.query_near(at, radius, types)


func _nearest(at: Vector3, radius: float, types: Array) -> WorldObject:
	if registry == null or not registry.has_method("nearest"):
		return null
	return registry.nearest(at, radius, types)


func _remove(id: int) -> void:
	if registry != null and registry.has_method("remove"):
		registry.remove(id)
