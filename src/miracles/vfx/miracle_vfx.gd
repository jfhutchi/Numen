class_name MiracleVfx
extends Node3D
## The visual of a miracle being cast — the signature action of the genre, which
## until now had no visual at all.
##
## Built by `for_miracle`, played with `play_at`, and then gone on its own.
## Lifetime discipline is the whole job: every emitter is one_shot, the node
## frees itself when they all report `finished`, and a belt-and-braces Timer
## frees it even when `finished` never comes — an emitter that emitted nothing
## never fires it, and the headless dummy renderer may not simulate particles at
## all. A cast per second for ten minutes must not accumulate nodes.
##
## Everything uses plain ParticleProcessMaterial features (gravity, initial
## velocity, accelerations, emission shapes, colour ramps) because the game also
## ships under the Compatibility renderer, where attractors, collision and
## sub_emitters do not exist.
##
## Meshes come from tools/blender/generate_vfx.py; a checkout without them falls
## back to a QuadMesh. Every emitter carries a code-built material either way
## (material_override), because a particle colour ramp only reaches albedo when
## the material sets vertex_color_use_as_albedo, which imported glTF materials
## do not — without the override the fade-out ramp would silently do nothing and
## every particle would pop out of existence at full opacity.

const MESH_DIR := "res://assets/procedural/meshes/"

## Side of the QuadMesh drawn when a vfx_*.glb is absent, in metres.
const FALLBACK_QUAD_SIZE := 0.15

## Margin over the estimated completion time for the failsafe Timer.
const FAILSAFE_FACTOR := 1.5
## The failsafe never waits less than this, so a heavily scaled-down test run
## still spans a few frames of particle spin-up.
const MIN_FAILSAFE_SECONDS := 0.1

## Emissive energy above Environment.glow_hdr_threshold (1.05), so the glow
## pipeline blooms it. Deliberate: the environment glow exists for these.
const GLOW_ENERGY := 2.4
## The bolt flashes far past the threshold and fades down through it.
const BOLT_FLASH_ENERGY := 8.0

## World gravity for falling particles. Matches feel, not physics config —
## particles are not physics objects and read better slightly floaty.
const GRAVITY := 9.8

# Colours, authored in sRGB; every consumer below runs them through
# srgb_to_linear because material properties set from code are consumed linear.
const COLOUR_GRAIN := Color(0.86, 0.68, 0.26)
const COLOUR_FOOD_GLOW := Color(0.72, 0.85, 0.38)
const COLOUR_LEAF := Color(0.30, 0.55, 0.22)
const COLOUR_DUST := Color(0.55, 0.48, 0.38)
const COLOUR_DROPLET := Color(0.45, 0.65, 0.95)
const COLOUR_CLOUD := Color(0.85, 0.88, 0.92)
const COLOUR_MOTE := Color(1.0, 0.85, 0.45)
const COLOUR_BOLT := Color(1.0, 0.98, 0.88)
const COLOUR_SCORCH := Color(0.18, 0.16, 0.14)
const COLOUR_SHIMMER := Color(0.88, 0.90, 1.0)

# food: grain kernels fountain up and rain back down; a soft green-gold glow
# burst swells over the effect area.
const FOOD_GRAIN_COUNT := 64
const FOOD_GRAIN_LIFETIME := 1.3
const FOOD_GRAIN_SPEED_MIN := 5.0
const FOOD_GRAIN_SPEED_MAX := 8.5
const FOOD_GLOW_COUNT := 14
const FOOD_GLOW_LIFETIME := 0.7

# wood: leaves tumble outward while a ring of dust puffs kicks up at the ground.
const WOOD_LEAF_COUNT := 40
const WOOD_LEAF_LIFETIME := 1.5
const WOOD_LEAF_SPEED_MIN := 2.5
const WOOD_LEAF_SPEED_MAX := 5.5
const WOOD_DUST_COUNT := 20
const WOOD_DUST_LIFETIME := 0.9

# water: a rain column falling from a puff-cloud disc. Longest lifetime of the
# five on purpose — rain that stops instantly reads as a glitch, not weather.
const WATER_CLOUD_HEIGHT := 6.0
const WATER_RAIN_COUNT := 180
const WATER_RAIN_LIFETIME := 1.1
const WATER_RAIN_SPEED_MIN := 6.0
const WATER_RAIN_SPEED_MAX := 9.0
const WATER_CLOUD_COUNT := 24
const WATER_CLOUD_LIFETIME := 2.4

