class_name Creature
extends CharacterBody3D
## The creature's body: the thing that carries the mind around and acts on what
## it decides.
##
## The body is deliberately dumb. It holds no plan and makes no choices — it
## walks to whatever the mind picked, performs the action when it arrives, and
## reports what the world did back. Every decision lives in src/creature/mind/.

signal chose(option: CreatureMind.Option)
signal acted_on(action: StringName, object: WorldObject)
signal feedback_shown(value: float)

const LEASH_NONE := &"none"
const LEASH_LEARNING := &"learning"
const LEASH_COMPASSION := &"compassion"
const LEASH_AGGRESSION := &"aggression"

## How hard each leash leans on the relevant desire. Not an override — a
## leashed creature still does what it has learned, it is just inclined.
const LEASH_BIAS: Dictionary = {
	LEASH_COMPASSION: {&"Compassion": 2.2, &"Anger": 0.35},
	LEASH_AGGRESSION: {&"Anger": 2.2, &"Compassion": 0.35},
}

## Proportions of the quadruped rig, in metres, measured from the ground between
## its paws. Constants rather than exports because the collider, the rig and the
## animator's captured rest pose all have to agree: changing one of these means
## rebuilding the body, which is not something the inspector can do to a live
## creature. What IS tuned live — every animation amplitude — lives on
## CreatureAnimatorTunables instead.
##
## Forward is local +Z, and the creature's own left is +X. +Z is not the Godot
## model convention, but it is what _move_toward_target() steers by:
## rotation.y = atan2(direction.x, direction.z) maps local +Z onto the direction
## of travel, so a body built facing -Z would walk backwards.
const HIP_HEIGHT := 1.30
const THIGH_LENGTH := 0.62
const SHIN_LENGTH := 0.55
const LEG_RADIUS := 0.16
const LEG_SPREAD_X := 0.40
const FRONT_LEG_Z := 0.62
const REAR_LEG_Z := -0.62
const PAW_SIZE := Vector3(0.34, 0.16, 0.46)
const TORSO_LENGTH := 1.70
const TORSO_RADIUS := 0.52
const TORSO_CENTRE := Vector3(0.0, 1.34, 0.0)
## The neck joint: where the head hangs off the front of the torso, and the point
## the head rotates about.
const NECK := Vector3(0.0, 1.58, 0.70)
const SKULL_RADIUS := 0.34
## Head-local, so relative to NECK. Forward and a little down, the way an animal
## carries its head, rather than perched on top like a snowman's.
const SKULL_CENTRE := Vector3(0.0, -0.06, 0.34)
const SNOUT_SIZE := Vector3(0.30, 0.24, 0.44)
## Deliberately oversized. Small eyes are invisible at the gameplay camera
## distance and the creature reads as faceless.
const EYE_RADIUS := 0.10
const EAR_HEIGHT := 0.26
const EAR_RADIUS := 0.14
## Rest splay of the ears, radians. The twitch adds to this.
const EAR_TILT := 0.26
const TAIL_BASE := Vector3(0.0, 1.50, -0.80)
const TAIL_LENGTH := 0.72
const TAIL_RADIUS := 0.10
## How far below horizontal the tail hangs, radians.
const TAIL_DROOP := 0.34
## Upright capsule around the torso and head. Deliberately not the length of the
## animal: a collider that reached the snout and the tail would snag on terrain
## and on gaps the creature can plainly walk through.
const COLLIDER_RADIUS := 0.56
const COLLIDER_HEIGHT := 1.90

## Skin at neutral alignment, and the two poles it is tinted toward. Named
## because _tick_flash() and the material both need them and a copy in each
## drifts.
## Ground must stand at least this far above the waterline to be walked on. A
## little above zero, so the creature stops on dry sand rather than in the surf.
const SHORE_MARGIN := 0.4
## Below this height the creature is in the sea and gets fetched out. The island's
## sea floor is at -10, so this triggers long before it reaches anything solid.
const DROWN_DEPTH := -1.0

