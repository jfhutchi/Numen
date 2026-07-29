class_name Conversion
extends RefCounted
## Belief spreading from village to village: the last item of the vertical slice.
##
## A village is not converted by one spectacle. Belief accrues from impressive
## acts performed within sight of it and bleeds away between them, so a player
## who casts one miracle and wanders off ends up roughly where they started.
## That is the design, not an accident of the maths: conversion is meant to cost
## sustained attention, which is also the only thing that makes converting a
## second village read as an achievement rather than a formality.
##
## Participates in the save contract (see src/core/save_manager.gd). Only the
## per-village state is serialised; the tunables below are configuration, and a
## save that pinned them would freeze one evening's balance into every old save.

## A village has come over. Carries the id so the HUD can name it.
signal village_converted(village_id: StringName)


## Per-village belief state. Named VillageBelief rather than Village to leave
## the global name free for the village simulation itself.
class VillageBelief:
	extends RefCounted
	var id: StringName = &""
	var centre: Vector3 = Vector3.ZERO
	var population: int = 0
	var belief: float = 0.0
	var converted: bool = false


# --- Tunables ----------------------------------------------------------------
# Plain vars rather than @export: this is a RefCounted with no inspector to
# export into, so the caller sets them in code. Grouped here for the same reason
# MindTunables exists — none of these numbers belongs loose in the logic below.

## Seconds an unattended village takes to lose half its accumulated belief.
## Short enough that neglect is felt within a minute of play, long enough that
## crossing the island to deal with something else does not undo the evening.
var belief_halflife: float = 90.0
## Belief a village of nobody would need. The floor under the population term,
## so a hamlet is not won over by a single loaf of bread.
var threshold_base: float = 6.0
## Extra belief needed per villager, so a large village is proportionally more
## work than a small one.
var threshold_per_head: float = 1.5
## How near an act has to happen to impress a village at all, in metres.
## Roughly a quarter of the island, so miracles have to be aimed.
var act_radius: float = 45.0

var _villages: Dictionary[StringName, VillageBelief] = {}


## Adds a village, or updates one already known. Re-registering is how the
## village simulation reports that a village grew, and a village that grew needs
## proportionally more belief. Accumulated belief is kept — work already done
## still counts.
func register_village(id: StringName, centre: Vector3, population: int) -> void:
	var village: VillageBelief = _villages.get(id)
	if village == null:
		village = VillageBelief.new()
		village.id = id
		_villages[id] = village
	village.centre = centre
	village.population = maxi(population, 0)
	# Checked here as well: a village that shrank may have dropped its threshold
	# below the belief it has already banked.
	_check_conversion(village)


## Credits, or debits, one village directly.
##
## Negative amounts are allowed — that is how cruelty in sight of a village
## costs the player ground. Belief floors at zero rather than going negative, so
## a village cannot bank a grudge that later kindness has to pay off before
## anything visible happens; from the player's side that would look exactly like
## the system being broken.
func add_belief(village_id: StringName, amount: float) -> void:
	var village: VillageBelief = _villages.get(village_id)
	if village == null:
		return
	village.belief = maxf(village.belief + amount, 0.0)
	_check_conversion(village)


## An impressive act somewhere in the world: a miracle cast, or the creature
## doing something worth watching. Every village in range is credited, scaled
## down with distance so the act has to happen where the audience is.
##
## Returns the total credited, for the HUD to report back. That is the belief
## that actually landed, not the belief intended: `add_belief` floors at zero, so
## a cruelty worth -10 in sight of a village holding 1 costs it 1, and reporting
## the -10 would have the HUD claim ground the player never lost.
func record_act(at: Vector3, magnitude: float) -> float:
	var credited: float = 0.0
	for village: VillageBelief in _villages.values():
		var distance: float = village.centre.distance_to(at)
		if distance >= act_radius:
			continue
		var share: float = magnitude * (1.0 - distance / maxf(act_radius, 0.001))
		var before: float = village.belief
		add_belief(village.id, share)
		credited += village.belief - before
	return credited


## Bleeds belief away. Call once per frame with the frame's delta.
##
## Exponential and expressed as a half-life, so the result does not depend on
## how often it is called. The naive `belief -= rate * delta` drifts with frame
## rate, needs its own clamp to stop belief going negative, and makes a village
## that was nearly converted lose the last of it in one long frame.
func advance(delta: float) -> void:
	if delta <= 0.0:
		return
	var retained: float = pow(0.5, delta / maxf(belief_halflife, 0.001))
	for village: VillageBelief in _villages.values():
		village.belief *= retained


func belief_of(village_id: StringName) -> float:
	var village: VillageBelief = _villages.get(village_id)
	return village.belief if village != null else 0.0


## Belief this village needs before it comes over. INF for a village that does
## not exist — returning 0 would read as "already there".
func threshold_for(village_id: StringName) -> float:
	var village: VillageBelief = _villages.get(village_id)
	return _threshold(village) if village != null else INF


## Conversion latches: a village that has come over does not fall away again
## when belief decays. A win condition that flickered on and off would be
## unreadable, and the fiction is that they changed their minds, not that they
## are holding their breath.
func is_converted(village_id: StringName) -> bool:
	var village: VillageBelief = _villages.get(village_id)
	return village.converted if village != null else false


func converted_count() -> int:
	var count: int = 0
	for village: VillageBelief in _villages.values():
		if village.converted:
			count += 1
	return count


## Belief across every village, for the prayer-power and progress readouts.
func total_belief() -> float:
	var total: float = 0.0
	for village: VillageBelief in _villages.values():
		total += village.belief
	return total


func village_count() -> int:
	return _villages.size()


func _threshold(village: VillageBelief) -> float:
	return threshold_base + threshold_per_head * float(village.population)


func _check_conversion(village: VillageBelief) -> void:
	if village.converted or village.belief < _threshold(village):
		return
	village.converted = true
	village_converted.emit(village.id)


func save_id() -> StringName:
	return &"conversion"


func to_dict() -> Dictionary:
	var rows: Array = []
	for village: VillageBelief in _villages.values():
		rows.append({
			"id": String(village.id),
			# Three numbers rather than a Vector3: JSON has no vector type and
			# Godot would otherwise serialise it as the string "(x, y, z)",
			# which parses back as text and silently lands every village at the
			# origin.
			"centre": [village.centre.x, village.centre.y, village.centre.z],
			"population": village.population,
			"belief": village.belief,
			"converted": village.converted,
		})
	return {"villages": rows}


## Restores saved state. Deliberately does not emit `village_converted` for
## villages that were already converted when the game was saved — reloading is
## not converting, and the HUD would announce the same triumph on every load.
func from_dict(data: Dictionary) -> void:
	_villages.clear()
	for row: Dictionary in data.get("villages", []):
		var centre_value: Variant = row.get("centre", [])
		var centre: Array = []
		if typeof(centre_value) == TYPE_ARRAY:
			centre = centre_value
		if centre.size() < 3:
			push_warning("[save] skipping malformed village row: %s" % row)
			continue
		var village := VillageBelief.new()
		village.id = StringName(row.get("id", ""))
		village.centre = Vector3(float(centre[0]), float(centre[1]), float(centre[2]))
		village.population = int(row.get("population", 0))
		village.belief = float(row.get("belief", 0.0))
		village.converted = bool(row.get("converted", false))
		_villages[village.id] = village