# heal: motes spiral upward — upward velocity plus tangential acceleration.
const HEAL_MOTE_COUNT := 36
const HEAL_MOTE_LIFETIME := 1.5
const HEAL_RISE_MIN := 1.2
const HEAL_RISE_MAX := 2.2
const HEAL_SPIRAL_ACCEL_MIN := 5.0
const HEAL_SPIRAL_ACCEL_MAX := 7.0

# lightning: a stacked jagged bolt, a flash sphere, a scorch ring of dark puffs.
const BOLT_SEGMENTS_MIN := 4
const BOLT_SEGMENTS_MAX := 7
## Authored height of vfx_bolt_segment.glb (base at y=0), which the stacking
## cursor climbs by. A mismatch gaps or overlaps the bolt.
const BOLT_SEGMENT_LENGTH := 0.8
const BOLT_SEGMENT_SCALE := 1.6
## Lateral drift per segment, in metres — what makes the bolt zigzag.
const BOLT_JITTER := 0.45
const BOLT_FADE_SECONDS := 0.4
const FLASH_SECONDS := 0.2
const FLASH_MAX_SCALE := 6.0
const SCORCH_COUNT := 24
## Must stay >= BOLT_FADE_SECONDS: the node frees itself when its emitters
## finish, and the scorch emitter is what holds the node alive through the fade.
const SCORCH_LIFETIME := 0.9
const SCORCH_EXPAND_ACCEL_MIN := 18.0
const SCORCH_EXPAND_ACCEL_MAX := 26.0

# The generic effect for a miracle this file has never heard of. A sixth
# miracle gets a shimmer, not a crash and not silence.
const GENERIC_COUNT := 24
const GENERIC_LIFETIME := 1.2

## Multiplies every lifetime and animation duration. Tests turn it far down so
## the self-free can be awaited in milliseconds rather than seconds.
@export var lifetime_scale: float = 1.0

## Seed for the bolt's shape. 0 means pick a fresh one per cast, which is what
## the game wants; tests set it so the same seed provably builds the same bolt.
@export var bolt_seed: int = 0

## Which miracle this effect dresses. Set by for_miracle.
var miracle_id: StringName = &""

## Reach of the miracle, read from MiracleLibrary in for_miracle so the visual
## and the rules cannot disagree about how far the effect spreads.
var effect_radius: float = 6.0

var _built: bool = false
var _emitters: Array[GPUParticles3D] = []
var _finished_count: int = 0
var _bolt_transforms: Array[Transform3D] = []
var _bolt_material: StandardMaterial3D = null
var _flash: MeshInstance3D = null
var _flash_material: StandardMaterial3D = null


## The one entry point the game calls. Never returns null: an id the table does
## not know gets the generic shimmer, so a sixth miracle cannot silently have no
## visual.
static func for_miracle(id: StringName) -> MiracleVfx:
	var vfx := MiracleVfx.new()
	vfx.name = "MiracleVfx_%s" % id
	vfx.miracle_id = id
	# Constructing a library per effect is fine — its own doc says constructing
	# five Resources is free — and it keeps the radius from being a second copy
	# of a number that already lives in the miracle table.
	var miracle: Miracle = MiracleLibrary.new().by_id(id)
	if miracle != null:
		vfx.effect_radius = miracle.effect_radius
	return vfx


## Constructs the emitters and meshes. Split from for_miracle so a test can
## turn lifetime_scale down first; play_at calls it if nobody else has.
func build() -> void:
	if _built:
		return
	_built = true
	match miracle_id:
		&"food":
			_build_food()
		&"wood":
			_build_wood()
		&"water":
			_build_water()
		&"heal":
			_build_heal()
		&"lightning":
			_build_lightning()
		_:
			_build_generic()