## How fast a pet/slap flash fades, in units per second. Shared by both bodies so
## the two cannot drift to different response speeds.
const FLASH_FADE_PER_SECOND := 2.0
## Peak overlay alpha at full cruelty or full kindness, for the rigged body. Kept
## well below 1.0 deliberately: the point is to tint the wolf, not to repaint it.
const ALIGNMENT_TINT_STRENGTH := 0.45
## Peak overlay alpha for a fresh pet or slap. Stronger than the alignment tint,
## because a slap has to read in the instant it happens.
const FLASH_TINT_STRENGTH := 0.7

const SKIN_NEUTRAL := Color(0.55, 0.45, 0.38)
const SKIN_CRUEL := Color(0.32, 0.13, 0.14)
const SKIN_KIND := Color(0.62, 0.58, 0.40)

## The rigged CC0 biped — an upright walking companion, which is how the genre's
## creatures carried themselves. Preferred over the wolf when present.
const BIPED_SCENE := "res://assets/third_party/quaternius/ultimate-monsters/yeti.glb"

## The biped's clips. Two stand-ins are deliberate and should be replaced if the
## rig ever grows the real thing: eat maps to Duck (it crouches to the ground,
## which reads as feeding at gameplay distance), and sleep to Idle (the animator
## would fall back there anyway; mapping it keeps the choice visible). Wave for a
## pet response reads as delight; Punch is the attack.
const BIPED_CLIPS: Dictionary = {
	&"idle": "Idle",
	&"walk": "Walk",
	&"eat": "Duck",
	&"sleep": "Idle",
	&"attack": "Punch",
	&"hurt": "HitReact",
	&"celebrate": "Wave",
	&"play": "Run",
}

## The rigged CC0 wolf, kept as the fallback body. Absent from a checkout without
## assets, in which case the primitive rig below is built instead.
const WOLF_SCENE := "res://assets/third_party/quaternius/ultimate-animated-animals/wolf.glb"

## Which baked clip each animation state plays. The wolf happens to ship a clip
## for every state the animator already had, which is why it was chosen over the
## other eleven animals in the pack.
const WOLF_CLIPS: Dictionary = {
	&"idle": "Idle",
	&"walk": "Walk",
	&"eat": "Eating",
	&"sleep": "Idle_2_HeadLow",
	&"attack": "Attack",
	&"hurt": "Idle_HitReact_Left",
	&"celebrate": "Jump_ToIdle",
	&"play": "Gallop_Jump",
}

## Tuned by eye against a 1.73 m villager and a 3.2 m hut, because the imported
## bounds are unreliable: a skinned mesh reports its bind-pose AABB, and the
## armature's IK pole targets inflate the source model's height to 5.26 units.
@export var wolf_scale: float = 1.7
## Same story for the biped: bind-pose bounds are meaningless, so the scale is
## set against the villager it towers over. 2.0 puts the adult at roughly 2.6 m —
## head and shoulders over a 1.73 m villager without dwarfing the huts.
@export var biped_scale: float = 2.1

## Set false to force the primitive rig even when the asset is present. The
## articulation tests use this: they assert on named parts and a shared skin
## material, neither of which a skinned mesh has.
@export var prefer_rigged_body: bool = true

## Fraction of adult size at birth. The mind already grows up — learning rate and
## softmax temperature both decay with age — and nothing showed it: the creature
## arrived full-sized and stayed that way for life. Now the body agrees with the
## mind about what age means.
@export_range(0.1, 1.0) var growth_start_scale: float = 0.72
## Seconds of age at which the creature reaches full size. Matches the pacing of
## the mind's own temperature_halflife scale rather than being realistic.
@export var growth_full_age: float = 1200.0

## How much of its perception range the creature learns by imitation within, as a
## fraction. Off the learning leash it is only glancing over rather than being
## shown, so it has to be closer for anything to stick.
@export_range(0.0, 1.0) var imitation_reach_fraction: float = 0.45

@export var move_speed: float = 7.0
@export var turn_speed: float = 6.0
## How close it must be before it can act on something.
@export var action_radius: float = 3.0
@export var gravity: float = 24.0
## Drives drift over time so the creature has reasons to do things.
@export var hunger_per_second: float = 0.012
@export var fatigue_per_second: float = 0.006
@export var idle_per_second: float = 0.05

var mind: CreatureMind
var animator: CreatureAnimator
var leash: StringName = LEASH_NONE

