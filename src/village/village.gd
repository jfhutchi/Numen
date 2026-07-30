extends Node3D
## The village: villagers, buildings, a store, and the tick budget that keeps
## them all off any one frame.
##
## `simulate(delta)` is the entire simulation and `_physics_process` does nothing
## but forward to it. That split is the single most important thing in this
## module: it is why a twenty-minute acceptance run costs about a second of wall
## clock. The behavioural test calls simulate() in a tight loop and never touches
## the frame loop at all.
##
## Everything the village owns is registered in the world store under the types
## the creature already knows — villager, house, store, wheat_field — so the
## creature perceives the village for free through the same seam it perceives
## everything else. There is deliberately no second perception path.
##
## Three of the brief's four buildings are registered; the temple is not. The
## village centre is the storehouse and the temple both: villagers pray at
## centre_position() and record_worship() counts it, so worship works, but the
## creature perceives one `store` where the brief named two kinds. A perceivable
## temple needs its own row in ObjectAttributes.TRUTH, which is the creature
## module's table, and registering a type with no attributes would teach the
## creature that a temple is exactly average at everything. Deferred on purpose
## until the creature has a reason to tell the two apart: one row there, one
## _register() call here.
##
## The village works in world coordinates and expects its own node to sit at the
## origin; it places itself on the island rather than being positioned.
##
## Buildings are drawn with the models tools/blender/generate_meshes.py writes to
## res://assets/procedural/meshes, and the whole population is drawn with one
## MultiMesh. The second of those is a draw-call decision, not a cosmetic one: a
## MeshInstance3D per villager put two hundred of them on the frame before the
## island had been drawn at all.

signal born(villager: Villager)
signal died(villager: Villager)
signal building_raised(kind: StringName, object: WorldObject)

const VILLAGER := preload("res://src/village/villager.gd")
const TUNABLES := preload("res://src/village/village_tunables.gd")
const STORE := preload("res://src/village/village_store.gd")

const RNG_STREAM := &"village"

const TYPE_VILLAGER := &"villager"
const TYPE_HOUSE := &"house"
const TYPE_FIELD := &"wheat_field"
const TYPE_STORE := &"store"
const TYPE_TREE := &"tree"

## What a builder can raise. The village centre is not on the list: it is the
## storehouse and the temple both, placed once by populate(), because a separate
## temple would need a registry type the creature has no attributes for and would
## teach it that a building is exactly average at everything.
const BUILD_HOUSE := &"house"
const BUILD_FIELD := &"field"

## Golden angle. Successive sites land spread around a ring without ever
## colliding, which is the whole of the town planning this village needs.
const GOLDEN_ANGLE := 2.39996323
const SITE_ATTEMPTS := 8
## Fraction of the ring radius given up per failed placement attempt. Pulling a
## site inward always ends on dry land, because the centre is dry by construction.
const SITE_SHRINK := 0.14
## Ground height a building site must clear to count as dry.
const DRY_ENOUGH := 0.4
## Sites per ring before the next ring starts.
const SITES_PER_RING := 6

const INDICATOR_BOB_HZ := 1.6
const INDICATOR_BOB_AMPLITUDE := 0.35

## Where tools/blender/generate_meshes.py leaves its output. Loaded at run time
## rather than preloaded: a checkout without the generated assets still has to run,
## and preload() of a missing file is a parse error rather than a null.
##
## Every model is built with its base at y = 0 and centred in X and Z, so it is
## placed at terrain height with no lift — unlike the primitives it replaces, which
## are centred on their own origin.
const MESH_DIR := "res://assets/procedural/meshes/"
const MODEL_HUT := &"hut"
const MODEL_STOREHOUSE := &"storehouse"
const MODEL_FIELD := &"field"
const MODEL_VILLAGER := &"villager"

## Scale that makes a MultiMesh instance vanish, for the slack between the living
## population and the buffer's capacity. Same trick as src/world/scatter.gd.
const HIDDEN_SCALE := Vector3(0.0001, 0.0001, 0.0001)
## How far a villager must move in one step for its heading to be believed. Below
## this a villager is standing still and keeps the facing it already had, rather
## than spinning to point along a rounding error.
const FACING_MIN_STEP := 0.01

## Authored in sRGB and converted on use: albedo is consumed as linear, and a
## colour handed over raw renders washed out.
const DESIRE_COLOURS: Dictionary = {
	&"food": Color(0.90, 0.75, 0.25),
	&"sleep": Color(0.30, 0.40, 0.85),
	&"worship": Color(0.88, 0.88, 0.98),
	&"procreate": Color(0.90, 0.45, 0.65),
	&"work": Color(0.45, 0.75, 0.40),
}

## Villagers are told apart by their trade at a glance. Farmers fall through to
## the default straw colour.
const JOB_COLOURS: Dictionary = {
	&"forester": Color(0.35, 0.55, 0.32),
	&"builder": Color(0.72, 0.52, 0.26),
	&"breeder": Color(0.78, 0.52, 0.62),
	&"priest": Color(0.86, 0.86, 0.92),
}

@export var tunables: VillageTunables
## When false the village only advances when someone calls simulate(). The
## behavioural test drives it that way so twenty minutes of village life do not
## take twenty minutes.
@export var auto_simulate: bool = true

## Where to look for somewhere to settle. The search still requires dry land all
## round, so an unsuitable origin simply falls back to the island centre — this
## biases the search, it does not force a bad site. Set it to put a second
## village somewhere other than on top of the first.
@export var search_origin: Vector3 = Vector3.ZERO