## Adds itself under `parent` at `at`, fires everything, and frees itself when
## done. One shot per instance; a second cast makes a second instance.
func play_at(parent: Node3D, at: Vector3) -> void:
	build()
	parent.add_child(self)
	# In-tree is a requirement, not a preference: the failsafe Timer cannot start
	# off-tree, tweens cannot run, and `finished` never fires — so an off-tree
	# play_at could never free itself, defeating the class's whole contract.
	assert(is_inside_tree(), "play_at needs a parent inside the scene tree")
	global_position = at
	for emitter: GPUParticles3D in _emitters:
		emitter.emitting = true
	if _bolt_material != null:
		_animate_bolt()
	_start_failsafe()


## The emitters, for tests to assert one_shot on. Do not mutate.
func emitters() -> Array[GPUParticles3D]:
	return _emitters


func bolt_segment_count() -> int:
	return _bolt_transforms.size()


## The transform of every bolt segment, in build order — the determinism
## contract a test can hold two same-seeded bolts to.
func bolt_transforms() -> Array[Transform3D]:
	return _bolt_transforms


## Seconds after which the failsafe frees the node regardless of signals.
func failsafe_seconds() -> float:
	var longest: float = 0.0
	for emitter: GPUParticles3D in _emitters:
		# An emitter with explosiveness e spreads its spawns over roughly
		# lifetime * (1 - e), so its last particle dies near lifetime * (2 - e).
		# Sizing the failsafe off bare lifetime cut the rain column short in a
		# live run — the timer fired before `finished` was due.
		longest = maxf(longest, emitter.lifetime * (2.0 - emitter.explosiveness))
	return maxf(longest * FAILSAFE_FACTOR, MIN_FAILSAFE_SECONDS)


# --- the five looks (and the stranger) ----------------------------------------

func _build_food() -> void:
	var grains: ParticleProcessMaterial = _flow(
		Vector3.UP, 30.0, FOOD_GRAIN_SPEED_MIN, FOOD_GRAIN_SPEED_MAX,
		Vector3(0.0, -GRAVITY, 0.0), COLOUR_GRAIN
	)
	grains.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	grains.emission_sphere_radius = effect_radius * 0.15
	# Rotation is ignored without this flag on mesh particles; without it the
	# tumble the angular velocity asks for silently never happens.
	grains.particle_flag_rotate_y = true
	grains.angular_velocity_min = -180.0
	grains.angular_velocity_max = 180.0
	_make_emitter("Grains", &"grain", FOOD_GRAIN_COUNT, FOOD_GRAIN_LIFETIME, 0.85,
		grains, _particle_material(COLOUR_GRAIN, 0.0))

	var glow: ParticleProcessMaterial = _flow(
		Vector3.UP, 60.0, 0.4, 1.0, Vector3.ZERO, COLOUR_FOOD_GLOW
	)
	glow.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	glow.emission_sphere_radius = effect_radius * 0.4
	glow.scale_min = 2.0
	glow.scale_max = 3.5
	_make_emitter("GlowBurst", &"puff", FOOD_GLOW_COUNT, FOOD_GLOW_LIFETIME, 1.0,
		glow, _particle_material(COLOUR_FOOD_GLOW, GLOW_ENERGY))


func _build_wood() -> void:
	var leaves: ParticleProcessMaterial = _flow(
		Vector3.UP, 70.0, WOOD_LEAF_SPEED_MIN, WOOD_LEAF_SPEED_MAX,
		# A fraction of gravity: leaves fall like leaves, not like grains.
		Vector3(0.0, -GRAVITY * 0.35, 0.0), COLOUR_LEAF
	)
	leaves.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	leaves.emission_sphere_radius = effect_radius * 0.2
	leaves.particle_flag_rotate_y = true
	leaves.angular_velocity_min = -360.0
	leaves.angular_velocity_max = 360.0
	_make_emitter("Leaves", &"leaf", WOOD_LEAF_COUNT, WOOD_LEAF_LIFETIME, 0.9,
		leaves, _particle_material(COLOUR_LEAF, 0.0))

	var dust: ParticleProcessMaterial = _flow(
		Vector3.UP, 80.0, 0.3, 0.8, Vector3.ZERO, COLOUR_DUST
	)
	dust.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	dust.emission_ring_axis = Vector3.UP
	dust.emission_ring_radius = effect_radius * 0.6
	dust.emission_ring_inner_radius = effect_radius * 0.5
	dust.emission_ring_height = 0.2
	# radial_accel rather than directed velocity: it pushes away from the origin
	# whatever side of the ring a puff spawned on, and it works on both renderers.
	dust.radial_accel_min = 2.0
	dust.radial_accel_max = 4.0
	dust.scale_min = 1.5
	dust.scale_max = 2.5
	_make_emitter("DustRing", &"puff", WOOD_DUST_COUNT, WOOD_DUST_LIFETIME, 1.0,
		dust, _particle_material(COLOUR_DUST, 0.0))