var _island: Node3D
var _registry: Node
var _rng := RandomNumberGenerator.new()
var _next_decision: float = 0.0
var _target: WorldObject = null
## One material shared by every skin part, so tinting the creature is one write
## rather than a walk of the rig.
var _skin_material: StandardMaterial3D
var _body_root: Node3D = null
## The scale the body was built at; growth multiplies this rather than replacing
## it, because the rigged and primitive bodies are built at different base sizes.
var _built_scale: Vector3 = Vector3.ONE
var _wolf_player: AnimationPlayer = null
## The state-to-clip map of whichever rig was actually built.
var _rig_clips: Dictionary = {}
var _wolf_mesh: MeshInstance3D = null
var _alignment_overlay: StandardMaterial3D = null
var _parts: Dictionary[StringName, Node3D] = {}
var _flash: float = 0.0
var _flash_colour := Color.WHITE


func configure(
	registry: Node, island: Node3D, tunables: MindTunables = null, seed_value: int = 0
) -> void:
	_registry = registry
	_island = island
	_rng.seed = seed_value
	mind = CreatureMind.new(tunables, seed_value)
	mind.bind_world(registry, global_position)


func _ready() -> void:
	_build_body()
	if mind == null:
		# Standing alone in a scene with no configure() call; still functional.
		mind = CreatureMind.new()

	animator = CreatureAnimator.new()
	animator.name = "Animator"
	# Driven explicitly from _physics_process below. Self-ticking as well would
	# advance the animation twice per frame at an invisible half-speed offset.
	animator.auto_advance = false
	add_child(animator)
	animator.configure(get_node_or_null(^"Body") as Node3D)
	if _wolf_player != null:
		# Rigged body: the state machine drives baked clips.
		animator.bind_animation_player(_wolf_player, _rig_clips)
	else:
		# configure() only learns the root. The named parts are what let it
		# articulate a gait instead of bobbing the whole creature as one lump.
		animator.bind_parts(_parts)


func set_leash(new_leash: StringName) -> void:
	leash = new_leash
	var bias: Dictionary = LEASH_BIAS.get(new_leash, {})
	var typed: Dictionary[StringName, float] = {}
	for key: StringName in bias:
		typed[key] = float(bias[key])
	mind.desire_bias = typed


## Player reward. Credits whatever the creature did in the last few seconds.
func pet() -> void:
	mind.apply_player_feedback(1.0)
	_flash_with(Color(0.4, 1.0, 0.5))
	if animator != null:
		animator.request_state(&"celebrate")
	feedback_shown.emit(1.0)


## Player punishment.
func slap() -> void:
	mind.apply_player_feedback(-1.0)
	_flash_with(Color(1.0, 0.35, 0.3))
	if animator != null:
		animator.request_state(&"hurt")
	feedback_shown.emit(-1.0)


## The player did something to an object in front of the creature. On the leash
## of learning this is a strong lesson; otherwise it is mere imitation.
## Returns true when the creature actually took the lesson.
##
## Three things were wrong with the first version, and all three made the central
## mechanic of the genre reachable only by accident:
##
## 1. **It did not check whether the creature could see.** A rock thrown on the
##    far side of the island taught it just as well as one thrown at its feet.
##    Being led somewhere and shown a thing is the whole point of the learning
##    leash; if distance does not matter, the leash does not either.
## 2. **Every lesson was filed under Curiosity**, whatever it was about. The
##    cross-desire fallback meant the knowledge was still reachable, but a lesson
##    about healing belongs with Compassion, and putting it elsewhere makes the
##    Mind Inspector's account of why the creature acted a fiction.
## 3. **One caller, with a hardcoded action and value.** Nothing the player did on
##    purpose taught the creature anything on purpose.
func witness(action: StringName, object: WorldObject, value: float) -> bool:
	if object == null:
		return false
	# It has to be able to see it. Off the leash the creature is only glancing over,
	# so it has to be closer still for mere imitation to take.
	var reach: float = mind.tunables.perception_radius
	if leash != LEASH_LEARNING:
		reach *= imitation_reach_fraction
	if global_position.distance_to(object.current_position()) > reach:
		return false

	var desire: StringName = OpinionStore.desire_for_action(action)
	if leash == LEASH_LEARNING:
		mind.learn_from_demonstration(desire, action, object, value)
	else:
		mind.learn_from_imitation(desire, action, object, value)
	if animator != null:
		# It looks up when it notices. Cheap, and it tells the player the lesson
		# landed without opening the Inspector.
		animator.request_state(&"celebrate" if value > 0.0 else &"hurt")
	return true


