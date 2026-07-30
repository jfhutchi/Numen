class_name Raider
extends RefCounted
## One raider from the rival village: walks to the target village and hurts
## whoever it finds there.
##
## Deliberately a RefCounted holding its own position, advanced by advance(delta),
## exactly the Villager split: the whole village sim runs twenty minutes in about
## a second because nothing in it needs a physics frame, and a raider that did
## would destroy that. Any scene puppet is a separate concern.
##
## Registered in the world store as `enemy_villager`, a type
## ObjectAttributes.TRUTH already has a row for (friendly 0.05, dangerous 0.60).
## That is the whole of the raider's integration with the creature: its Fear and
## Anger desires already read threat_near through the one existing perception
## seam, and it can already attack. No second perception path is built here.

## Villagers are dead at zero health — villager.gd documents health as
## normalised with 0.0 dead — and the villager's own tunables are the village's
## private business, so the floor is stated here rather than read out of them.
const VILLAGER_HEALTH_DEAD := 0.0

## Registry record for this raider, so the creature perceives it for free.
var object: WorldObject = null
var position: Vector3 = Vector3.ZERO
var alive: bool = true
var health: float = 1.0
## Villagers this raider has killed. The raid director sums it when the raid
## ends to decide whether the raid counted as a loss.
var kills: int = 0
## Damage actually landed. The raid ends by budget rather than by clock: a
## raider that has done its damage withdraws, so an unopposed raid is bounded
## and a repelled one is one whose raiders died before spending it.
var damage_dealt: float = 0.0

var _tunables: RaidTunables
## The village under attack. Typed Object rather than the village's own type:
## village.gd has no class_name, and naming it would couple the two scripts.
## Same trick as Villager._village. Duck-typed against villagers(),
## ground_height() and centre_position().
var _village: Object = null
var _registry: Node = null


func _init(
	tunables: RaidTunables, village: Object, registry: Node, at: Vector3
) -> void:
	_tunables = tunables
	_village = village
	_registry = registry
	position = at
	health = tunables.raider_health


## One step of raiding. Cheap on purpose — a walk or an attack, never both, and
## no decision tick at all: a raider wants exactly one thing.
func advance(delta: float) -> void:
	if not alive or delta <= 0.0:
		return
	if _body_owns_position():
		return
	# Drowning is checked before anything else, so a raider the hand threw into
	# the sea dies of the sea rather than "withdrawing" because the victim scan
	# below happened to come up empty first. Strict less-than: the flat
	# zero-height ground headless tests run on is land.
	if float(_village.ground_height(position.x, position.z)) < _tunables.drown_below:
		_expire()
		return
	if damage_dealt >= _tunables.raider_damage_budget:
		# Satisfied. Withdrawing is simply ceasing to exist — marching the
		# raider back over the horizon is cosmetic, and six thousand headless
		# steps would pay for it.
		_expire()
		return

	var victim: Villager = _nearest_villager()
	if victim == null:
		# Nothing left to raid: the village is empty. Same exit as a spent
		# budget — the raid director judges the raid by kills, not by how its
		# raiders left.
		_expire()
		return
	if position.distance_to(victim.position) <= _tunables.attack_radius:
		_attack(victim, delta)
	else:
		_walk_towards(victim.position, delta)
	if object != null:
		object.position = position


## Lightning, the creature's attack, or anything else that hurts a raider comes
## through here. Death removes the registry record, so the creature's threat
## reading falls the moment the threat does.
func take_damage(amount: float) -> void:
	if not alive or amount <= 0.0 or is_nan(amount):
		return
	health -= amount
	if health <= 0.0:
		_expire()


## Damage on contact. The wound is written straight to the villager's health —
## the same seam the heal miracle reads back — but death is deliberately the
## villager's own path, called by name despite the underscore: _die() ->
## abandon_task() -> report_death() is the village's single way to die, it is
## what releases the dead villager's store reservations, and adding a second
## path here is exactly how the village slowly reserves itself to a standstill.
func _attack(victim: Villager, delta: float) -> void:
	var before: float = victim.health
	victim.health = maxf(
		before - _tunables.damage_per_second * delta, VILLAGER_HEALTH_DEAD
	)
	damage_dealt += before - victim.health
	if victim.health <= VILLAGER_HEALTH_DEAD and victim.alive:
		kills += 1
		victim._die()


## Steering, not pathfinding — the same judgement as Villager._travel(): there
## is nothing on the island worth walking around.
func _walk_towards(goal: Vector3, delta: float) -> void:
	var to_goal: Vector3 = goal - position
	to_goal.y = 0.0
	var distance: float = to_goal.length()
	# Guarded above zero: normalising a zero-length vector is how NaN gets into
	# a position and never leaves.
	if distance <= 0.001:
		return
	var step: float = minf(_tunables.raider_speed * delta, distance)
	position += to_goal / distance * step
	position.y = float(_village.ground_height(position.x, position.z))


## Nearest living villager, or null when the village is empty.
##
## ponytail: linear scan per raider per step over the tens of villagers a
## village holds — the same cost the village's own loops pay. Spatial hash if
## profiling ever says otherwise.
func _nearest_villager() -> Villager:
	var best: Villager = null
	var best_distance: float = INF
	var people: Array = _village.villagers()
	for villager: Villager in people:
		if not villager.alive:
			continue
		var distance: float = villager.position.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = villager
	return best


## The one way a raider leaves the world — killed, drowned, or withdrawn.
## Removes the registry record so perception stops reporting a threat that no
## longer exists; the raid director sweeps the object itself off its list on the
## next simulate().
func _expire() -> void:
	alive = false
	if _registry != null and object != null:
		_registry.remove(object.id)


## True while a physics body — the divine hand's grasp, or the flight after a
## throw — owns this raider's position. Mirrors Villager._sync_record(): the
## hand never takes the body back, so once it has settled the raider reclaims
## its landing spot, frees the body, and the next advance() decides whether that
## spot is the sea.
func _body_owns_position() -> bool:
	if object == null or object.node == null or not is_instance_valid(object.node):
		return false
	var body := object.node as RigidBody3D
	if body == null:
		return false
	position = body.global_position
	if body.freeze:
		return true
	var rest: float = _tunables.hand_settle_speed
	if body.linear_velocity.length_squared() > rest * rest:
		return true
	position.y = float(_village.ground_height(position.x, position.z))
	object.node = null
	object.position = position
	body.queue_free()
	return false
