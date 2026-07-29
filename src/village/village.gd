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
var _storehouse: WorldObject = null
## Buildings paid for and under construction, so two builders do not both raise
## the one house the village was short of and waste the timber.
var _under_construction: Dictionary[StringName, int] = {}
var _indicator: MeshInstance3D = null

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
	_storehouse = _register(
		TYPE_STORE, centre, _box(Vector3(4.0, 3.0, 4.0), Color(0.55, 0.42, 0.28))
	)

	for i in tunables.starting_houses:
		_raise(BUILD_HOUSE, building_site(BUILD_HOUSE))
	for i in tunables.starting_fields:
		_raise(BUILD_FIELD, building_site(BUILD_FIELD))
	for i in tunables.starting_population:
		_spawn(_founder_spot(i), tunables.initial_need_spread)

	_build_indicator()
	_refresh_urgencies()
	_refresh_desire()
	set_physics_process(auto_simulate)


## One step of village life. Needs, movement and work advance for everyone;
## deciding is rationed.
func simulate(delta: float) -> void:
	if store == null or delta <= 0.0:
		return
	_clock += delta

	for villager: Villager in _villagers:
		villager.advance(delta)

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
	var slice: int = mini(maxi(tunables.villagers_per_decision_tick, 1), _villagers.size())
	for i in slice:
		_cursor = (_cursor + 1) % _villagers.size()
		var villager: Villager = _villagers[_cursor]
		if villager.alive and villager.is_idle():
			villager.decide()


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


func _reap() -> void:
	if _pending_deaths.is_empty():
		return
	for villager: Villager in _pending_deaths:
		_villagers.erase(villager)
		deaths_total += 1
		if villager.object != null and _registry != null:
			_registry.remove(villager.object.id)
		if villager.visual != null and is_instance_valid(villager.visual):
			villager.visual.queue_free()
		villager.visual = null
		died.emit(villager)
	_pending_deaths.clear()
	# The cursor indexes an array that just shrank.
	_cursor = 0


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
	villager.visual = _capsule(_job_colour(job))
	villager.visual_lift = _visual_half_height(villager.visual)
	villager.visual.position = spot + Vector3.UP * villager.visual_lift
	add_child(villager.visual)
	_villagers.append(villager)
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
		object = _register(TYPE_HOUSE, at, _box(Vector3(3.0, 2.6, 3.0), Color(0.62, 0.50, 0.36)))
		_houses.append(object)
	else:
		object = _register(TYPE_FIELD, at, _box(Vector3(6.0, 0.2, 6.0), Color(0.78, 0.68, 0.28)))
		_fields.append(object)
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
		# Lifted by half its own height. Box and capsule meshes are centred on
		# their origin, so placing one at ground level buries the lower half and
		# a house reads as a flat slab sunk into the hillside.
		visual.position = at + Vector3.UP * _visual_half_height(visual)
		add_child(visual)
	return object


## Half the height of a primitive mesh, for sitting it on the ground rather than
## through it.
func _visual_half_height(visual: Node3D) -> float:
	var instance := visual as MeshInstance3D
	if instance == null or instance.mesh == null:
		return 0.0
	var box := instance.mesh as BoxMesh
	if box != null:
		return box.size.y * 0.5
	var capsule := instance.mesh as CapsuleMesh
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


func _box(size: Vector3, colour: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(colour)
	return instance


func _capsule(colour: Color) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.3
	mesh.height = 1.6
	mesh.radial_segments = 6
	mesh.rings = 3
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(colour)
	return instance


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