func _physics_process(delta: float) -> void:
	_drift_drives(delta)
	mind.advance_clock(delta)
	mind.set_position(global_position)

	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	_next_decision -= delta
	if _next_decision <= 0.0:
		_decide()
		# Jittered so a herd of creatures never thinks on the same frame.
		var interval: float = 1.0 / maxf(mind.tunables.decision_hz, 0.001)
		_next_decision = interval * (
			1.0 + _rng.randf_range(-mind.tunables.decision_jitter, mind.tunables.decision_jitter)
		)

	_move_toward_target(delta)
	move_and_slide()
	_keep_out_of_the_sea()
	_tick_flash(delta)

	if animator != null:
		animator.set_locomotion_speed(Vector2(velocity.x, velocity.z).length())
		animator.advance(delta)

	if _body_root != null:
		_body_root.scale = _built_scale * growth_scale()


func _decide() -> void:
	var choice: CreatureMind.Option = mind.choose()
	if choice == null:
		_target = null
		return
	_target = choice.object
	chose.emit(choice)

	# Act immediately if already close enough; otherwise walk over first and the
	# next decision will catch it.
	if _target != null and global_position.distance_to(_target.current_position()) <= action_radius:
		_perform(choice)


func _perform(option: CreatureMind.Option) -> void:
	mind.perform(option)
	acted_on.emit(option.action, option.object)
	if animator != null:
		animator.request_state(CreatureActionStates.for_action(option.action))

	# Intrinsic consequences: what the world says back, with no player involved.
	if option.object == null:
		return
	match option.action:
		&"eat":
			var nutrition: float = ObjectAttributes.truth_for(option.object.type)[
				ObjectAttributes.index_of(&"nutritious")
			]
			if nutrition > 0.1:
				mind.hunger = clampf(mind.hunger - nutrition * 0.5, 0.0, 1.0)
				mind.apply_intrinsic_feedback(option.desire, option.action, option.object, nutrition)
			else:
				# Eating a rock teaches its own lesson.
				mind.apply_intrinsic_feedback(option.desire, option.action, option.object, -0.5)
		&"sleep":
			mind.fatigue = clampf(mind.fatigue - 0.4, 0.0, 1.0)
			mind.apply_intrinsic_feedback(option.desire, option.action, option.object, 0.4)


func _drift_drives(delta: float) -> void:
	mind.hunger = clampf(mind.hunger + hunger_per_second * delta, 0.0, 1.0)
	mind.fatigue = clampf(mind.fatigue + fatigue_per_second * delta, 0.0, 1.0)
	mind.idle = clampf(mind.idle + idle_per_second * delta, 0.0, 1.0)


## Keeps the creature out of the sea, and fetches it back if it ends up there.
##
## The island's collision is a height field that stops at the shoreline, so there
## is simply no floor past the edge: a creature that walks off it falls for ever.
## It was found at y = -14.9, below the sea floor, still cheerfully playing its
## walk cycle. Two guards, because the two failure modes are different — walking
## out under its own steam, and being thrown out by the player's hand.
func _keep_out_of_the_sea() -> void:
	if _island == null:
		return
	if global_position.y >= DROWN_DEPTH:
		return
	# Already in the drink. Walk it back to the middle of the island, which is
	# land by construction, rather than guessing at the nearest shore.
	var rescue := Vector3(0.0, 0.0, 0.0)
	rescue.y = maxf(_island.height_at(0.0, 0.0), 0.0) + 1.0
	global_position = rescue
	velocity = Vector3.ZERO


## True when the ground at this spot is dry enough to stand on.
func _is_walkable(x: float, z: float) -> bool:
	if _island == null:
		return true
	return _island.height_at(x, z) > SHORE_MARGIN