var store: VillageStore
var centre: Vector3 = Vector3.ZERO
## Acts of worship completed. A village statistic, not a resource: the prayer
## pool that miracles spend belongs to the miracle module and is fed from
## worshipper_count(), so there is only ever one place power is banked.
var worship_total: int = 0
var births_total: int = 0
var deaths_total: int = 0

var _island: Node3D = null
var _registry: Node = null
var _rng := RandomNumberGenerator.new()
var _villagers: Array[Villager] = []
var _houses: Array[WorldObject] = []
var _fields: Array[WorldObject] = []
## Field object id to moisture in [0,1]. Held here rather than on WorldObject
## because moisture is the village's business, not the registry's: the creature
## perceives a wheat field, it has no opinion about how wet one is. Keyed by id
## rather than by the record itself so the entry cannot pin a freed field alive.
var _moisture: Dictionary[int, float] = {}
var _storehouse: WorldObject = null
## Buildings paid for and under construction, so two builders do not both raise
## the one house the village was short of and waste the timber.
var _under_construction: Dictionary[StringName, int] = {}
var _indicator: MeshInstance3D = null
## Generated model scenes, loaded on first use and reused for every instance. A
## missing asset is cached as null so the fallback is decided once, not per hut —
## which is also why this dictionary is untyped: a typed value cannot be the null
## that stands for "looked, not there".
var _models: Dictionary = {}
## The whole population, in one draw batch.
var _villager_mesh: MultiMeshInstance3D = null
## What each villager instance was last drawn with, index-parallel to the
## MultiMesh, which is write-only — see _push_villagers().
var _villager_drawn: Array[Transform3D] = []
## How many instances the last push left standing, so a shrinking population only
## has to hide the ones that actually went away.
var _visible_villagers: int = 0
## Job colours are rewritten only when the roster moved. Every other step the
## villager at an index is the same one, doing the same job.
var _villager_colours_dirty: bool = true
## Lift the villager instances need, which is zero for the model and half a height
## for the capsule the model falls back to.
## The transform villager.glb carries inside itself, composed into every instance
## on the way to the rendering server. See _villager_model_mesh().
var _villager_local: Transform3D = Transform3D.IDENTITY

var _clock: float = 0.0
var _decision_accumulator: float = 0.0
var _desire_accumulator: float = 0.0
## Round-robin position through the population.
var _cursor: int = 0
var _job_cursor: int = 0
var _desire: StringName = &"work"
var _food_urgency: float = 0.0
var _wood_urgency: float = 0.0
var _pending_births: Array[Villager] = []
var _pending_deaths: Array[Villager] = []


func _ready() -> void:
	set_physics_process(auto_simulate)


func _physics_process(delta: float) -> void:
	if store == null:
		return
	simulate(delta)


## Builds the village on the island and registers every part of it.
##
## `island` may be null, in which case the ground is flat at zero — unit tests
## that only care about the economy need not pay for a heightmap.
func populate(island: Node3D, registry: Node, seed_value: int = 0) -> void:
	_island = island
	_registry = registry
	if tunables == null:
		tunables = TUNABLES.new()
	_rng.seed = seed_value if seed_value != 0 else _default_seed()

	store = STORE.new()
	store.add(VillageStore.FOOD, tunables.starting_food)
	store.add(VillageStore.WOOD, tunables.starting_wood)

	centre = _find_centre()
	_storehouse = _register(TYPE_STORE, centre, _centre_visual())
	# Before the founders: every villager wants an instance to be drawn in.
	_build_villager_mesh()

	for i in tunables.starting_houses:
		_raise(BUILD_HOUSE, building_site(BUILD_HOUSE))
	for i in tunables.starting_fields:
		_raise(BUILD_FIELD, building_site(BUILD_FIELD))
	for i in tunables.starting_population:
		_spawn(_founder_spot(i), tunables.initial_need_spread)

	_build_indicator()
	_refresh_urgencies()
	_refresh_desire()
	_push_villagers()
	set_physics_process(auto_simulate)


## One step of village life. Needs, movement and work advance for everyone;
## deciding is rationed.
func simulate(delta: float) -> void:
	if store == null or delta <= 0.0:
		return
	_clock += delta

	for villager: Villager in _villagers:
		villager.advance(delta)
	_dry_fields(delta)

	var interval: float = 1.0 / maxf(tunables.decisions_per_second, 0.001)
	_decision_accumulator += delta
	while _decision_accumulator >= interval:
		_decision_accumulator -= interval
		_decision_tick()

	_reap()
	_deliver_births()

	_desire_accumulator += delta
	if _desire_accumulator >= tunables.desire_refresh_seconds:
		_desire_accumulator = 0.0
		_refresh_desire()
	_bob_indicator()
	_push_villagers()


func population() -> int:
	return _villagers.size()


## What the village as a whole most wants right now, summed over everyone.
func current_desire() -> StringName:
	return _desire


func villagers() -> Array[Villager]:
	return _villagers


func houses() -> Array[WorldObject]:
	return _houses


func fields() -> Array[WorldObject]:
	return _fields


func storehouse() -> WorldObject:
	return _storehouse


