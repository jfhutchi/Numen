extends GutTest
## Acceptance tests for the creature's procedural quadruped body.
##
## The rig is built by a static function, so these tests build the exact geometry
## the creature walks on without booting a CharacterBody3D, a mind or an
## animator. Everything here is shape: the tests that make it move are in
## test_creature_animator.gd.
##
## The point of the module is that the creature reads as an ANIMAL. That is not
## something a test can assert, so what is asserted instead is the structure that
## makes it possible: a torso longer than it is tall, a head with a snout in front
## of it and a jaw under it, ears above it, four legs in four different corners
## with a knee halfway down each, and a tail out the back.

const CREATURE := preload("res://src/creature/body/creature.gd")
const ANIMATOR := preload("res://src/creature/body/creature_animator.gd")
const MIND := preload("res://src/creature/mind/mind.gd")

## Every part the rig is contracted to hand over: the ones the animator poses,
## plus the eyes, which ride the head but still have to exist.
const EXPECTED_PARTS: Array[StringName] = [
	&"torso", &"head", &"jaw", &"ear_left", &"ear_right", &"tail",
	&"eye_left", &"eye_right",
	&"leg_front_left", &"leg_front_right", &"leg_rear_left", &"leg_rear_right",
	&"shin_front_left", &"shin_front_right", &"shin_rear_left", &"shin_rear_right",
]

var _root: Node3D
var _parts: Dictionary[StringName, Node3D]


func before_each() -> void:
	_root = Node3D.new()
	_root.name = "Body"
	# In the tree, so global_position composes the rig's nested joints for us
	# rather than the test doing transform algebra by hand.
	add_child_autofree(_root)
	_parts = CREATURE.build_rig(_root)


func _part(key: StringName) -> Node3D:
	return _parts.get(key)