func _move_toward_target(delta: float) -> void:
	if _target == null or not _target.alive:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	var to_target: Vector3 = _target.current_position() - global_position
	to_target.y = 0.0
	if to_target.length() <= action_radius:
		velocity.x = 0.0
		velocity.z = 0.0
		return

	var direction: Vector3 = to_target.normalized()

	# Stop at the shoreline rather than striding into the sea after something
	# floating just offshore. Checked one step ahead, so it halts on land instead
	# of halting once it is already falling.
	var step: Vector3 = global_position + direction * move_speed * delta
	if not _is_walkable(step.x, step.z):
		velocity.x = 0.0
		velocity.z = 0.0
		# Still turn to face it. A creature that wants something across the water
		# and stares at it reads as thwarted; one that stops facing away reads as
		# broken.
		var facing: float = atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, facing, clampf(turn_speed * delta, 0.0, 1.0))
		return

	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed

	var wanted: float = atan2(direction.x, direction.z)
	rotation.y = lerp_angle(rotation.y, wanted, clampf(turn_speed * delta, 0.0, 1.0))


func _build_body() -> void:
	var root := Node3D.new()
	root.name = "Body"
	add_child(root)
	_body_root = root

	# Rig preference: the upright biped first — the genre's creatures walked on
	# two legs, and an upright companion at eye height with the player's villages
	# is most of what makes it read as a being rather than a pet — then the wolf,
	# then the hand-assembled primitive rig for a checkout with no assets at all.
	#
	# The collider is built below either way. An earlier version returned early on
	# the rigged path and the creature had no collision shape at all, so it fell
	# through the island the moment gravity touched it.
	var rig: Dictionary = preferred_rig()
	if not (prefer_rigged_body and not rig.is_empty() and _build_rigged(root, rig)):
		_skin_material = default_skin()
		_parts = build_rig(root, _skin_material)

	var shape := CollisionShape3D.new()
	shape.name = "Collider"
	var collider := CapsuleShape3D.new()
	collider.radius = COLLIDER_RADIUS
	collider.height = COLLIDER_HEIGHT
	shape.shape = collider
	# Sat on the ground, not centred on it. A capsule shape is centred on its own
	# origin, so at y = 0 half the creature would be underground and it would
	# spend its life standing in a hole.
	shape.position = Vector3(0.0, COLLIDER_HEIGHT * 0.5, 0.0)
	add_child(shape)
	_built_scale = _body_root.scale


## The best rigged body this checkout has: the biped, else the wolf, else none.
## Static so the tests can interrogate the same preference the build uses.
static func preferred_rig() -> Dictionary:
	if ResourceLoader.exists(BIPED_SCENE):
		return {"scene": BIPED_SCENE, "clips": BIPED_CLIPS, "scale": &"biped"}
	if ResourceLoader.exists(WOLF_SCENE):
		return {"scene": WOLF_SCENE, "clips": WOLF_CLIPS, "scale": &"wolf"}
	return {}


## Instances a rigged CC0 body under `root`. Returns false when loading fails,
## so the caller falls back to the primitive rig.
func _build_rigged(root: Node3D, rig: Dictionary) -> bool:
	var packed: PackedScene = load(rig["scene"])
	if packed == null:
		return false

	var instance: Node = packed.instantiate()
	if instance == null:
		return false
	root.add_child(instance)
	root.scale = Vector3.ONE * (biped_scale if rig["scale"] == &"biped" else wolf_scale)
	_rig_clips = rig["clips"]

	_wolf_player = _find_first(instance, "AnimationPlayer") as AnimationPlayer
	_wolf_mesh = _find_skinned_mesh(instance)

	if _wolf_mesh != null:
		# Alignment is expressed as an overlay rather than by replacing the
		# material. The wolf carries four surfaces (coat, light coat, eyes, nose)
		# and a material_override would flatten all four into one colour, losing
		# the face entirely.
		_alignment_overlay = StandardMaterial3D.new()
		_alignment_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_alignment_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_alignment_overlay.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
		_wolf_mesh.material_overlay = _alignment_overlay

	return _wolf_player != null


## Depth-first search for the first node of a class. The glTF import hierarchy is
## the exporter's business, not ours, so nothing here depends on its shape.
func _find_first(node: Node, class_wanted: String) -> Node:
	if node.is_class(class_wanted):
		return node
	for child: Node in node.get_children():
		var found: Node = _find_first(child, class_wanted)
		if found != null:
			return found
	return null