## The transform villager instance `index` is drawn with, where instance `index`
## draws `villagers()[index]`.
##
## The authoritative copy, and the only readable one: the MultiMesh is write-only
## because the headless dummy renderer discards instance data and hands identity
## back out of get_instance_transform(). Same rule as src/world/scatter.gd.
func villager_instance_transform(index: int) -> Transform3D:
	if index < 0 or index >= _villager_drawn.size():
		return Transform3D.IDENTITY
	return _villager_drawn[index]


## How many villager instances are drawn. Every instance above this is scaled to
## nothing rather than the buffer being resized — see _build_villager_mesh().
func villager_instances_drawn() -> int:
	return _visible_villagers


func centre_position() -> Vector3:
	return centre


func ground_height(x: float, z: float) -> float:
	if _island == null:
		return 0.0
	return float(_island.height_at(x, z))


## Whether the village can afford another mouth: somewhere to put it, food to
## spare beyond the birth itself, and room under the ceiling.
func can_birth() -> bool:
	if population() >= tunables.max_population:
		return false
	if population() >= _houses.size() * tunables.house_capacity:
		return false
	return store.available(VillageStore.FOOD) >= (
		tunables.birth_food_cost + tunables.birth_food_reserve
	)


## How badly the village needs this job done, in [0,1]. This is what turns a
## private utility function into a village: nobody is told to farm, but an empty
## larder makes farming the most attractive thing a farmer can do.
func work_level_for(job: StringName) -> float:
	var level: float = tunables.work_base_level
	match job:
		Villager.FORESTER:
			level += _wood_urgency
		Villager.BUILDER:
			level += 1.0 if wanted_building() != &"" else tunables.builder_idle_urgency
		Villager.PRIEST:
			level += tunables.priest_work_urgency
		_:
			level += _food_urgency
	# Capped below a full personal need on purpose — see work_max_level.
	return clampf(level, 0.0, tunables.work_max_level)


## Nearest field, or null when the village has none and the farmers must forage.
func nearest_field(from: Vector3) -> WorldObject:
	return _nearest_of(_fields, from)


## How wet one of this village's fields is, in [0,1]. Zero for a field it does not
## own: a `wheat_field` record from somewhere else is not this village's to water.
func field_moisture(field: WorldObject) -> float:
	if field == null:
		return 0.0
	return float(_moisture.get(field.id, 0.0))


## Food one harvest of this field yields.
##
## Moisture scales it between a dry floor and the full figure, which is what makes
## the water miracle worth casting and neglect worth noticing. The floor is
## deliberately generous — see harvest_dry_yield_fraction. A village that can be
## starved to death by a player who never casts water is a worse game than one
## that is merely poorer, and the twenty-minute acceptance run has to survive a
## bone-dry back half without losing anybody.
func harvest_yield(field: WorldObject) -> float:
	return tunables.harvest_food * lerpf(
		tunables.harvest_dry_yield_fraction, 1.0, field_moisture(field)
	)


## Waters one field and reports the moisture actually added, which is zero for a
## field already soaked and zero for one this village does not own.
func water_field(field: WorldObject, amount: float) -> float:
	if field == null or amount <= 0.0 or is_nan(amount) or not _moisture.has(field.id):
		return 0.0
	var before: float = float(_moisture[field.id])
	_moisture[field.id] = clampf(before + amount, 0.0, 1.0)
	return float(_moisture[field.id]) - before


## Waters every field within `radius` of `point` and returns how many actually
## took water. Fields already at full moisture are skipped and not counted, so the
## miracle reports what it changed rather than what it merely reached.
##
## Public and duck-typed against on purpose: this is one of the two seams
## MiracleEffects reaches the village through, and it must not have to import the
## village module to do it.
func water_fields_near(point: Vector3, radius: float, amount: float) -> int:
	var watered: int = 0
	for field: WorldObject in _fields:
		if field.current_position().distance_to(point) > radius:
			continue
		if water_field(field, amount) > 0.0:
			watered += 1
	return watered


## Heals every villager within `radius` of `point` and returns how many actually
## gained health. Villagers already at full health are skipped and not counted:
## casting heal over a hale village honestly reports nothing, rather than claiming
## to have mended eight people who were never hurt.
func heal_villagers_near(point: Vector3, radius: float, amount: float) -> int:
	var healed: int = 0
	for villager: Villager in _villagers:
		if not villager.alive:
			continue
		if villager.position.distance_to(point) > radius:
			continue
		if villager.heal(amount) > 0.0:
			healed += 1
	return healed


func house_position_near(from: Vector3) -> Vector3:
	var house: WorldObject = _nearest_of(_houses, from)
	return house.current_position() if house != null else centre


## Where a forester goes for timber: a registered tree if the world has any,
## otherwise a point on the woodland ring, so a village on a bare test island
## still produces wood instead of stalling.
##
## The tree is not felled. Scenery belongs to the scatter, which the divine hand
## also grabs from, and removing an object out from under a carried prop is a
## crash waiting to happen. Chopping is abstract: the forester goes to the woods
## and comes back with timber.
func tree_point(from: Vector3, rng: RandomNumberGenerator) -> Vector3:
	if _registry != null:
		var tree: WorldObject = _registry.nearest(from, tunables.forest_radius, [TYPE_TREE])
		if tree != null:
			return tree.current_position()
	return _ring_point(tunables.forest_radius, rng)


func forage_point(rng: RandomNumberGenerator) -> Vector3:
	return _ring_point(tunables.field_ring_radius, rng)


