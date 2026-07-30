class_name Villager
extends RefCounted
## One villager: needs, a job, and the utility scoring that picks between them.
##
## Every need is scored each time the villager is free to choose, and the highest
## score wins. Not a state machine and not a behaviour tree: a villager that is
## hungry, tired and needed in the fields resolves that by arithmetic, and the
## same three lines produce a farmer, a priest and a breeder given different
## weights (see VillageTunables.job_need_weights).
##
## Deliberately a RefCounted holding its own position rather than a Node3D, for
## the same reason the creature's mind is separate from its body: twenty minutes
## of village life has to run inside a test in about a second, and that is only
## possible if walking costs a vector add rather than a physics frame. The scene
## node beside it is a puppet that shows where the villager already is.

enum Phase {IDLE, TRAVEL, WORK}

## The four needs from the brief, plus work.
##
## Work is not a drive the villager feels for itself — its level comes from what
## the *village* is short of, so a full store quietens the farmers and an empty
## one puts everyone in the fields. It is scored through the same utility
## function as the rest because the alternative is a village of pure self
## interest that stands around an empty store and starves.
const FOOD := &"food"
const SLEEP := &"sleep"
const WORSHIP := &"worship"
const PROCREATE := &"procreate"
const WORK := &"work"
const NEEDS: Array[StringName] = [FOOD, SLEEP, WORSHIP, PROCREATE, WORK]

const FARMER := &"farmer"
const FORESTER := &"forester"
const BUILDER := &"builder"
const BREEDER := &"breeder"
const PRIEST := &"priest"
const JOBS: Array[StringName] = [FARMER, FORESTER, BUILDER, BREEDER, PRIEST]

## Registry record for this villager, so the creature perceives it for free.
var object: WorldObject = null
## Scene puppet, or null when the village is running headless.
var visual: Node3D = null
## How far above its ground position the puppet sits. Primitive meshes are
## centred on their origin, so without this a villager walks buried to the waist.
var visual_lift: float = 0.0

var job: StringName = FARMER
var position: Vector3 = Vector3.ZERO
var alive: bool = true
## Body condition, normalised: 1.0 hale, 0.0 dead. Kept apart from the food need
## on purpose — hunger is what the villager feels and acts on, health is what
## ignoring it costs. Starvation is the only thing that lowers it today, and it is
## the single gate on death, so the heal miracle has something real to save.
var health: float = 1.0
var needs: Dictionary[StringName, float] = {}
## What it last decided to do. Readable state, for the inspector and the tests.
var current_need: StringName = &""
var age_seconds: float = 0.0
## Metres walked. A villager that never moves is a bug, and this is how a test
## catches one without watching it.
var distance_travelled: float = 0.0
var decisions_made: int = 0

var _tunables: VillageTunables
var _store: VillageStore
## The orchestrator. Typed Object rather than the village's own type on purpose:
## naming it would make the two scripts cyclically dependent and neither would
## compile. Same trick as CreatureMind._world.
var _village: Object = null
var _rng: RandomNumberGenerator

var _phase: Phase = Phase.IDLE
var _target: Vector3 = Vector3.ZERO
var _timer: float = 0.0
## Outstanding store claim for the errand in progress, or 0.
var _claim: int = 0
## Building kind this villager reserved wood for, or empty.
var _pending_build: StringName = &""
## The field being harvested, or null when foraging.
var _site: WorldObject = null
var _birth_cooldown: float = 0.0


func _init(
	villager_job: StringName,
	at: Vector3,
	tunables: VillageTunables,
	store: VillageStore,
	village: Object,
	rng: RandomNumberGenerator,
	need_level: float = 0.2,
	need_spread: float = 0.0
) -> void:
	job = villager_job
	position = at
	_tunables = tunables
	_store = store
	_village = village
	_rng = rng
	health = tunables.health_max
	for need: StringName in NEEDS:
		# Jittered so a generation of villagers does not get hungry in lockstep
		# and queue at the store on the same second. Work is left at zero: its
		# level is the village's shortfall, not anything this villager stores.
		needs[need] = 0.0 if need == WORK \
			else clampf(need_level + rng.randf() * need_spread, 0.0, 1.0)