func _find_skinned_mesh(node: Node) -> MeshInstance3D:
	var mesh := node as MeshInstance3D
	if mesh != null and mesh.mesh != null:
		return mesh
	for child: Node in node.get_children():
		var found: MeshInstance3D = _find_skinned_mesh(child)
		if found != null:
			return found
	return null


## Builds the quadruped rig under `root` and returns its parts by name.
##
## Static, and filling a root it is handed, so the tests can build the exact rig
## the creature walks on without booting a CharacterBody3D, a mind and an
## animator. The alternative was a mock rig in the test file, and a mock rig
## drifts away from the real one silently — which is how the old animator ended
## up matching its head parts by height and finding nothing.
##
## Every returned part sits at the joint it rotates about: a hip node at the hip,
## a jaw node at the hinge, the head node at the neck. That is the contract
## CreatureAnimator poses them under — it only ever rotates a part about its own
## origin — so the visible geometry hangs off each joint as child meshes rather
## than being the joint itself. A leg mesh centred on the hip would swing its top
## half out through the shoulder.
static func build_rig(
	root: Node3D, skin: StandardMaterial3D = null
) -> Dictionary[StringName, Node3D]:
	if skin == null:
		skin = default_skin()
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.07, 0.06, 0.06).srgb_to_linear()
	dark.roughness = 0.6
	var iris := StandardMaterial3D.new()
	iris.albedo_color = Color(0.95, 0.72, 0.24).srgb_to_linear()
	iris.roughness = 0.25

	var parts: Dictionary[StringName, Node3D] = {}

	# Torso. A capsule's long axis is its local Y, so it is tipped a quarter turn
	# to lie along the body: longer than it is tall, which is most of what makes
	# the silhouette read as an animal rather than as a standing figure.
	var lie_along_z := Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
	parts[CreatureAnimator.PART_TORSO] = _part(
		root, "Torso", _capsule(TORSO_RADIUS, TORSO_LENGTH), TORSO_CENTRE, skin, lie_along_z
	)
	# Shoulder hump and haunches. Not animated — they are bulk, so the legs come
	# out of a mass instead of out of the taper at the end of a capsule. Siblings
	# of the torso rather than children: the torso is scaled when the creature
	# breathes, and children would inflate with it.
	#
	# Trim like this is sized as a fraction of the named dimensions above, so the
	# whole animal can be rescaled from one constant without going lumpy.
	_part(
		root, "Shoulders", _sphere(TORSO_RADIUS * 0.90),
		TORSO_CENTRE + Vector3(0.0, 0.09, TORSO_LENGTH * 0.30), skin
	)
	_part(
		root, "Haunches", _sphere(TORSO_RADIUS * 0.86),
		TORSO_CENTRE + Vector3(0.0, 0.04, TORSO_LENGTH * -0.30), skin
	)

	_build_legs(root, parts, skin, dark)
	_build_head(root, parts, skin, dark, iris)

	# Tail: a joint at the base with the length hanging off it, so a sway pivots
	# from the rump.
	var tail: MeshInstance3D = _part(root, "Tail", _sphere(TAIL_RADIUS * 1.2), TAIL_BASE, skin)
	parts[CreatureAnimator.PART_TAIL] = tail
	# Local +Y is the capsule's length; this aims it backwards and down.
	var droop := Basis.from_euler(Vector3(-(PI * 0.5 + TAIL_DROOP), 0.0, 0.0))
	_part(
		tail, "TailLength", _capsule(TAIL_RADIUS, TAIL_LENGTH),
		droop * Vector3(0.0, TAIL_LENGTH * 0.5, 0.0), skin, droop
	)

	return parts