func _build_water() -> void:
	var rain: ParticleProcessMaterial = _flow(
		Vector3.DOWN, 4.0, WATER_RAIN_SPEED_MIN, WATER_RAIN_SPEED_MAX,
		Vector3(0.0, -GRAVITY, 0.0), COLOUR_DROPLET
	)
	rain.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	rain.emission_box_extents = Vector3(effect_radius * 0.5, 0.2, effect_radius * 0.5)
	# Explosiveness 0: rain is a stream, not a burst. Its spawn window plus fall
	# time is what failsafe_seconds() budgets for.
	var rain_emitter: GPUParticles3D = _make_emitter(
		"Rain", &"droplet", WATER_RAIN_COUNT, WATER_RAIN_LIFETIME, 0.0,
		rain, _particle_material(COLOUR_DROPLET, 0.0)
	)
	rain_emitter.position = Vector3.UP * WATER_CLOUD_HEIGHT

	var cloud: ParticleProcessMaterial = _flow(
		Vector3.UP, 180.0, 0.1, 0.3, Vector3.ZERO, COLOUR_CLOUD
	)
	cloud.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	cloud.emission_box_extents = Vector3(effect_radius * 0.5, 0.3, effect_radius * 0.5)
	cloud.scale_min = 2.5
	cloud.scale_max = 4.0
	var cloud_emitter: GPUParticles3D = _make_emitter(
		"Cloud", &"puff", WATER_CLOUD_COUNT, WATER_CLOUD_LIFETIME, 0.9,
		cloud, _particle_material(COLOUR_CLOUD, 0.0)
	)
	cloud_emitter.position = Vector3.UP * WATER_CLOUD_HEIGHT


func _build_heal() -> void:
	var motes: ParticleProcessMaterial = _flow(
		Vector3.UP, 20.0, HEAL_RISE_MIN, HEAL_RISE_MAX, Vector3.ZERO, COLOUR_MOTE
	)
	motes.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	motes.emission_sphere_radius = effect_radius * 0.45
	# Tangential acceleration curls the straight rise into a spiral. Attractors
	# would do it prettier and do not exist under Compatibility.
	motes.tangential_accel_min = HEAL_SPIRAL_ACCEL_MIN
	motes.tangential_accel_max = HEAL_SPIRAL_ACCEL_MAX
	_make_emitter("Motes", &"mote", HEAL_MOTE_COUNT, HEAL_MOTE_LIFETIME, 0.7,
		motes, _particle_material(COLOUR_MOTE, GLOW_ENERGY))