## True when the villager has finished whatever it was doing and is waiting for
## its turn in the round-robin to choose again.
func is_idle() -> bool:
	return _phase == Phase.IDLE


## Advances needs, movement and work. Cheap on purpose: this runs for every
## villager on every step, whereas decide() runs for a handful per tick.
func advance(delta: float) -> void:
	if not alive:
		return
	age_seconds += delta
	_birth_cooldown = maxf(_birth_cooldown - delta, 0.0)
	_drift(delta)
	if not alive:
		return

	match _phase:
		Phase.TRAVEL:
			_travel(delta)
		Phase.WORK:
			_timer -= delta
			if _timer <= 0.0:
				_finish()

	_sync_record()


## Utility scoring. Score every need, act on the winner.
##
## Feasibility is a multiplier rather than a filter so an impossible need scores
## zero and simply loses: a starving villager in a village with no food does not
## stand at the empty store, it goes to the fields, which is the only thing that
## ends the famine.
func decide() -> void:
	if not alive or _phase != Phase.IDLE:
		return
	decisions_made += 1

	var best: StringName = &""
	var best_score: float = 0.0
	for need: StringName in NEEDS:
		var score: float = weighted_level(need) * feasibility_of(need)
		if score > best_score:
			best_score = score
			best = need
	if best == &"":
		return

	current_need = best
	_begin(best)


## How much this villager wants `need`, before feasibility. Public because the
## village sums it across the population to work out its dominant desire.
func weighted_level(need: StringName) -> float:
	return pow(level_of(need), _tunables.need_urgency_exponent) * _weight(need)


func level_of(need: StringName) -> float:
	if need == WORK:
		return clampf(float(_village.work_level_for(job)), 0.0, 1.0)
	return float(needs.get(need, 0.0))


## Mends the villager and reports how much health was actually restored: less than
## `amount` for one already nearly hale, and zero for one at full health or one
## already dead. Callers report this figure rather than the amount they asked for,
## so a miracle cast over a healthy village can honestly say it changed nothing.
##
## Deliberately does not touch hunger. Heal mends the body; it does not fill the
## belly, so a healed villager still has to go and eat or it will be back here.
func heal(amount: float) -> float:
	if not alive or amount <= 0.0 or is_nan(amount):
		return 0.0
	var before: float = health
	health = clampf(health + amount, _tunables.health_min, _tunables.health_max)
	return health - before


## Gives back any outstanding claim. Called when the villager dies mid-errand —
## otherwise its reservation would sit on the store forever and the village would
## slowly reserve itself to a standstill.
func abandon_task() -> void:
	if _pending_build != &"":
		_village.cancel_building(_pending_build, _claim)
		_pending_build = &""
	elif _claim != 0:
		_store.release(_claim)
	_claim = 0
	_site = null
	_phase = Phase.IDLE


func describe() -> String:
	return "%s#%d %s food=%.2f sleep=%.2f health=%.2f" % [
		job, object.id if object != null else -1, current_need,
		needs[FOOD], needs[SLEEP], health,
	]


func _weight(need: StringName) -> float:
	var row: Dictionary = _tunables.job_need_weights.get(job, {})
	return float(row.get(need, _tunables.default_need_weight))


## Whether a need can be acted on at all right now, as a multiplier.
##
## Sleep, worship and work are always possible: there is always ground to sleep
## on, always a village centre to pray at, and always something to gather. That
## is the guarantee that nothing in this village can deadlock — whatever else is
## impossible, some option always scores above zero.
##
## Public alongside weighted_level() because the village multiplies the two to
## rank its indicator. Ranking by weight alone made the indicator read "procreate"
## for the whole back half of a run: the need kept rising after the population hit
## its ceiling even though not one villager could act on it.
func feasibility_of(need: StringName) -> float:
	if need == FOOD:
		return 1.0 if _store.available(VillageStore.FOOD) >= _tunables.meal_food else 0.0
	if need == PROCREATE:
		if _birth_cooldown > 0.0:
			return 0.0
		var allowed: bool = _village.can_birth()
		return 1.0 if allowed else 0.0
	return 1.0