## The kind of building the village is short of, or empty when it wants none.
## Fields come first: a village that runs out of food stops growing anyway.
func wanted_building() -> StringName:
	var wanted_fields: int = int(
		ceil(float(population()) / float(maxi(tunables.villagers_per_field, 1)))
	)
	if _fields.size() + _pending(BUILD_FIELD) < wanted_fields:
		return BUILD_FIELD
	if population() >= tunables.max_population:
		return &""
	var capacity: int = (_houses.size() + _pending(BUILD_HOUSE)) * tunables.house_capacity
	if population() >= capacity:
		return BUILD_HOUSE
	return &""


func wood_cost(kind: StringName) -> float:
	return tunables.house_wood_cost if kind == BUILD_HOUSE else tunables.field_wood_cost


## Reserves the timber for a building and counts it as started. Returns the wood
## claim, or 0 when there is not enough — in which case nothing was started.
func begin_building(kind: StringName) -> int:
	var claim: int = store.reserve(VillageStore.WOOD, wood_cost(kind))
	if claim != 0:
		_under_construction[kind] = _pending(kind) + 1
	return claim


func cancel_building(kind: StringName, claim: int) -> void:
	store.release(claim)
	_under_construction[kind] = maxi(_pending(kind) - 1, 0)


func finish_building(kind: StringName, at: Vector3) -> void:
	_under_construction[kind] = maxi(_pending(kind) - 1, 0)
	_raise(kind, Vector3(at.x, ground_height(at.x, at.z), at.z))


func record_worship() -> void:
	worship_total += 1


## Villagers at the temple right now — those acting on the worship need, and the
## priests whose work is tending it. This is what the miracle module's prayer
## pool accrues from.
func worshipper_count() -> int:
	var count: int = 0
	for villager: Villager in _villagers:
		if villager.current_need == Villager.WORSHIP:
			count += 1
		elif villager.job == Villager.PRIEST and villager.current_need == Villager.WORK:
			count += 1
	return count


## Queued rather than spawned on the spot: births happen inside the loop that is
## walking the population, and appending to that array while it is being iterated
## is how a simulation grows a hole in the middle of itself.
func request_birth(parent: Villager) -> void:
	_pending_births.append(parent)


func report_death(villager: Villager) -> void:
	_pending_deaths.append(villager)


## The whole per-frame AI budget: a slice of the population, in round-robin
## order, and only those with nothing to do. Everyone else is already walking or
## working, which costs a float add each and needs no thinking.
func _decision_tick() -> void:
	if _villagers.is_empty():
		return
	_refresh_urgencies()
	var slice: int = mini(_decision_slice(), _villagers.size())
	for i in slice:
		_cursor = (_cursor + 1) % _villagers.size()
		var villager: Villager = _villagers[_cursor]
		if villager.alive and villager.is_idle():
			villager.decide()


## How many villagers may re-decide on one tick: a fraction of the population, with
## the flat count as a floor.
##
## A flat count alone does not scale. Four per tick at five ticks a second comes
## back round to each of twenty-four villagers every 1.2 s, but takes ten seconds
## over two hundred — long enough that a villager which has just finished its meal
## stands in the square doing nothing while the player watches it. The fraction
## holds that interval at 1 / (decisions_per_second * decision_slice_fraction)
## whatever the population, so the cost per villager is flat instead of the cost
## per frame.
##
## Rounded rather than ceiled: 0.2 is not exactly representable, so a ceiling turns
## two hundred into forty-one and — the part that would have mattered — twenty into
## five, quietly moving the slice for villages the flat count was tuned against.
func _decision_slice() -> int:
	return maxi(
		maxi(tunables.villagers_per_decision_tick, 1),
		roundi(float(_villagers.size()) * tunables.decision_slice_fraction)
	)


func _refresh_urgencies() -> void:
	var pop: float = float(maxi(population(), 1))
	_food_urgency = _shortfall(
		store.stock_of(VillageStore.FOOD), tunables.food_target_per_villager * pop
	)
	_wood_urgency = _shortfall(
		store.stock_of(VillageStore.WOOD), tunables.wood_target_per_villager * pop
	)


func _shortfall(have: float, want: float) -> float:
	return clampf(1.0 - have / maxf(want, 0.001), 0.0, 1.0)


## Dominant need: the one with the highest appetite summed over the population.
## Summed rather than counted so a village where everyone is slightly hungry
## still reads as hungry, which is what a player watching the indicator expects.
##
## Scored with exactly the expression Villager.decide() maximises, feasibility
## included. Without the feasibility term the indicator ranks needs by a
## different function than the villagers act on, and it shows: it sat on
## "procreate" for the back half of a run because the need kept rising after the
## population hit its ceiling, while not one villager was able to act on it.
func _refresh_desire() -> void:
	if _villagers.is_empty():
		return
	var best: StringName = _desire
	var best_total: float = -1.0
	for need: StringName in Villager.NEEDS:
		var total: float = 0.0
		for villager: Villager in _villagers:
			total += villager.weighted_level(need) * villager.feasibility_of(need)
		if total > best_total:
			best_total = total
			best = need
	if best != _desire:
		_desire = best
		_tint_indicator()