func _build_lightning() -> void:
	var rng := RandomNumberGenerator.new()
	if bolt_seed == 0:
		rng.randomize()
	else:
		rng.seed = bolt_seed

	# The bolt itself: stacked segments, not particles, because a bolt is one
	# connected jagged line and particles cannot connect to each other.
	# NOT unshaded: unshaded materials output albedo only and EMISSION is
	# discarded, so the 8.0-energy flash never rendered, never crossed the glow
	# threshold, and the fade tween animated a property with no visual effect.
	_bolt_material = _particle_material(COLOUR_BOLT, BOLT_FLASH_ENERGY)
	var bolt := Node3D.new()
	bolt.name = "Bolt"
	add_child(bolt)
	var segment_mesh: Mesh = _particle_mesh(&"bolt_segment")
	var count: int = rng.randi_range(BOLT_SEGMENTS_MIN, BOLT_SEGMENTS_MAX)
	var cursor: Vector3 = Vector3.ZERO
	for i in count:
		var segment := MeshInstance3D.new()
		segment.name = "Segment_%d" % i
		segment.mesh = segment_mesh
		segment.material_override = _bolt_material
		segment.transform = Transform3D(
			Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(
				Vector3.ONE * BOLT_SEGMENT_SCALE
			),
			cursor
		)
		bolt.add_child(segment)
		_bolt_transforms.append(segment.transform)
		cursor += Vector3(
			rng.randf_range(-BOLT_JITTER, BOLT_JITTER),
			BOLT_SEGMENT_LENGTH * BOLT_SEGMENT_SCALE,
			rng.randf_range(-BOLT_JITTER, BOLT_JITTER)
		)

	# The strike flash: a sphere that scales up and alpha-fades in ~0.2 s.
	# Shaded for the same reason as the bolt: emission must actually render.
	_flash_material = _particle_material(COLOUR_BOLT, BOLT_FLASH_ENERGY)
	_flash = MeshInstance3D.new()
	_flash.name = "Flash"
	var flash_mesh := SphereMesh.new()
	flash_mesh.radius = 0.5
	flash_mesh.height = 1.0
	flash_mesh.radial_segments = 12
	flash_mesh.rings = 6
	_flash.mesh = flash_mesh
	_flash.material_override = _flash_material
	_flash.scale = Vector3.ONE * 0.1
	_flash.position = Vector3.UP * 0.5
	add_child(_flash)

	# The scorch: dark puffs expanding out along the ground. Also the emitter
	# whose lifetime keeps the node alive through the bolt fade (SCORCH_LIFETIME
	# >= BOLT_FADE_SECONDS is load-bearing).
	var scorch: ParticleProcessMaterial = _flow(
		Vector3.UP, 40.0, 0.5, 1.5, Vector3.ZERO, COLOUR_SCORCH
	)
	scorch.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	scorch.emission_ring_axis = Vector3.UP
	scorch.emission_ring_radius = 0.6
	scorch.emission_ring_inner_radius = 0.3
	scorch.emission_ring_height = 0.1
	scorch.radial_accel_min = SCORCH_EXPAND_ACCEL_MIN
	scorch.radial_accel_max = SCORCH_EXPAND_ACCEL_MAX
	scorch.scale_min = 1.4
	scorch.scale_max = 2.4
	_make_emitter("Scorch", &"puff", SCORCH_COUNT, SCORCH_LIFETIME, 1.0,
		scorch, _particle_material(COLOUR_SCORCH, 0.0))


func _build_generic() -> void:
	var shimmer: ParticleProcessMaterial = _flow(
		Vector3.UP, 45.0, 0.8, 1.6, Vector3.ZERO, COLOUR_SHIMMER
	)
	shimmer.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	shimmer.emission_sphere_radius = effect_radius * 0.4
	_make_emitter("Shimmer", &"mote", GENERIC_COUNT, GENERIC_LIFETIME, 0.8,
		shimmer, _particle_material(COLOUR_SHIMMER, GLOW_ENERGY))


# --- plumbing -----------------------------------------------------------------

func _make_emitter(
	node_name: String, mesh_name: StringName, amount: int, lifetime: float,
	explosiveness: float, process: ParticleProcessMaterial,
	surface: StandardMaterial3D
) -> GPUParticles3D:
	var emitter := GPUParticles3D.new()
	emitter.name = node_name
	emitter.one_shot = true
	# Armed by play_at, not here: an emitter that starts the moment it enters
	# the tree would fire during a test's build() inspection.
	emitter.emitting = false
	emitter.amount = amount
	emitter.lifetime = maxf(lifetime * lifetime_scale, 0.05)
	emitter.explosiveness = explosiveness
	emitter.process_material = process
	emitter.draw_pass_1 = _particle_mesh(mesh_name)
	emitter.material_override = surface
	# The default visibility box is eight units on a side; rain falls from above
	# it and grains arc past its edges, and a burst culled mid-flight reads as a
	# bug. One generous box — culling precision is worth nothing on an effect
	# that lives for a second.
	# Symmetric on purpose: the rain emitter sits 6 m up and its droplets occupy
	# the space BELOW it, so a box that only reached 2 m down culled the falling
	# rain whenever the cloud left the frustum.
	var half: float = maxf(effect_radius * 2.0, WATER_CLOUD_HEIGHT * 2.0)
	emitter.visibility_aabb = AABB(
		Vector3(-half, -half, -half), Vector3(half * 2.0, half * 2.0, half * 2.0)
	)
	emitter.finished.connect(_on_emitter_finished)
	_emitters.append(emitter)
	add_child(emitter)
	return emitter


