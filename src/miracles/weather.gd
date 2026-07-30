class_name Weather
extends RefCounted
## Weather: the two miracles that are an area over time rather than an instant.
##
## Rain soaks the fields under it for as long as it lasts, so it reads as
## weather rather than a watering can. A storm tears up what it covers, piece
## by piece, and keeps the villagers under it too frightened to work.
##
## RefCounted rather than a Node on purpose: nothing in here renders, and the
## simulation must stay drivable without the frame loop — whoever owns the sim
## tick calls advance(delta), exactly as Village.simulate is driven, which is
## why a twenty-minute weather test costs a fraction of a second. A Node would
## invite _process and turn every behavioural test into a wall-clock test.
##
## The registry and the villages arrive duck-typed, the same seam and for the
## same reasons as MiracleEffects: the standalone registry the tests build works
## exactly like the live autoload, naming the autoload would break compilation
## anywhere it is absent, and naming the village's type would make the two
## modules cyclically dependent.

const RAIN := &"rain"
const STORM := &"storm"

## What a storm tears up: the same set lightning burns, reused for the same
## ownership argument — scenery and stockpiles that no other system keeps a
## list of. Everything else in the world (villagers, houses, fields, stores,
## the creature) has an owner that would be left holding a dangling record.
const STORM_DESTROYS: Array[StringName] = MiracleEffects.LIGHTNING_DESTROYS

## Tunables. Plain vars rather than @export: RefCounted, constructed in code,
## never seen by the inspector.

## Moisture a rain adds per second to every field it covers. At 0.05 a
## twenty-second rain takes a bone-dry field to fully soaked, which is the
## point: the change arrives over the rain's lifetime, not on the first tick.
var rain_moisture_per_second: float = 0.05
## Chance per second that any one covered tree, rock or food pile is torn up.
## A rate rather than a sweep so the storm dismantles the woodland piece by
## piece for as long as it rages, instead of deleting it like a second
## lightning bolt on its opening tick.
var storm_destroy_per_second: float = 0.15

var registry: Object = null
## Every village whose fields and people this weather may touch — home and
## rival alike, summed for the same reason MiracleEffects sums: the disc is a
## place, not a faction.
var villages: Array = []
var rng: RandomNumberGenerator

## Active weather cells: {kind, at, radius, remaining, duration}. A list rather
## than one slot so casting rain over the second village does not silently
## cancel the storm still raging over the first.
var _events: Array[Dictionary] = []


func _init(
	world_registry: Object = null,
	owning_villages: Variant = null,
	generator: RandomNumberGenerator = null
) -> void:
	registry = world_registry
	# One village or a list of them, normalised here so no caller has to care —
	# the same shape MiracleEffects accepts.
	if owning_villages is Array:
		for one: Variant in owning_villages:
			if one != null:
				villages.append(one)
	elif owning_villages != null:
		villages.append(owning_villages)
	if generator != null:
		rng = generator
	else:
		# Explicitly seeded even in the fallback, or which tree a storm fells
		# would differ between two runs of the same seeded test.
		rng = RandomNumberGenerator.new()
		rng.seed = 0


## Starts a weather cell over a point. Unknown kinds and degenerate areas or
## lifetimes are ignored rather than crashed on: the caster validates casts
## upstream, and weather arriving malformed must not take the sim down with it.
func begin(kind: StringName, at: Vector3, radius: float, seconds: float) -> void:
	if kind != RAIN and kind != STORM:
		return
	if radius <= 0.0 or seconds <= 0.0 or is_nan(radius) or is_nan(seconds):
		return
	_events.append({
		"kind": kind,
		"at": at,
		"radius": radius,
		"remaining": seconds,
		"duration": seconds,
	})


func is_active() -> bool:
	return not _events.is_empty()


## Copies of the active cells, for the VFX layer to draw weather over.
## Mutating a copy changes nothing in here.
func events() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for event: Dictionary in _events:
		out.append(event.duplicate())
	return out


## One tick of every active cell. Returns what this tick actually did:
## {watered: int, frightened: int, removed: Array[int]} — counts of fields that
## took water and villagers sent cowering, and the ids the storm erased, which
## is what the VFX layer draws from.
func advance(delta: float) -> Dictionary:
	var removed: Array[int] = []
	var summary: Dictionary = {"watered": 0, "frightened": 0, "removed": removed}
	if delta <= 0.0 or is_nan(delta) or _events.is_empty():
		return summary

	var survivors: Array[Dictionary] = []
	for event: Dictionary in _events:
		# Clamped to the remaining life, so the final tick delivers exactly the
		# moisture the cell had left rather than a whole step of it — a rain's
		# total delivery is rate x lifetime regardless of the caller's step size.
		var step: float = minf(delta, float(event["remaining"]))
		match event["kind"]:
			RAIN:
				summary["watered"] = int(summary["watered"]) + _rain(
					event["at"], float(event["radius"]), step
				)
			STORM:
				_storm(event["at"], float(event["radius"]), step, removed)
				summary["frightened"] = int(summary["frightened"]) + _frighten(
					event["at"], float(event["radius"])
				)
		event["remaining"] = float(event["remaining"]) - step
		if float(event["remaining"]) > 0.0:
			survivors.append(event)
	_events = survivors
	return summary


## Asks every village to water what it owns in the disc, and reports how many
## fields actually took water this tick.
func _rain(at: Vector3, radius: float, step: float) -> int:
	var amount: float = rain_moisture_per_second * step
	if amount <= 0.0:
		return 0
	var watered: int = 0
	for village: Object in villages:
		if village != null and village.has_method("water_fields_near"):
			watered += int(village.call("water_fields_near", at, radius, amount))
	return watered


## Tears up destructible scenery in the disc, at a rate.
func _storm(at: Vector3, radius: float, step: float, removed: Array[int]) -> void:
	if registry == null or not registry.has_method("query_near"):
		return
	if not registry.has_method("remove"):
		return
	var chance: float = clampf(storm_destroy_per_second * step, 0.0, 1.0)
	for victim: WorldObject in registry.query_near(at, radius, STORM_DESTROYS):
		if rng.randf() < chance:
			removed.append(victim.id)
			registry.remove(victim.id)


## Everyone under the storm drops what they are doing, every tick, so a
## villager inside it stands cowering rather than working until it passes.
## abandon_task is the same release the death path uses, which matters: a
## dropped errand gives its store claim back instead of leaking the reservation.
##
## Deliberately no health damage. Villager.heal refuses negative amounts and
## the one death path belongs to the village's starvation drift; a storm that
## killed would need the village to own a hurt seam first — same reasoning as
## lightning being report-only against the living in MiracleEffects.
func _frighten(at: Vector3, radius: float) -> int:
	var frightened: int = 0
	for village: Object in villages:
		if village == null or not village.has_method("villagers"):
			continue
		for person: Object in village.call("villagers"):
			if person == null or not person.has_method("abandon_task"):
				continue
			if not bool(person.get("alive")):
				continue
			var spot: Vector3 = person.get("position")
			if spot.distance_to(at) > radius:
				continue
			person.call("abandon_task")
			frightened += 1
	return frightened