func _drift(delta: float) -> void:
	needs[FOOD] = clampf(needs[FOOD] + _tunables.food_per_second * delta, 0.0, 1.0)
	needs[SLEEP] = clampf(needs[SLEEP] + _tunables.sleep_per_second * delta, 0.0, 1.0)
	needs[WORSHIP] = clampf(needs[WORSHIP] + _tunables.worship_per_second * delta, 0.0, 1.0)
	needs[PROCREATE] = clampf(
		needs[PROCREATE] + _tunables.procreate_per_second * delta, 0.0, 1.0
	)

	if needs[FOOD] >= 1.0:
		# Exactly the rate the old stopwatch implied — a villager at full health that
		# never eats still dies after starve_seconds — but spent out of health rather
		# than counted off a clock, so a heal genuinely buys the villager its time
		# back. Death still goes through _die() and nowhere else: a second exit would
		# skip abandon_task() and leave the villager's claim reserved on the store
		# forever.
		health = maxf(health - delta / maxf(_tunables.starve_seconds, 0.001),
			_tunables.health_min)
		if health <= _tunables.health_min:
			_die()
	else:
		# Convalescence rather than a reset. The old code zeroed its stopwatch the
		# instant a villager ate, so a village lurching from famine to famine took no
		# lasting damage at all; recovering at a rate means the second famine is
		# worse than the first, which is when the player should be reaching for heal.
		health = minf(health + _tunables.health_regen_per_second * delta, _tunables.health_max)


func _die() -> void:
	alive = false
	abandon_task()
	_village.report_death(self)


## Steering, not pathfinding. There is nothing on this island worth walking
## around, and a NavigationAgent3D would drag a navigation map into every test.
func _travel(delta: float) -> void:
	var to_target: Vector3 = _target - position
	to_target.y = 0.0
	var distance: float = to_target.length()
	# Guarded above zero as well as above the arrival radius: normalising a
	# zero-length vector is how NaN gets into a position and never leaves.
	if distance <= maxf(_tunables.arrive_radius, 0.001):
		_phase = Phase.WORK
		return

	var step: float = minf(_tunables.walk_speed * delta, distance)
	position += to_target / distance * step
	position.y = float(_village.ground_height(position.x, position.z))
	distance_travelled += step


func _begin(need: StringName) -> void:
	match need:
		FOOD:
			_claim = _store.reserve(VillageStore.FOOD, _tunables.meal_food)
			if _claim == 0:
				# Someone else took the last of it between scoring and asking.
				# Stay idle and re-score on the next turn rather than walking
				# over to eat food that is no longer there.
				return
			var table: Vector3 = _village.centre_position()
			_travel_to(table, _tunables.meal_seconds)
		SLEEP:
			var bed: Vector3 = _village.house_position_near(position)
			_travel_to(bed, _tunables.sleep_seconds)
		WORSHIP:
			var altar: Vector3 = _village.centre_position()
			_travel_to(altar, _tunables.worship_seconds)
		PROCREATE:
			_claim = _store.reserve(VillageStore.FOOD, _tunables.birth_food_cost)
			if _claim == 0:
				return
			var home: Vector3 = _village.house_position_near(position)
			_travel_to(home, _tunables.procreate_seconds)
		WORK:
			_begin_work()


func _begin_work() -> void:
	match job:
		FORESTER:
			_begin_chopping()
		BUILDER:
			var kind: StringName = _village.wanted_building()
			if kind != &"":
				_claim = _village.begin_building(kind)
				if _claim != 0:
					_pending_build = kind
					var site: Vector3 = _village.building_site(kind)
					_travel_to(site, _tunables.build_seconds)
					return
			# Nothing wanted, or no timber to build it with. Either way the most
			# useful thing a builder can do is go and fetch wood.
			_begin_chopping()
		PRIEST:
			var temple: Vector3 = _village.centre_position()
			_travel_to(temple, _tunables.priest_tend_seconds)
		_:
			# Farmers, breeders, and anything unrecognised, work the fields.
			_site = _village.nearest_field(position)
			if _site != null:
				_travel_to(_site.current_position(), _tunables.harvest_seconds)
			else:
				var patch: Vector3 = _village.forage_point(_rng)
				_travel_to(patch, _tunables.forage_seconds)