## Four legs, each a hip joint carrying a thigh and a knee joint carrying a shank
## and a paw. The knee is a child of the hip, so swinging the hip takes the whole
## leg with it and the knee only has to add its own bend.
static func _build_legs(
	root: Node3D, parts: Dictionary[StringName, Node3D],
	skin: StandardMaterial3D, dark: StandardMaterial3D
) -> void:
	for i in CreatureAnimator.LEGS.size():
		# Read off the name rather than off the index: the animator's gait phases
		# are indexed by the same order, and a leg placed in the wrong corner
		# would still trot correctly while looking wrong.
		var label: String = String(CreatureAnimator.LEGS[i])
		var x: float = LEG_SPREAD_X if label.ends_with("left") else -LEG_SPREAD_X
		var z: float = FRONT_LEG_Z if label.contains("front") else REAR_LEG_Z
		var suffix: String = label.trim_prefix("leg_").to_pascal_case()

		var hip: MeshInstance3D = _part(
			root, "Hip" + suffix, _sphere(LEG_RADIUS * 1.15), Vector3(x, HIP_HEIGHT, z), skin
		)
		parts[CreatureAnimator.LEGS[i]] = hip
		_part(
			hip, "Thigh" + suffix, _capsule(LEG_RADIUS, THIGH_LENGTH),
			Vector3(0.0, -THIGH_LENGTH * 0.5, 0.0), skin
		)

		var knee: MeshInstance3D = _part(
			hip, "Knee" + suffix, _sphere(LEG_RADIUS), Vector3(0.0, -THIGH_LENGTH, 0.0), skin
		)
		parts[CreatureAnimator.SHINS[i]] = knee
		_part(
			knee, "Shank" + suffix, _capsule(LEG_RADIUS * 0.85, SHIN_LENGTH),
			Vector3(0.0, -SHIN_LENGTH * 0.5, 0.0), skin
		)
		# The paw's underside lands on y = 0 when the leg hangs straight.
		_part(
			knee, "Paw" + suffix, _box(PAW_SIZE),
			Vector3(0.0, -SHIN_LENGTH - PAW_SIZE.y * 0.5 + 0.03, PAW_SIZE.z * 0.16), dark
		)


## Head, snout, jaw, ears and eyes, all hanging off the neck joint so a nod moves
## the lot together.
static func _build_head(
	root: Node3D, parts: Dictionary[StringName, Node3D],
	skin: StandardMaterial3D, dark: StandardMaterial3D, iris: StandardMaterial3D
) -> void:
	var head: MeshInstance3D = _part(root, "Head", _sphere(SKULL_RADIUS * 0.6), NECK, skin)
	parts[CreatureAnimator.PART_HEAD] = head
	_part(head, "Skull", _sphere(SKULL_RADIUS), SKULL_CENTRE, skin)
	# Snout: a blunt box out of the front of the skull, its back end buried so
	# there is no seam. This and the jaw under it are what stop the head reading
	# as a ball.
	var snout_at: Vector3 = SKULL_CENTRE + Vector3(0.0, -0.10, SKULL_RADIUS * 0.82)
	_part(head, "Snout", _box(SNOUT_SIZE), snout_at, skin)
	_part(
		head, "Nose", _sphere(SNOUT_SIZE.x * 0.28),
		snout_at + Vector3(0.0, 0.06, SNOUT_SIZE.z * 0.5), dark
	)

	# Jaw hinged under the back of the snout. Rotating it about +X drops the chin,
	# and the chin plate is sized so a shut mouth ends level with the nose.
	var jaw: MeshInstance3D = _part(
		head, "Jaw", _sphere(SNOUT_SIZE.x * 0.3), SKULL_CENTRE + Vector3(0.0, -0.22, 0.12), skin
	)
	parts[CreatureAnimator.PART_JAW] = jaw
	_part(
		jaw, "Chin", _box(Vector3(SNOUT_SIZE.x * 0.86, 0.12, SNOUT_SIZE.z * 0.92)),
		Vector3(0.0, -0.04, SNOUT_SIZE.z * 0.42), skin
	)

	# Ears and eyes, mirrored. The creature's own left is +X, so the left ear
	# tilts toward +X, which is a negative rotation about Z.
	var ear_keys: Array[StringName] = [
		CreatureAnimator.PART_EAR_LEFT, CreatureAnimator.PART_EAR_RIGHT
	]
	var eye_keys: Array[StringName] = [&"eye_left", &"eye_right"]
	for i in 2:
		var side: float = 1.0 if i == 0 else -1.0
		var suffix: String = "Left" if i == 0 else "Right"
		# Ear origins sit just inside the skull so a twitch never opens a gap.
		parts[ear_keys[i]] = _part(
			head, "Ear" + suffix, _cone(EAR_RADIUS, EAR_HEIGHT),
			SKULL_CENTRE + Vector3(side * 0.19, 0.24, -0.08), skin,
			Basis.from_euler(Vector3(0.0, 0.0, -side * EAR_TILT))
		)
		# Amber and big, with a dark pupil in front: at gameplay camera distance a
		# pair of small dark dots vanishes into the skin and the creature stops
		# having a face. Offset far enough from the skull centre to stand out of it.
		var eye: MeshInstance3D = _part(
			head, "Eye" + suffix, _sphere(EYE_RADIUS),
			SKULL_CENTRE + Vector3(side * 0.16, 0.10, SKULL_RADIUS * 0.76), iris
		)
		parts[eye_keys[i]] = eye
		_part(eye, "Pupil", _sphere(EYE_RADIUS * 0.55), Vector3(0.0, 0.0, EYE_RADIUS * 0.7), dark)