## Fields dry out. Every step rather than on demand: there is a handful of fields
## against dozens of villagers, so the loop is free next to what advance() already
## costs, and a stored level is one the inspector can read.
##
## Iterated over keys() rather than the dictionary itself: copying half a dozen
## ints per step costs nothing, and it means this loop cannot be broken later by
## anything that grows the field list from inside a step.
func _dry_fields(delta: float) -> void:
	if _moisture.is_empty():
		return
	var loss: float = tunables.field_moisture_decay_per_second * delta
	if loss <= 0.0:
		return
	for id: int in _moisture.keys():
		_moisture[id] = maxf(float(_moisture[id]) - loss, 0.0)


func _reap() -> void:
	if _pending_deaths.is_empty():
		return
	for villager: Villager in _pending_deaths:
		_villagers.erase(villager)
		deaths_total += 1
		if villager.object != null and _registry != null:
			_registry.remove(villager.object.id)
		died.emit(villager)
	_pending_deaths.clear()
	# Erasing shifted every villager after the corpse down one, so the instance at
	# an index now draws somebody else, with somebody else's job.
	_villager_colours_dirty = true
	# The cursor is deliberately left where it stood. _decision_tick() takes it
	# modulo the population before using it, so a shrunken array cannot overrun it,
	# and resetting to zero restarts the round-robin at the top on every death: in a
	# village of two hundred with the occasional funeral, the tail never gets a turn.


func _deliver_births() -> void:
	if _pending_births.is_empty():
		return
	for parent: Villager in _pending_births:
		# The full test, not just the ceiling: two villagers finishing on the same
		# step against one free bed would both be delivered otherwise, and the
		# village would end up housing more people than it has room for.
		if not can_birth():
			break
		var offset := Vector3(_rng.randf_range(-1.5, 1.5), 0.0, _rng.randf_range(-1.5, 1.5))
		# Jittered like the founders: a generation born on the same second and
		# fed on the same second queues at the store as one.
		var child: Villager = _spawn(parent.position + offset, tunables.initial_need_spread)
		births_total += 1
		born.emit(child)
	_pending_births.clear()


func _spawn(at: Vector3, spread: float) -> Villager:
	var spot := Vector3(at.x, ground_height(at.x, at.z), at.z)
	var job: StringName = _next_job()
	var villager: Villager = VILLAGER.new(
		job, spot, tunables, store, self, _rng, tunables.newborn_need_level, spread
	)
	villager.object = _registry.add(TYPE_VILLAGER, spot)
	_villagers.append(villager)
	# No scene node of its own: the next push draws it as an instance of the villager
	# MultiMesh, in the slot its position in this array gives it.
	_villager_colours_dirty = true
	return villager


func _next_job() -> StringName:
	var cycle: Array[StringName] = tunables.job_cycle
	if cycle.is_empty():
		return Villager.FARMER
	var job: StringName = cycle[_job_cursor % cycle.size()]
	_job_cursor += 1
	return job


func _raise(kind: StringName, at: Vector3) -> void:
	var object: WorldObject
	if kind == BUILD_HOUSE:
		var hut: Node3D = _model_visual(
			MODEL_HUT, Vector3(3.0, 2.6, 3.0), Color(0.62, 0.50, 0.36)
		)
		object = _register(TYPE_HOUSE, at, hut)
		_houses.append(object)
	else:
		var crop: Node3D = _model_visual(
			MODEL_FIELD, Vector3(6.0, 0.2, 6.0), Color(0.78, 0.68, 0.28)
		)
		object = _register(TYPE_FIELD, at, crop)
		_fields.append(object)
		_moisture[object.id] = tunables.field_moisture_initial
	building_raised.emit(kind, object)


## Where the next building of this kind goes. Deterministic and query-free: the
## village knows what it has built, so it needs no spatial search to place the
## next one.
func building_site(kind: StringName) -> Vector3:
	var placed: int = (_houses.size() if kind == BUILD_HOUSE else _fields.size()) + _pending(kind)
	var base: float = (
		tunables.house_ring_radius if kind == BUILD_HOUSE else tunables.field_ring_radius
	)
	base += tunables.site_spacing * float(placed / SITES_PER_RING)
	var angle: float = float(placed) * GOLDEN_ANGLE
	if kind == BUILD_FIELD:
		# Half a turn off the houses so fields do not land on the doorstep.
		angle += PI
	for attempt in SITE_ATTEMPTS:
		var radius: float = base * (1.0 - SITE_SHRINK * float(attempt))
		var spot := centre + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		spot.y = ground_height(spot.x, spot.z)
		if spot.y > DRY_ENOUGH or _island == null:
			return spot
	return centre


func _founder_spot(index: int) -> Vector3:
	var angle: float = float(index) * GOLDEN_ANGLE
	var radius: float = tunables.house_ring_radius * 0.5
	var spot := centre + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	spot.y = ground_height(spot.x, spot.z)
	return spot


## A random spot on a ring around the village, pulled inward until it is dry.
## Without the check a forester on a treeless island will happily wade out to
## chop timber on the sea floor.
func _ring_point(radius: float, rng: RandomNumberGenerator) -> Vector3:
	var angle: float = rng.randf_range(0.0, TAU)
	for attempt in SITE_ATTEMPTS:
		var reach: float = radius * (1.0 - SITE_SHRINK * float(attempt))
		var spot := centre + Vector3(cos(angle) * reach, 0.0, sin(angle) * reach)
		spot.y = ground_height(spot.x, spot.z)
		if spot.y > DRY_ENOUGH or _island == null:
			return spot
	return centre


func _pending(kind: StringName) -> int:
	return int(_under_construction.get(kind, 0))