func _begin_chopping() -> void:
	var wood: Vector3 = _village.tree_point(position, _rng)
	_travel_to(wood, _tunables.chop_seconds)


func _travel_to(target: Vector3, work_seconds: float) -> void:
	_target = target
	_timer = work_seconds
	_phase = Phase.TRAVEL


func _finish() -> void:
	match current_need:
		FOOD:
			# Committed on arrival, not on decision: the claim held the food while
			# the villager walked, and this is the single point at which stock
			# actually falls.
			_store.commit(_claim)
			_claim = 0
			needs[FOOD] = clampf(needs[FOOD] - _tunables.meal_relief, 0.0, 1.0)
		SLEEP:
			needs[SLEEP] = clampf(needs[SLEEP] - _tunables.sleep_relief, 0.0, 1.0)
		WORSHIP:
			needs[WORSHIP] = clampf(needs[WORSHIP] - _tunables.worship_relief, 0.0, 1.0)
			_village.record_worship()
		PROCREATE:
			_store.commit(_claim)
			_claim = 0
			needs[PROCREATE] = 0.0
			_birth_cooldown = _tunables.birth_cooldown
			_village.request_birth(self)
		WORK:
			_finish_work()
	_phase = Phase.IDLE


func _finish_work() -> void:
	match job:
		FORESTER:
			_store.add(VillageStore.WOOD, _tunables.chop_wood)
		BUILDER:
			if _pending_build != &"":
				_store.commit(_claim)
				_claim = 0
				# Raised on the surveyed site rather than wherever the builder
				# happened to stop walking, which can be a stride short of it and
				# on some other island's shoreline.
				_village.finish_building(_pending_build, _target)
				_pending_build = &""
			else:
				_store.add(VillageStore.WOOD, _tunables.chop_wood)
		PRIEST:
			_village.record_worship()
		_:
			# The field's own yield rather than a flat rate: a dry field pays less,
			# which is the whole of what the water miracle is for. Foraging is
			# unaffected — a hedgerow is nobody's to irrigate.
			_store.add(
				VillageStore.FOOD,
				_village.harvest_yield(_site) if _site != null else _tunables.forage_food
			)
			_site = null


## Keeps the world registry in step with where this villager actually is, so the
## creature's perception sees it move.
##
## The record's position is only written while nothing owns the villager's node.
## The divine hand promotes a physics body and hangs it on the record when it
## picks a villager up; while that is true the body is authoritative and the
## agent follows it, rather than the two fighting over one position.
##
## The hand never takes the body away again, so the handshake back is this
## villager's job: once the body has been let go and has stopped moving, the
## villager takes its landing spot, drops the body and lives on. Without that it
## stays pinned wherever it was put down and starves standing up.
## True while a physics body — the divine hand's grasp, or the flight after a
## throw — owns this villager's position. The crowd batch hides the instance for
## the duration: the body carries the visible villager, and drawing both put a
## second copy at whatever spot the record last held.
func is_hand_held() -> bool:
	return object != null and is_instance_valid(object.node) and object.node is RigidBody3D


func _sync_record() -> void:
	if object != null:
		if object.node != null and is_instance_valid(object.node):
			var body := object.node as RigidBody3D
			if body != null and _settled(body):
				position = body.global_position
				# The body landed on a collider; the villager walks on the
				# heightmap, and the two are not the same surface.
				position.y = float(_village.ground_height(position.x, position.z))
				object.node = null
				object.position = position
				body.queue_free()
			else:
				position = object.current_position()
		else:
			object.position = position
	if visual != null and is_instance_valid(visual):
		visual.position = position + Vector3.UP * visual_lift


## Whether the body the hand hung on this villager has finished moving.
##
## Frozen means the hand still has hold of it — that is what hand.gd sets on grab
## and clears on release. An unfrozen body is still in flight until it slows to a
## crawl, and a body the physics server has put to sleep reports no velocity at
## all, so one test covers both.
func _settled(body: RigidBody3D) -> bool:
	if body.freeze:
		return false
	var rest: float = _tunables.hand_settle_speed
	return body.linear_velocity.length_squared() <= rest * rest