## The shared skeleton of every process material; callers add shapes and
## accelerations on top.
static func _flow(
	direction: Vector3, spread: float, velocity_min: float, velocity_max: float,
	gravity: Vector3, colour: Color
) -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.direction = direction
	process.spread = spread
	process.initial_velocity_min = velocity_min
	process.initial_velocity_max = velocity_max
	process.gravity = gravity
	process.color_ramp = _fade_ramp(colour)
	return process


## Colour held, then faded to transparent over the last stretch of a particle's
## life. This is where every particle's tint lives; the surface material's
## albedo stays white so the two do not multiply into mud.
static func _fade_ramp(colour: Color, hold: float = 0.6) -> GradientTexture1D:
	var linear: Color = colour.srgb_to_linear()
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, hold, 1.0])
	gradient.colors = PackedColorArray([linear, linear, Color(linear, 0.0)])
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


## White albedo (the colour ramp supplies the tint through vertex colour),
## alpha transparency (so the ramp's fade actually fades), no culling (leaves
## and quads are one-sided otherwise), and optionally emissive past the glow
## threshold.
static func _particle_material(
	glow_colour: Color, glow_energy: float
) -> StandardMaterial3D:
	var surface := StandardMaterial3D.new()
	surface.albedo_color = Color.WHITE
	surface.vertex_color_use_as_albedo = true
	surface.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	surface.cull_mode = BaseMaterial3D.CULL_DISABLED
	surface.roughness = 0.8
	if glow_energy > 0.0:
		surface.emission_enabled = true
		surface.emission = glow_colour.srgb_to_linear()
		surface.emission_energy_multiplier = glow_energy
	return surface


## The mesh for one particle, or a small quad when the generated asset is
## absent — a checkout without assets degrades, it does not crash.
static func _particle_mesh(mesh_name: StringName) -> Mesh:
	var path: String = MESH_DIR + "vfx_%s.glb" % mesh_name
	if ResourceLoader.exists(path):
		var packed: PackedScene = load(path)
		if packed != null:
			var root: Node = packed.instantiate()
			var found: MeshInstance3D = _first_mesh_instance(root)
			var mesh: Mesh = found.mesh if found != null else null
			# Freed at once: only the Mesh is wanted, and it is reference
			# counted so it outlives the node. An off-tree node left alive here
			# is an orphan the test runner counts against the run.
			root.free()
			if mesh != null:
				return mesh
	var quad := QuadMesh.new()
	quad.size = Vector2(FALLBACK_QUAD_SIZE, FALLBACK_QUAD_SIZE)
	return quad


static func _first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child: Node in node.get_children():
		var found: MeshInstance3D = _first_mesh_instance(child)
		if found != null:
			return found
	return null


func _animate_bolt() -> void:
	var fade: float = maxf(BOLT_FADE_SECONDS * lifetime_scale, 0.01)
	var flash_time: float = maxf(FLASH_SECONDS * lifetime_scale, 0.01)
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	# The whole bolt shares one material, so one pair of property tweens fades
	# every segment together: white-hot, then down through the glow threshold.
	tween.tween_property(_bolt_material, "emission_energy_multiplier", 0.0, fade)
	tween.tween_property(_bolt_material, "albedo_color:a", 0.0, fade)
	tween.tween_property(_flash, "scale", Vector3.ONE * FLASH_MAX_SCALE, flash_time)
	tween.tween_property(_flash_material, "albedo_color:a", 0.0, flash_time)


func _on_emitter_finished() -> void:
	_finished_count += 1
	if _finished_count >= _emitters.size() and not is_queued_for_deletion():
		queue_free()


func _start_failsafe() -> void:
	# Belt and braces under the finished signals: an emitter that emitted
	# nothing never fires finished, and the headless dummy renderer may never
	# simulate the particles at all. Either way this timer frees the node.
	var timer := Timer.new()
	timer.name = "Failsafe"
	timer.one_shot = true
	timer.wait_time = failsafe_seconds()
	timer.timeout.connect(queue_free)
	add_child(timer)
	timer.start()