static func default_skin() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = SKIN_NEUTRAL.srgb_to_linear()
	material.roughness = 0.85
	return material


static func _part(
	parent: Node3D, part_name: String, mesh: Mesh, at: Vector3, material: Material,
	orientation: Basis = Basis.IDENTITY
) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.transform = Transform3D(orientation, at)
	instance.material_override = material
	parent.add_child(instance)
	return instance


# Low-poly on purpose: a stylised animal built from a couple of dozen primitives,
# and the defaults (64 radial segments on a sphere) would spend a lot of vertices
# on a creature the camera rarely gets close to.

static func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	# A SphereMesh with height below twice its radius is a squashed ellipsoid.
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	return mesh


static func _capsule(radius: float, height: float) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 16
	mesh.rings = 4
	return mesh


static func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


static func _cone(radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	mesh.rings = 1
	return mesh


## How grown the creature is, as a multiplier on its built size: growth_start at
## birth easing to 1.0 at growth_full_age. Smoothstepped so the visible growing
## happens in the middle of childhood rather than as a linear creep.
func growth_scale() -> float:
	var progress: float = clampf(mind.age_seconds / maxf(growth_full_age, 1.0), 0.0, 1.0)
	return lerpf(growth_start_scale, 1.0, smoothstep(0.0, 1.0, progress))


func _flash_with(colour: Color) -> void:
	_flash = 1.0
	_flash_colour = colour


## Alignment and feedback for the rigged body, as a translucent overlay.
##
## The wolf's own four materials are left intact and washed over instead of
## replaced: a material_override would collapse coat, light coat, eyes and nose
## into one flat colour and the animal would lose its face. Alpha carries the
## strength, so a neutral, un-slapped creature is exactly the mesh as authored.
func _tick_wolf_tint(delta: float) -> void:
	var cruelty: float = clampf(-mind.alignment, 0.0, 1.0)
	var kindness: float = clampf(mind.alignment, 0.0, 1.0)
	var tint: Color = SKIN_CRUEL if cruelty >= kindness else SKIN_KIND
	var strength: float = maxf(cruelty, kindness) * ALIGNMENT_TINT_STRENGTH

	if _flash > 0.0:
		_flash = maxf(_flash - delta * FLASH_FADE_PER_SECOND, 0.0)
		tint = _flash_colour
		strength = maxf(strength, _flash * FLASH_TINT_STRENGTH)

	_alignment_overlay.albedo_color = Color(tint.r, tint.g, tint.b, strength)


func _tick_flash(delta: float) -> void:
	if _alignment_overlay != null:
		_tick_wolf_tint(delta)
		return
	if _skin_material == null:
		return
	# Alignment tints the creature: cruelty darkens and reddens it. Feedback
	# flashes over the top so a slap reads instantly. Every skin part shares this
	# one material, so the whole animal tints — the old body only tinted its
	# torso, which read as a creature wearing a jumper.
	var base: Color = SKIN_NEUTRAL.lerp(SKIN_CRUEL, clampf(-mind.alignment, 0.0, 1.0))
	base = base.lerp(SKIN_KIND, clampf(mind.alignment, 0.0, 1.0))
	if _flash > 0.0:
		_flash = maxf(_flash - delta * FLASH_FADE_PER_SECOND, 0.0)
		_skin_material.albedo_color = base.lerp(_flash_colour, _flash).srgb_to_linear()
	else:
		_skin_material.albedo_color = base.srgb_to_linear()