func _nearest_of(objects: Array[WorldObject], from: Vector3) -> WorldObject:
	var best: WorldObject = null
	var best_distance: float = INF
	for object: WorldObject in objects:
		var distance: float = object.current_position().distance_squared_to(from)
		if distance < best_distance:
			best_distance = distance
			best = object
	return best


## Registers a building. Its scene node is deliberately *not* hung on the record:
## buildings never move, and a record that reads its position from a node would
## make the creature's perception depend on the scene being alive.
func _register(type: StringName, at: Vector3, visual: Node3D) -> WorldObject:
	var object: WorldObject = _registry.add(type, at)
	if visual != null:
		# Lifted by half its own height, which is zero for the generated models: a
		# box or a capsule is centred on its own origin, so placing one at ground
		# level buries the lower half and a house reads as a slab sunk into the
		# hillside, whereas the models are modelled standing on y = 0 already.
		visual.position = at + Vector3.UP * _visual_half_height(visual)
		add_child(visual)
	return object


## Half the height of a primitive mesh, for sitting it on the ground rather than
## through it.
func _visual_half_height(visual: Node3D) -> float:
	var instance := visual as MeshInstance3D
	return _mesh_half_height(instance.mesh) if instance != null else 0.0


## Half the height of a primitive mesh. Zero for anything else, which is what makes
## the same placement right for the generated models: they are built with their base
## at y = 0 and want no lift at all.
func _mesh_half_height(mesh: Mesh) -> float:
	var box := mesh as BoxMesh
	if box != null:
		return box.size.y * 0.5
	var capsule := mesh as CapsuleMesh
	if capsule != null:
		return capsule.height * 0.5
	return 0.0


## A dry, gently sloped spot with land all round it for the fields.
func _find_centre() -> Vector3:
	if _island == null:
		return Vector3.ZERO
	var half: float = float(_island.extent) * tunables.centre_search_fraction
	for attempt in 96:
		# Biased around search_origin so a second village can be settled away
		# from the first. Left at Vector3.ZERO this is the original behaviour.
		var x: float = search_origin.x + _rng.randf_range(-half, half)
		var z: float = search_origin.z + _rng.randf_range(-half, half)
		var h: float = ground_height(x, z)
		if h > 2.0 and h < 12.0 and _land_all_round(x, z, tunables.field_ring_radius):
			return Vector3(x, h, z)
	return Vector3(0.0, maxf(ground_height(0.0, 0.0), 0.0), 0.0)


func _land_all_round(x: float, z: float, radius: float) -> bool:
	for i in 8:
		var angle: float = TAU * float(i) / 8.0
		if ground_height(x + cos(angle) * radius, z + sin(angle) * radius) <= DRY_ENOUGH:
			return false
	return true


func _build_indicator() -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.7
	mesh.height = 1.4
	mesh.radial_segments = 10
	mesh.rings = 5

	_indicator = MeshInstance3D.new()
	_indicator.name = "DesireIndicator"
	_indicator.mesh = mesh
	var material := StandardMaterial3D.new()
	material.roughness = 0.4
	# Unshaded so the desire colour reads the same whatever the sun is doing.
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_indicator.material_override = material
	add_child(_indicator)
	_tint_indicator()
	_bob_indicator()


func _tint_indicator() -> void:
	if _indicator == null:
		return
	var material: StandardMaterial3D = _indicator.material_override
	if material == null:
		return
	var colour: Color = DESIRE_COLOURS.get(_desire, Color(0.8, 0.8, 0.8))
	material.albedo_color = colour.srgb_to_linear()


func _bob_indicator() -> void:
	if _indicator == null:
		return
	var bob: float = sin(_clock * INDICATOR_BOB_HZ) * INDICATOR_BOB_AMPLITUDE
	_indicator.position = centre + Vector3.UP * (tunables.indicator_height + bob)


## The village centre's model.
##
## storehouse.glb rather than temple.glb, deliberately. The centre is the storehouse
## and the temple both (see the note at the top of this file), but it is registered
## as `store`, which is the one of the two the creature has attributes for — so the
## building the player sees is the building the creature thinks it is looking at.
## It also leaves temple.glb unclaimed for the perceivable temple this file defers,
## which will want a mesh of its own the day it gets a row in ObjectAttributes.
func _centre_visual() -> Node3D:
	return _model_visual(MODEL_STOREHOUSE, Vector3(4.0, 3.0, 4.0), Color(0.55, 0.42, 0.28))


## A building's visual: the generated model, or the box primitive it replaced when
## the asset is not in the checkout.
func _model_visual(model: StringName, size: Vector3, colour: Color) -> Node3D:
	var scene: PackedScene = _model(model)
	if scene == null:
		return _box(size, colour)
	return scene.instantiate() as Node3D


## A generated model scene, loaded once and reused for every instance, or null when
## the asset is missing.
func _model(model: StringName) -> PackedScene:
	if _models.has(model):
		return _models[model] as PackedScene
	var path: String = MESH_DIR + String(model) + ".glb"
	var scene: PackedScene = null
	if ResourceLoader.exists(path):
		scene = load(path) as PackedScene
	_models[model] = scene
	return scene