## Every MeshInstance3D under a node, itself included.
func _meshes(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	var instance := node as MeshInstance3D
	if instance != null:
		found.append(instance)
	for child: Node in node.get_children():
		found.append_array(_meshes(child))
	return found


## A creature with its body built but nothing else booted. _ready() never runs,
## because the node is deliberately not added to the tree — this is the only way
## to look at the collision shape without a mind and a physics frame.
func _built_creature() -> Creature:
	var creature := CREATURE.new()
	autofree(creature)
	# Forced onto the primitive rig: this file asserts on named parts and a shared
	# skin material, and a skinned mesh has neither. The rigged path has its own
	# tests below.
	creature.prefer_rigged_body = false
	creature._build_body()
	return creature


## A creature built on the rigged wolf, when the asset is present.
func _rigged_creature() -> Creature:
	var creature := CREATURE.new()
	autofree(creature)
	creature.prefer_rigged_body = true
	creature._build_body()
	return creature


# --- The parts exist ----------------------------------------------------------

func test_the_rig_builds_every_named_part_with_a_mesh() -> void:
	var meshes: Array[MeshInstance3D] = _meshes(_root)
	gut.p("rig: %d parts named, %d mesh instances in total" % [_parts.size(), meshes.size()])
	for key: StringName in EXPECTED_PARTS:
		var part: Node3D = _part(key)
		assert_not_null(part, "the rig never built '%s'" % key)
		if part == null:
			continue
		var instance := part as MeshInstance3D
		assert_not_null(instance, "'%s' is not a MeshInstance3D" % key)
		if instance != null:
			assert_not_null(instance.mesh, "'%s' has no mesh" % key)
	assert_eq(_parts.size(), EXPECTED_PARTS.size(),
		"the rig hands over parts nothing has been told about")


func test_the_animator_and_the_rig_agree_on_every_name() -> void:
	# The two files only share strings. A rename on one side is otherwise a part
	# that silently never animates.
	var articulated: Array[StringName] = [
		ANIMATOR.PART_TORSO, ANIMATOR.PART_HEAD, ANIMATOR.PART_JAW,
		ANIMATOR.PART_EAR_LEFT, ANIMATOR.PART_EAR_RIGHT, ANIMATOR.PART_TAIL,
	]
	articulated.append_array(ANIMATOR.LEGS)
	articulated.append_array(ANIMATOR.SHINS)
	for key: StringName in articulated:
		assert_true(_parts.has(key), "the animator poses '%s' and the rig never builds it" % key)
	gut.p("%d articulated parts, all present" % articulated.size())


# --- The shape is an animal ---------------------------------------------------

func test_the_torso_lies_along_the_body_and_is_longer_than_it_is_tall() -> void:
	var torso: Node3D = _part(&"torso")
	# A capsule's length is its own local Y. Lying down means that axis points
	# along the body — which is the whole difference between a quadruped and the
	# standing capsule this used to be.
	var length_axis: Vector3 = torso.transform.basis * Vector3.UP
	gut.p("torso length axis %s, %.2f m long by %.2f m thick" % [
		length_axis, CREATURE.TORSO_LENGTH, CREATURE.TORSO_RADIUS * 2.0
	])
	assert_almost_eq(absf(length_axis.z), 1.0, 0.001, "the torso is still standing on end")
	assert_gt(CREATURE.TORSO_LENGTH, CREATURE.TORSO_RADIUS * 2.0,
		"a torso no longer than it is thick is a ball")


func test_the_head_is_forward_and_low_with_a_snout_and_a_jaw() -> void:
	var head: Node3D = _part(&"head")
	var jaw: Node3D = _part(&"jaw")
	var snout: Node3D = head.get_node_or_null(^"Snout") as Node3D
	var skull: Node3D = head.get_node_or_null(^"Skull") as Node3D
	assert_not_null(snout, "no snout")
	assert_not_null(skull, "no skull")

	gut.p("neck %s, skull %s, snout %s, jaw %s" % [
		head.global_position, skull.global_position, snout.global_position, jaw.global_position
	])
	# Forward is +Z. The head hangs off the front of the torso, not on top of it.
	assert_gt(head.global_position.z, CREATURE.TORSO_LENGTH * 0.25,
		"the head should be set forward of the torso's middle")
	assert_lt(head.global_position.y, CREATURE.TORSO_CENTRE.y + CREATURE.TORSO_RADIUS,
		"the head is perched above the shoulders like a snowman's")
	assert_gt(snout.global_position.z, skull.global_position.z,
		"the snout should stick out in front of the skull")
	assert_lt(snout.global_position.y, skull.global_position.y,
		"and sit slightly below it")
	assert_lt(jaw.global_position.y, snout.global_position.y,
		"the jaw hinges under the snout")
	assert_gt(jaw.global_position.z, skull.global_position.z,
		"and in front of the middle of the skull, or it opens backwards")


func test_two_ears_sit_on_top_of_the_head_and_mirror_each_other() -> void:
	var skull: Node3D = _part(&"head").get_node_or_null(^"Skull") as Node3D
	var left: Node3D = _part(&"ear_left")
	var right: Node3D = _part(&"ear_right")
	gut.p("ears at %s and %s, skull at %s" % [
		left.global_position, right.global_position, skull.global_position
	])
	assert_gt(left.global_position.y, skull.global_position.y, "the left ear is not on top")
	assert_gt(right.global_position.y, skull.global_position.y, "the right ear is not on top")
	assert_almost_eq(left.global_position.x, -right.global_position.x, 0.001,
		"the ears are not mirrored")
	assert_gt(absf(left.global_position.x), 0.05, "both ears are in the same place")
	# The creature's own left is +X, matching how creature.gd steers.
	assert_gt(left.global_position.x, 0.0, "the left ear should be on the +X side")


func test_the_eyes_are_big_enough_to_read_and_face_forward() -> void:
	var left: MeshInstance3D = _part(&"eye_left") as MeshInstance3D
	var right: MeshInstance3D = _part(&"eye_right") as MeshInstance3D
	var sphere := left.mesh as SphereMesh
	assert_not_null(sphere, "the eye should be a sphere")
	gut.p("eyes at %s / %s, radius %.3f m" % [
		left.global_position, right.global_position, sphere.radius
	])
	assert_gt(sphere.radius, 0.07,
		"eyes this small vanish into the skin at the gameplay camera distance")
	assert_almost_eq(left.global_position.x, -right.global_position.x, 0.001,
		"the eyes are not mirrored")
	var skull: Node3D = _part(&"head").get_node_or_null(^"Skull") as Node3D
	assert_gt(left.global_position.z, skull.global_position.z,
		"the eyes should be on the front of the skull")
	# Set out far enough from the skull's centre to stand out of its surface.
	var out: float = left.global_position.distance_to(skull.global_position)
	assert_gt(out + sphere.radius, CREATURE.SKULL_RADIUS,
		"the eyes are buried inside the skull")


func test_four_legs_stand_in_four_corners_with_a_knee_in_each() -> void:
	var corners: Array[Vector2] = []
	for i in ANIMATOR.LEGS.size():
		var hip: Node3D = _part(ANIMATOR.LEGS[i])
		var knee: Node3D = _part(ANIMATOR.SHINS[i])
		gut.p("%-16s hip %s knee %s" % [ANIMATOR.LEGS[i], hip.global_position, knee.global_position])

		assert_eq(knee.get_parent(), hip,
			"the knee must hang off the hip, or swinging the hip leaves the shin behind")
		assert_almost_eq(knee.global_position.y, CREATURE.HIP_HEIGHT - CREATURE.THIGH_LENGTH,
			0.001, "the knee is not a thigh's length below the hip")

		var label: String = String(ANIMATOR.LEGS[i])
		var expected_x: float = 1.0 if label.ends_with("left") else -1.0
		var expected_z: float = 1.0 if label.contains("front") else -1.0
		assert_eq(signf(hip.global_position.x), expected_x, "%s is on the wrong side" % label)
		assert_eq(signf(hip.global_position.z), expected_z, "%s is at the wrong end" % label)
		corners.append(Vector2(hip.global_position.x, hip.global_position.z))

	for i in corners.size():
		for j in range(i + 1, corners.size()):
			assert_gt(corners[i].distance_to(corners[j]), 0.1,
				"two legs are standing in the same corner")

	# The legs have to reach the ground, or the creature hovers.
	var reach: float = CREATURE.HIP_HEIGHT - CREATURE.THIGH_LENGTH - CREATURE.SHIN_LENGTH
	gut.p("ankle sits %.3f m up; paw is %.2f m thick" % [reach, CREATURE.PAW_SIZE.y])
	assert_between(reach, 0.0, CREATURE.PAW_SIZE.y,
		"the legs do not reach the ground within a paw's thickness")


func test_the_tail_hangs_off_the_back() -> void:
	var tail: Node3D = _part(&"tail")
	var length: Node3D = tail.get_node_or_null(^"TailLength") as Node3D
	assert_not_null(length, "the tail has no length")
	var direction: Vector3 = tail.transform.basis * length.transform.basis * Vector3.UP
	gut.p("tail base %s pointing %s" % [tail.global_position, direction])
	assert_lt(tail.global_position.z, 0.0, "the tail should be at the back")
	assert_lt(direction.z, -0.5, "the tail should point backwards")
	assert_lt(direction.y, 0.0, "and hang below horizontal")


# --- Physics and colour -------------------------------------------------------

func test_the_collision_capsule_matches_the_visual_body() -> void:
	var lowest: float = INF
	var highest: float = -INF
	var widest: float = 0.0
	var front: float = -INF
	var back: float = INF
	for instance: MeshInstance3D in _meshes(_root):
		var at: Vector3 = instance.global_position
		lowest = minf(lowest, at.y)
		highest = maxf(highest, at.y)
		widest = maxf(widest, absf(at.x))
		front = maxf(front, at.z)
		back = minf(back, at.z)

	var bottom: float = 0.0
	var top: float = CREATURE.COLLIDER_HEIGHT
	gut.p("parts span y %.2f..%.2f, x +-%.2f, z %.2f..%.2f" % [lowest, highest, widest, back, front])
	gut.p("collider: radius %.2f, height %.2f, spanning y %.2f..%.2f" % [
		CREATURE.COLLIDER_RADIUS, CREATURE.COLLIDER_HEIGHT, bottom, top
	])
	assert_lte(bottom, lowest, "the capsule starts above the paws")
	assert_gte(top, highest, "the capsule does not reach the top of the head")
	assert_lt(top, highest + 0.5, "the capsule towers over the creature")
	assert_gte(CREATURE.COLLIDER_RADIUS, widest, "the capsule is narrower than the creature")
	assert_lt(CREATURE.COLLIDER_RADIUS, widest + CREATURE.LEG_RADIUS * 2.0,
		"the capsule is much wider than the creature")
	# Deliberately not as long as the animal: see the comment on COLLIDER_RADIUS.
	assert_lt(CREATURE.COLLIDER_RADIUS, (front - back) * 0.5,
		"a capsule this fat is a ball, and the creature is longer than it is wide")


func test_the_body_wires_a_collision_shape_sat_on_the_ground() -> void:
	var creature: Creature = _built_creature()
	var shape: CollisionShape3D = creature.get_node_or_null(^"Collider") as CollisionShape3D
	assert_not_null(shape, "the body built no collision shape")
	var capsule := shape.shape as CapsuleShape3D
	assert_not_null(capsule, "the collision shape is not a capsule")
	gut.p("collider at %s, radius %.2f, height %.2f" % [
		shape.position, capsule.radius, capsule.height
	])
	assert_almost_eq(capsule.radius, CREATURE.COLLIDER_RADIUS, 0.001)
	assert_almost_eq(capsule.height, CREATURE.COLLIDER_HEIGHT, 0.001)
	# A capsule is centred on its own origin, so this is what keeps the creature
	# out of a hole in the ground.
	assert_almost_eq(shape.position.y, CREATURE.COLLIDER_HEIGHT * 0.5, 0.001,
		"the capsule is not sat on the ground")
	assert_not_null(creature.get_node_or_null(^"Body"), "the animator's root node is missing")


func test_every_skin_part_shares_one_material_so_alignment_tints_all_of_it() -> void:
	var creature: Creature = _built_creature()
	var torso: MeshInstance3D = creature.get_node_or_null(^"Body/Torso") as MeshInstance3D
	var skull: MeshInstance3D = creature.get_node_or_null(^"Body/Head/Skull") as MeshInstance3D
	var thigh: MeshInstance3D = creature.get_node_or_null(^"Body/HipFrontLeft/ThighFrontLeft") as MeshInstance3D
	assert_not_null(torso)
	assert_not_null(skull)
	assert_not_null(thigh)
	# One material for the lot: the old body tinted its torso only, which read as
	# a creature wearing a jumper.
	assert_eq(skull.material_override, torso.material_override,
		"the head does not share the torso's skin")
	assert_eq(thigh.material_override, torso.material_override,
		"the legs do not share the torso's skin")

	var eye: MeshInstance3D = creature.get_node_or_null(^"Body/Head/EyeLeft") as MeshInstance3D
	assert_ne(eye.material_override, torso.material_override,
		"the eyes must not tint with the skin, or the creature has no expression")


func test_alignment_tints_the_skin_and_feedback_flashes_over_it() -> void:
	var creature: Creature = _built_creature()
	creature.mind = MIND.new()
	var skin: StandardMaterial3D = creature._skin_material

	creature.mind.alignment = -1.0
	creature._tick_flash(0.016)
	var cruel: Color = skin.albedo_color
	creature.mind.alignment = 1.0
	creature._tick_flash(0.016)
	var kind: Color = skin.albedo_color
	gut.p("cruel skin %s, kind skin %s" % [cruel, kind])
	assert_lt(cruel.g, kind.g, "cruelty should darken the creature")
	assert_gt(cruel.r / maxf(cruel.g, 0.0001), kind.r / maxf(kind.g, 0.0001),
		"cruelty should redden the creature")

	# The flash rides over the tint and fades back to it.
	creature.mind.alignment = 0.0
	creature._tick_flash(0.016)
	var calm: Color = skin.albedo_color
	creature._flash_with(Color(1.0, 0.35, 0.3))
	creature._tick_flash(0.016)
	var flashed: Color = skin.albedo_color
	gut.p("calm %s, flashed %s" % [calm, flashed])
	assert_gt(flashed.r - calm.r, 0.1, "a slap should flash the skin")
	for i in 60:
		creature._tick_flash(0.016)
	gut.p("after %.1fs the skin is back to %s" % [60 * 0.016, skin.albedo_color])
	assert_almost_eq(skin.albedo_color.r, calm.r, 0.001, "the flash never faded")


func test_the_rig_is_deterministic() -> void:
	# No RandomNumberGenerator anywhere in the body: two creatures built from the
	# same code have to be the same shape, or nothing above can be asserted.
	var other := Node3D.new()
	add_child_autofree(other)
	var twin: Dictionary[StringName, Node3D] = CREATURE.build_rig(other)
	for key: StringName in EXPECTED_PARTS:
		assert_true(twin[key].transform.is_equal_approx(_parts[key].transform),
			"'%s' was built differently the second time" % key)


# --- The rigged body ----------------------------------------------------------

func test_the_rigged_body_loads_the_wolf_with_its_animation_player() -> void:
	# The creature's whole point is being watchable, so the asset actually
	# resolving matters more than any single property of it.
	if CREATURE.preferred_rig().is_empty():
		pass_test("no rigged asset in this checkout; the primitive rig covers it")
		return

	var creature: Creature = _rigged_creature()
	var player: AnimationPlayer = creature._wolf_player
	assert_not_null(player, "the rigged body should expose an AnimationPlayer")
	if player == null:
		return

	var clips: PackedStringArray = player.get_animation_list()
	gut.p("wolf clips available: %d" % clips.size())
	assert_gt(clips.size(), 0, "the rig should carry baked clips")


func test_every_animation_state_maps_to_a_clip_the_wolf_actually_has() -> void:
	# A state with no clip freezes the creature mid-pose. Mapping by hand is
	# exactly the kind of thing that rots when either side is edited, so it is
	# checked against the rig rather than against a list.
	if CREATURE.preferred_rig().is_empty():
		pass_test("no rigged asset in this checkout")
		return

	var creature: Creature = _rigged_creature()
	var player: AnimationPlayer = creature._wolf_player
	if player == null:
		return
	var available: PackedStringArray = player.get_animation_list()

	var clips: Dictionary = CREATURE.preferred_rig()["clips"]
	for state: StringName in clips:
		var wanted: String = String(clips[state])
		var found := false
		for candidate: String in available:
			if candidate == wanted or candidate.get_slice("|", 1) == wanted:
				found = true
				break
		assert_true(found, "state '%s' maps to clip '%s', which the rig does not have"
			% [state, wanted])


func test_the_rigged_body_still_gets_a_collision_shape() -> void:
	# Regression. The first version returned early once the wolf loaded and never
	# built the collider, so the creature fell straight through the island.
	if CREATURE.preferred_rig().is_empty():
		pass_test("no rigged asset in this checkout")
		return

	var creature: Creature = _rigged_creature()
	var shape: CollisionShape3D = creature.get_node_or_null(^"Collider")
	assert_not_null(shape, "a rigged creature needs collision as much as a primitive one")
	if shape != null:
		assert_not_null(shape.shape)


func test_the_rigged_body_tints_by_overlay_so_the_wolfs_own_materials_survive() -> void:
	if CREATURE.preferred_rig().is_empty():
		pass_test("no rigged asset in this checkout")
		return

	var creature: Creature = _rigged_creature()
	assert_not_null(creature._alignment_overlay, "expected an alignment overlay")
	assert_not_null(creature._wolf_mesh, "expected to find the skinned mesh")
	if creature._wolf_mesh == null:
		return
	# material_override would flatten coat, light coat, eyes and nose into one
	# colour and the animal would lose its face.
	assert_null(creature._wolf_mesh.material_override,
		"the wolf's own materials must not be overridden")
	assert_gt(creature._wolf_mesh.mesh.get_surface_count(), 1,
		"the wolf should keep its several surfaces")


# --- It stays out of the sea --------------------------------------------------

func _islanded_creature() -> Creature:
	var island: Node3D = load("res://src/world/island.gd").new()
	add_child_autofree(island)
	island.generate(20260729)
	var creature := CREATURE.new()
	creature.prefer_rigged_body = false
	add_child_autofree(creature)
	# The registry is a Node used off-tree, so it needs freeing explicitly or GUT
	# reports it as an orphan.
	var registry: Node = load("res://src/world/object_registry.gd").new()
	autofree(registry)
	creature.configure(registry, island, null, 7)
	return creature


func test_the_creature_refuses_to_walk_off_the_island() -> void:
	# It used to. Found at y = -14.9, below the sea floor, still playing its walk
	# cycle: the island's height field simply ends at the shore, so there is no
	# floor out there and nothing stopped it.
	var creature: Creature = _islanded_creature()
	var island: Node3D = creature._island

	var half: float = island.extent * 0.5
	assert_false(creature._is_walkable(half, half), "the far corner is open sea")
	assert_true(creature._is_walkable(0.0, 0.0), "the middle of the island is land")


func test_a_creature_in_the_sea_is_fetched_back_onto_land() -> void:
	# The other way in: thrown there by the divine hand, which can pick the
	# creature up. Refusing to walk into water does not help once it is airborne.
	var creature: Creature = _islanded_creature()
	creature.global_position = Vector3(70.0, -6.0, 70.0)
	creature._keep_out_of_the_sea()

	gut.p("rescued to %s" % creature.global_position)
	assert_gt(creature.global_position.y, 0.0, "a drowning creature should be put back on land")
	assert_true(creature._is_walkable(creature.global_position.x, creature.global_position.z),
		"and put back somewhere it can actually stand")
	assert_eq(creature.velocity, Vector3.ZERO, "its fall should not carry on afterwards")


func test_a_creature_on_dry_land_is_left_alone() -> void:
	# The rescue must not fire for a creature merely standing in a dip.
	var creature: Creature = _islanded_creature()
	var island: Node3D = creature._island
	var where := Vector3(0.0, island.height_at(0.0, 0.0) + 0.5, 0.0)
	creature.global_position = where
	creature._keep_out_of_the_sea()
	assert_eq(creature.global_position, where, "a creature on land should not be teleported")


# --- It grows up ---------------------------------------------------------------

func test_the_creature_grows_from_cub_to_adult_with_age() -> void:
	# The mind already ages — learning rate and temperature decay — but the body
	# never showed it: the creature arrived adult-sized and stayed that way. Size
	# is the one channel a player reads at a glance.
	var creature: Creature = _islanded_creature()
	creature.mind.age_seconds = 0.0
	assert_almost_eq(creature.growth_scale(), creature.growth_start_scale, 0.001,
		"a newborn starts at the cub scale")

	creature.mind.age_seconds = creature.growth_full_age * 0.5
	var half: float = creature.growth_scale()
	assert_between(half, creature.growth_start_scale + 0.01, 0.99,
		"halfway through childhood it should be visibly between cub and adult")

	creature.mind.age_seconds = creature.growth_full_age * 3.0
	assert_almost_eq(creature.growth_scale(), 1.0, 0.001,
		"an adult stops growing rather than becoming a kaiju")

	# Monotonic: age must never shrink it.
	var previous: float = 0.0
	for step in 12:
		creature.mind.age_seconds = creature.growth_full_age * float(step) / 10.0
		var now: float = creature.growth_scale()
		assert_gte(now, previous, "growth must never reverse")
		previous = now
