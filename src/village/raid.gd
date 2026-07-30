class_name Raid
extends Node
## The raid director: decides when raids happen, runs them, and holds the one
## win/loss rule the game reads.
##
## This is the pressure the sandbox was missing. Raids come from the unconverted
## rival village and scale with how badly the player is doing at converting it,
## so a player who ignores the rival is punished in villagers' lives and one who
## converts it ends the threat for good — which is what ties the Conversion
## module to a real consequence. Belief arrives as a plain float through
## set_rival_belief() rather than as the Conversion object itself: the director
## needs one number and a flag, and importing the module would couple the two
## for nothing.
##
## simulate(delta) is the entire behaviour and _physics_process only forwards to
## it — the same rule as the village, and for the same reason: the behavioural
## tests drive whole raids through simulate() in a tight loop and never touch
## the frame loop at all.

## A raid has set out. Carries the strength so the HUD can size the warning.
signal raid_began(strength: int)
## Every raider died before the raid could kill anyone worth counting.
signal raid_repelled
## The raid killed villagers and got away with it.
signal raid_succeeded

const RAIDER := preload("res://src/village/raider.gd")
const TUNABLES := preload("res://src/village/raid_tunables.gd")

## The registry type ObjectAttributes.TRUTH already carries a threat row for.
## Registering under it is the whole creature integration: Fear and Anger read
## threat_near through the existing perception seam, free.
const TYPE_RAIDER := &"enemy_villager"
## Golden angle, the same constant the village plans building sites with:
## successive spawn spots spread around the origin without colliding and without
## an RNG — a raid must replay identically between the healed and unhealed
## acceptance runs, so the director owns no randomness at all.
const GOLDEN_ANGLE := 2.39996323

@export var tunables: RaidTunables
## When false the director only advances when someone calls simulate(). The
## behavioural tests drive it that way, in step with the village.
@export var auto_simulate: bool = true

var raids_survived: int = 0
var raids_lost: int = 0

var _registry: Node = null
## The village raids fall on. Duck-typed against villagers(), ground_height()
## and centre_position(), same as Villager._village and for the same reason.
var _target: Object = null
## Where raiders appear: the rival village's centre, in fiction and in wiring.
var _origin: Vector3 = Vector3.ZERO
var _raiders: Array[Raider] = []
## Kills accumulated off raiders as they are swept, so the verdict at raid end
## counts every raider including the ones long dead.
var _kills_this_raid: int = 0
var _timer: float = 0.0
var _rival_belief: float = 0.0
var _rival_converted: bool = false
## World facts outcome() is computed from, fed by the orchestrator. Held as
## plain numbers so the rule below depends on nothing it could go stale against.
var _villages_total: int = 0
var _villages_converted: int = 0
var _faithful_population: int = 0


func _ready() -> void:
	set_physics_process(auto_simulate)


func _physics_process(delta: float) -> void:
	if _registry == null:
		return
	simulate(delta)


## Points the director at the world: the registry raiders are perceived through,
## the village raids fall on, and where raiders appear — which the orchestrator
## sets to the rival village's centre.
func setup(registry: Node, target: Object, origin: Vector3) -> void:
	if tunables == null:
		tunables = TUNABLES.new()
	_registry = registry
	_target = target
	_origin = origin
	_timer = tunables.first_raid_delay
	set_physics_process(auto_simulate)


## The rival's standing, fed each frame from the Conversion module. A converted
## rival raids nobody — conversion, not appeasement, is what ends the threat —
## and belief short of that only softens the raids that still come.
func set_rival_belief(belief: float, converted: bool) -> void:
	_rival_belief = maxf(belief, 0.0)
	_rival_converted = converted


## World facts for outcome(): how many villages exist, how many are converted,
## and how many souls live in villages that believe in the player (the starting
## village believes from the first frame, so zero genuinely means no one left).
func set_world_state(
	villages_total: int, villages_converted: int, faithful_population: int
) -> void:
	_villages_total = villages_total
	_villages_converted = villages_converted
	_faithful_population = faithful_population