## One MultiMesh for the whole population, allocated at the ceiling exactly once.
##
## Instances are never added or removed. Resizing the buffer re-uploads every
## instance in it, and this village has a birth or a death every few seconds, so the
## slack between the living population and the ceiling is scaled to nothing instead
## — the same trick src/world/scatter.gd uses for a prop in the divine hand.
func _build_villager_mesh() -> void:
	var mesh: Mesh = _villager_model_mesh()
	if mesh == null:
		mesh = _capsule_mesh()
	if mesh != null and _model(MODEL_VILLAGER) == null:
		# Capsule fallback: a primitive is centred on its origin, so it needs the
		# same standing-up treatment the model gets from its own node transform.
		_villager_local = Transform3D(Basis.IDENTITY, Vector3.UP * _mesh_half_height(mesh))

	var multimesh := MultiMesh.new()
	# Both of these are refused once instance_count is non-zero, and refused
	# silently: the mesh stays in 2D mode with no colours and nothing says why.
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	# starting_population as well as the ceiling: nothing stops a village being
	# configured to open with more people than it is allowed to grow to.
	multimesh.instance_count = maxi(tunables.max_population, tunables.starting_population)

	_villager_mesh = MultiMeshInstance3D.new()
	_villager_mesh.name = "Villagers"
	_villager_mesh.multimesh = multimesh
	_villager_mesh.material_override = _villager_material()
	add_child(_villager_mesh)

	# Every instance starts hidden. An instance the village never grows into would
	# otherwise be left at identity, which draws a whole ceiling of villagers
	# standing on top of each other at the world origin.
	_villager_drawn.resize(multimesh.instance_count)
	for index in multimesh.instance_count:
		_write_villager(index, _hidden_transform())
	_visible_villagers = 0


## Writes the population into the villager MultiMesh.
##
## The MultiMesh is write-only. Under --headless the dummy renderer discards
## instance data and get_instance_transform() hands identity back, so the drawn
## transforms are kept here in _villager_drawn and read back from there — the same
## rule as src/world/scatter.gd, and the reason a headless test can assert anything
## about where a villager is drawn at all.
##
## Instance `i` draws `_villagers[i]`, so a death shifts the ownership of every
## instance after the corpse — which is what _villager_colours_dirty is for.
func _push_villagers() -> void:
	if _villager_mesh == null:
		return
	var multimesh: MultiMesh = _villager_mesh.multimesh
	if _villagers.size() > multimesh.instance_count:
		_grow_villager_buffer(_villagers.size())
	var count: int = mini(_villagers.size(), multimesh.instance_count)
	for index in count:
		var villager: Villager = _villagers[index]
		if villager.is_hand_held():
			# The divine hand's body carries the visible villager for the whole
			# grasp-and-flight; drawing the crowd instance too put a second copy at
			# wherever the record last was — the player picked someone up and saw
			# them still standing by the hut.
			_write_villager(index, _hidden_transform())
		else:
			_write_villager(index, _villager_transform(index, villager))
		if _villager_colours_dirty:
			# Consumed as linear, like every other colour here.
			multimesh.set_instance_color(index, _job_colour(villager.job).srgb_to_linear())
	# Only the instances that actually went away. Hiding the whole slack every step
	# would cost the ceiling in writes per step however small the village is, and the
	# twenty-minute acceptance run takes six thousand steps.
	for index in range(count, _visible_villagers):
		_write_villager(index, _hidden_transform())
	_visible_villagers = count
	_villager_colours_dirty = false


## Enlarges the instance buffer so a population that outgrew it is still drawn.
##
## The buffer used to be sized once from `tunables.max_population` in populate(),
## and `_push_villagers()` silently clamped to it. That is a quiet lie rather than
## a limitation: tools/perf_probe.gd raises the ceiling *after* the village is
## populated and grows to two hundred, so it would have reported
## `villagers=200 PASS` while drawing twenty-four bodies — the measurement of the
## one open Definition-of-Done line, invalidated by its own subject.
##
## Assigning `instance_count` clears the transform and colour buffers, so every
## slot is rewritten afterwards from `_villager_drawn`, which survives because it
## lives here rather than in the rendering server.
func _grow_villager_buffer(wanted: int) -> void:
	var multimesh: MultiMesh = _villager_mesh.multimesh
	var previous: Array[Transform3D] = _villager_drawn.duplicate()
	# Grown in chunks rather than exactly, so a village adding one villager a
	# minute does not reallocate once a minute.
	var capacity: int = maxi(wanted, multimesh.instance_count * 2)

	multimesh.instance_count = capacity
	_villager_drawn.resize(capacity)
	for index in capacity:
		var transform: Transform3D = (
			previous[index] if index < previous.size() else _hidden_transform()
		)
		_write_villager(index, transform)
	# Colours live in the buffer that was just cleared, so every one is stale.
	_villager_colours_dirty = true


## Where and which way round to draw a villager.
##
## The yaw comes from how far the villager moved since the last push, because that
## is the only record of its heading the village has: a Villager walks by adding to
## its own position and keeps its target to itself. Standing still keeps the facing
## it already had.
##
## ponytail: the previous position is read out of the instance's own slot, and a
## death shifts everyone after the corpse down one — so for the single step after a
## funeral those villagers take their old neighbour's position as their own previous
## one and face the wrong way for a sixtieth of a second. Give each villager a slot
## of its own if that ever becomes something anybody can see.
func _villager_transform(index: int, villager: Villager) -> Transform3D:
	var previous: Transform3D = _villager_drawn[index]
	# Orthonormalised so a slot that was hidden hands back a usable basis rather
	# than the near-zero scale it was parked at.
	var basis: Basis = previous.basis.orthonormalized()
	var step: Vector3 = villager.position - previous.origin
	step.y = 0.0
	if step.length_squared() > FACING_MIN_STEP * FACING_MIN_STEP:
		# atan2(x, z) maps the model's local +Z onto the direction of travel, which
		# is the convention src/creature/body/creature.gd turns its body by.
		basis = Basis(Vector3.UP, atan2(step.x, step.z))
	# The villager's own placement, with no model offset folded in. _write_villager
	# composes that on the way to the rendering server, so `previous.origin` above
	# stays comparable with `villager.position` — baking it in here would skew the
	# facing step by the height of the model.
	return Transform3D(basis, villager.position)


