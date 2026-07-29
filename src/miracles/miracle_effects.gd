class_name MiracleEffects
extends RefCounted
## The world half of a miracle: what actually happens when one lands.
##
## Split from MiracleCaster so the caster — the rules about cost and reach — can
## be tested with no world at all. Wire the two together with two lines:
##
##     var effects := MiracleEffects.new(get_node_or_null(^"/root/World"), rng, village)
##     caster.bind_effects(effects)
##
## Use bind_effects rather than assigning caster.effect_handler directly: a
## Callable does not keep a RefCounted alive on its own.
##
## Both the registry and the village arrive as constructor parameters and are only
## ever duck-typed, so the standalone `object_registry.gd` instance the tests build
## works exactly like the live autoload, and a five-line stub works like the real
## village. Never name the autoload directly in here: GDScript resolves `World` at
## compile time and the script then fails to compile anywhere the autoload is
## absent, test runs included. The village is held as a bare Object for a
## different reason — the same one Villager holds its village that way: naming the
## type would make the two modules cyclically dependent and neither would compile.
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
## The village, or null when there is none — a unit test, or the world before
## populate(). Every use of it degrades to "do the registry-only thing".
var village: Object = null
var rng: RandomNumberGenerator


func _init(
	world_registry: Object = null,
	generator: RandomNumberGenerator = null,
	owning_village: Object = null
) -> void:
	registry = world_registry
	village = owning_village
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
				if store != null and _deposit_wood(miracle.magnitude):
					deposited = miracle.magnitude
					affected.append(store.id)
				else:
					spawned = _scatter(&"tree", at, miracle.effect_radius, int(miracle.magnitude))
			&"water":
				# ponytail: reports the fields it reached and changes nothing else.
				# The village has no moisture or per-field yield to write into —
				# harvest_food is a flat number — so there is no honest place to
				# put the water yet. The ids are what the VFX layer draws from
				# meanwhile; wire the magnitude to the field when fields grow one.
				for field: WorldObject in _near(at, miracle.effect_radius, [&"wheat_field"]):
					affected.append(field.id)
			&"heal":
				# ponytail: same as water. Villager has needs and `alive` but no
				# health, and the creature has no body script yet, so there is
				# nothing to mend. Reported, not applied, until one of them does.
				for hurt: WorldObject in _near(at, miracle.effect_radius, HEAL_TYPES):
					affected.append(hurt.id)
			&"lightning":
				for victim: WorldObject in _near(at, miracle.effect_radius, []):
					if LIGHTNING_DESTROYS.has(victim.type):
						removed.append(victim.id)
						_remove(victim.id)
					else:
						# Struck, but left standing: something else owns whether it
						# died, and until that system exists the strike only
						# reports what it hit. See LIGHTNING_DESTROYS.
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


## Puts timber in the village's stock. False when there is no village to take it
## — which is what sends the wood miracle back to growing trees instead.
func _deposit_wood(amount: float) -> bool:
	if village == null:
		return false
	# get() rather than a typed access: the village is duck-typed, and a stub or a
	# village before populate() has no store at all.
	var stock: Object = village.get("store")
	if stock == null or not stock.has_method("add"):
		return false
	stock.add(RESOURCE_WOOD, amount)
	return true


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