## How many raiders the next raid brings: the base band plus a surcharge scaled
## by how badly conversion is going, zero surcharge at belief_for_peace. Public
## so the HUD can size its warning and the tests can print the figures.
func next_strength() -> int:
	var pressure: float = 1.0 - clampf(
		_rival_belief / maxf(tunables.belief_for_peace, 0.001), 0.0, 1.0
	)
	var strength: int = tunables.base_strength + roundi(
		pressure * tunables.strength_per_pressure
	)
	return clampi(strength, 1, tunables.max_strength)


## Launches a raid of `strength` raiders against `target`. One raid at a time,
## deliberately: overlapping raids would share one kill count and one verdict,
## and the player can only be losing one battle legibly.
func begin_raid(target: Object, strength: int) -> void:
	if _registry == null or target == null or strength < 1:
		return
	if not _raiders.is_empty():
		return
	_target = target
	_kills_this_raid = 0
	for i in strength:
		var angle: float = float(i) * GOLDEN_ANGLE
		var spot: Vector3 = _origin + Vector3(
			cos(angle) * tunables.spawn_spread, 0.0, sin(angle) * tunables.spawn_spread
		)
		spot.y = float(target.ground_height(spot.x, spot.z))
		var raider: Raider = RAIDER.new(tunables, target, _registry, spot)
		raider.object = _registry.add(TYPE_RAIDER, spot)
		_raiders.append(raider)
	raid_began.emit(strength)


## One step: run the active raid, or count down to the next one.
func simulate(delta: float) -> void:
	if delta <= 0.0 or tunables == null:
		return
	if _raiders.is_empty():
		_schedule(delta)
		return
	for raider: Raider in _raiders:
		raider.advance(delta)
	# Swept after advancing rather than during: erasing from the array being
	# walked is how a simulation grows a hole in the middle of itself — the same
	# reason the village queues its births and deaths.
	var survivors: Array[Raider] = []
	for raider: Raider in _raiders:
		if raider.alive:
			survivors.append(raider)
		else:
			_kills_this_raid += raider.kills
	_raiders = survivors
	if _raiders.is_empty():
		_end_raid()


## Raiders still in the field. Counts the living rather than the list: a raider
## lightning killed a moment ago is off the registry at once but stays on the
## list until the next sweep, and it is not active in any sense the HUD means.
func active_raiders() -> int:
	var count: int = 0
	for raider: Raider in _raiders:
		if raider.alive:
			count += 1
	return count


## The raiders in the field, for the puppet layer to draw. Authoritative
## positions live on the raiders themselves, same rule as the villagers.
func raiders() -> Array[Raider]:
	return _raiders


## Hurts every living raider within `radius` of `point` and returns how many
## were hit. This is the seam lightning and the creature's attack reach raiders
## through — the mirror of Village.heal_villagers_near(), and duck-typed against
## for the same reason.
func damage_raiders_near(point: Vector3, radius: float, amount: float) -> int:
	var hit: int = 0
	for raider: Raider in _raiders:
		if not raider.alive:
			continue
		if raider.position.distance_to(point) > radius:
			continue
		raider.take_damage(amount)
		hit += 1
	return hit


## The win/loss rule, whole and in one place, computed from the facts
## set_world_state() feeds and decided nowhere else.
##
## Won when every village is converted. Lost when the player's last believing
## village is empty. Lost is checked first, deliberately: a god whose final
## village converted as its last villager died has no believers left, and no
## believers is a loss whatever the map says. Before the orchestrator has
## reported any world at all there is nothing to judge, so the answer is
## playing.
func outcome() -> StringName:
	if _villages_total < 1:
		return &"playing"
	if _faithful_population <= 0:
		return &"lost"
	if _villages_converted >= _villages_total:
		return &"won"
	return &"playing"


func _schedule(delta: float) -> void:
	if _rival_converted or _target == null or _registry == null:
		return
	_timer -= delta
	if _timer <= 0.0:
		begin_raid(_target, next_strength())


## One raid over. Lost when it killed at least deaths_to_lose_raid villagers,
## repelled otherwise — including raiders cut down before they hurt anyone, and
## raiders whose every wound the player healed back. The player's measure is
## people, not damage dealt.
func _end_raid() -> void:
	if _kills_this_raid >= tunables.deaths_to_lose_raid:
		raids_lost += 1
		raid_succeeded.emit()
	else:
		raids_survived += 1
		raid_repelled.emit()
	_kills_this_raid = 0
	_timer = tunables.raid_interval