## An instance scaled to nothing, for the slack above the living population.
##
## Parked at the village centre rather than at the world origin: the MultiMesh's
## bounding box spans every instance in it whether it is visible or not, and a
## hidden instance left at the origin stretches that box across the island and
## defeats the culling the MultiMesh was drawn as one batch to get.
func _hidden_transform() -> Transform3D:
	return Transform3D(Basis.IDENTITY.scaled(HIDDEN_SCALE), centre)


## Stores the placement and writes it composed with the model's own internal
## offset. Kept in that order deliberately: `_villager_drawn` is the villager's
## position as the simulation knows it, which is what the facing step and the
## tests compare against, while the rendering server needs the mesh stood up.
func _write_villager(index: int, transform: Transform3D) -> void:
	_villager_drawn[index] = transform
	_villager_mesh.multimesh.set_instance_transform(index, transform * _villager_local)


## The Mesh inside villager.glb, or null when the asset is not in the checkout.
##
## A .glb imports as a PackedScene, so the Mesh a MultiMesh needs is one
## instantiation deep: the file is one joined mesh with a material slot per part,
## which lands as a single MeshInstance3D carrying several surfaces. The instance is
## thrown away at once — the Mesh is a Resource and outlives it.
## Also records the transform the mesh carries INSIDE the .glb, into
## `_villager_local`. That offset is not decoration: generate_meshes.py joins the
## villager's parts into the first one, so the joined mesh data lives in that
## part's local space with the feet at y = -0.475, and the glTF node translation
## is what stands it on the ground. Taking `.mesh` alone loses it and draws every
## villager buried to the thighs — which is exactly what happened, and no test
## noticed because the only vertical assertion checked the lift's *sign*.
##
## src/world/scatter.gd hit the same trap with tree.glb and solved it with
## `_transform_in_scene`; this composes the same way rather than re-deriving it.
func _villager_model_mesh() -> Mesh:
	_villager_local = Transform3D.IDENTITY
	var scene: PackedScene = _model(MODEL_VILLAGER)
	if scene == null:
		return null
	var root: Node = scene.instantiate()
	var instance: MeshInstance3D = _first_mesh_instance(root)
	var mesh: Mesh = null
	if instance != null:
		mesh = instance.mesh
		_villager_local = _transform_in_scene(instance)
	# free() rather than queue_free(): it was never in the tree, and a node left on
	# the queue is a node GUT reports as an orphan.
	root.free()
	return mesh


## A node's transform composed with every ancestor's, up the off-tree scene.
func _transform_in_scene(node: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node3D = node
	while current != null:
		result = current.transform * result
		current = current.get_parent() as Node3D
	return result


func _first_mesh_instance(node: Node) -> MeshInstance3D:
	var instance := node as MeshInstance3D
	if instance != null and instance.mesh != null:
		return instance
	for child: Node in node.get_children():
		var found: MeshInstance3D = _first_mesh_instance(child)
		if found != null:
			return found
	return null


func _first_mesh(node: Node) -> Mesh:
	var instance := node as MeshInstance3D
	if instance != null and instance.mesh != null:
		return instance.mesh
	for child in node.get_children():
		var found: Mesh = _first_mesh(child)
		if found != null:
			return found
	return null


## Material for the villager MultiMesh.
##
## One override across every surface of the model, on purpose. The job colour is
## carried per instance, and a per-instance colour only reaches albedo through a
## material that reads vertex colour — so the model's own materials are given up to
## get it. Villagers read as one job-coloured figure each, exactly as the capsules
## they replaced did, and the colour is what tells a forester from a priest.
func _villager_material() -> StandardMaterial3D:
	var material: StandardMaterial3D = _material(Color.WHITE)
	material.vertex_color_use_as_albedo = true
	return material


func _box(size: Vector3, colour: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(colour)
	return instance


## The villager primitive, kept as the fallback for a checkout without the
## generated models. Unlike them it is centred on its origin, which is what
## _villager_lift is for.
func _capsule_mesh() -> Mesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.3
	mesh.height = 1.6
	mesh.radial_segments = 6
	mesh.rings = 3
	return mesh


func _material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour.srgb_to_linear()
	material.roughness = 0.9
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material


func _job_colour(job: StringName) -> Color:
	var colour: Color = JOB_COLOURS.get(job, Color(0.80, 0.74, 0.58))
	return colour


func _default_seed() -> int:
	if is_inside_tree():
		var rng_service: Node = get_node_or_null(^"/root/Rng")
		if rng_service != null:
			return rng_service.derive_seed(RNG_STREAM)
	# Tests and tool scripts run without the autoload; the village still has to
	# be reproducible.
	return hash("numen:village")
