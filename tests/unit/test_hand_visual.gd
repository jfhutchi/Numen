extends GutTest
## The divine hand's mesh and its grasp.
##
## The game is built around acting through a hand, the hand is documented as the
## only cursor — and until now src/hand/hand.gd contained no mesh at all. You moved
## an invisible point and things happened. These tests exist so it cannot silently
## go back to being invisible.

const HAND := preload("res://src/hand/hand.gd")
const REGISTRY := preload("res://src/world/object_registry.gd")
const ISLAND := preload("res://src/world/island.gd")
const SCATTER := preload("res://src/world/scatter.gd")

var _registry: Node
var _hand: Node3D


func before_each() -> void:
	_registry = REGISTRY.new()
	autofree(_registry)
	_hand = HAND.new()
	add_child_autofree(_hand)


func after_each() -> void:
	# Grabbing promotes a physics body parented beside the hand, which outlives
	# autofree.
	for child: Node in get_children():
		if child.name.begins_with("Detached_"):
			child.free()


func _asset_present() -> bool:
	return ResourceLoader.exists(HAND.HAND_SCENE)


func test_the_hand_has_a_mesh_at_all() -> void:
	if not _asset_present():
		pass_test("hand asset absent from this checkout")
		return
	var visual: Node3D = _hand.get_node_or_null(^"HandVisual")
	assert_not_null(visual, "the hand must be visible; it shipped invisible for eight phases")
	if visual == null:
		return
	var meshes: int = _count_meshes(visual)
	gut.p("hand visual carries %d mesh instances" % meshes)
	assert_gt(meshes, 4, "expected a palm, four fingers and a thumb at minimum")


func test_every_named_joint_in_the_mapping_exists_in_the_mesh() -> void:
	# The joint names are the only contract between the Blender script and this
	# file. A rename on either side leaves a digit that silently never moves.
	if not _asset_present():
		pass_test("hand asset absent from this checkout")
		return
	assert_eq(_hand._joints.size(), HAND.FINGER_JOINTS.size(),
		"every joint named in FINGER_JOINTS should have been found in hand.glb")


func test_the_curl_tables_line_up_with_the_joints() -> void:
	# Indexed in lockstep; a short table would read past the end or leave a digit
	# stuck open.
	assert_eq(HAND.CURL_ANGLE.size(), HAND.FINGER_JOINTS.size())
	assert_eq(HAND.CURL_PHASE.size(), HAND.FINGER_JOINTS.size())
	for phase: float in HAND.CURL_PHASE:
		assert_lt(phase, 1.0, "a phase of 1.0 or more means that digit never closes")


func test_the_hand_closes_on_a_grab_and_opens_on_release() -> void:
	var rock: WorldObject = _registry.add(&"rock", Vector3.ZERO)
	_hand.configure(null, null, _make_scatter(), _registry)
	_hand._ground_target = Vector3.ZERO

	assert_almost_eq(_hand.curl(), 0.0, 0.001, "a hand starts open")

	assert_true(_hand.grab_at(Vector3.ZERO), "expected to catch the rock")
	_hand._update_visual(1.0)
	var closed: float = _hand.curl()
	gut.p("curl after grabbing: %.2f" % closed)
	assert_gt(closed, 0.9, "grabbing should close the hand")

	_hand.release()
	_hand._update_visual(1.0)
	gut.p("curl after releasing: %.2f" % _hand.curl())
	assert_lt(_hand.curl(), 0.1, "releasing should open it again")


func test_closing_actually_rotates_the_fingers() -> void:
	# The curl number moving is not the same as the mesh moving. This is the
	# assertion that would have caught the fingers curling the wrong way — upward,
	# so a closed hand read as a row of railings pointing at the sky.
	if not _asset_present() or _hand._joints.is_empty():
		pass_test("hand asset absent from this checkout")
		return

	var joint: Node3D = _hand._joints[0]
	var open_basis: Basis = joint.transform.basis
	_hand._curl_target = 1.0
	_hand._update_visual(1.0)
	var closed_basis: Basis = joint.transform.basis

	var swing: float = open_basis.z.angle_to(closed_basis.z)
	gut.p("first finger swung %.1f degrees" % rad_to_deg(swing))
	assert_gt(swing, 0.3, "the finger geometry should actually move, not just the number")

	# Down and inward, not up. The finger points along +Z at rest; closing must
	# carry it toward -Y.
	assert_lt(closed_basis.z.y, open_basis.z.y - 0.1,
		"fingers must curl down into the palm, not up away from it")


func _make_scatter() -> Node3D:
	var scatter: Node3D = SCATTER.new()
	scatter.tree_count = 0
	scatter.rock_count = 0
	add_child_autofree(scatter)
	var island: Node3D = ISLAND.new()
	add_child_autofree(island)
	island.generate(1)
	# Its own registry, freed with the test: a Node used off-tree is an orphan
	# otherwise, and GUT counts orphans against the run.
	var throwaway: Node = REGISTRY.new()
	autofree(throwaway)
	scatter.populate(island, throwaway)
	return scatter


func _count_meshes(node: Node) -> int:
	var found: int = 1 if node is MeshInstance3D else 0
	for child: Node in node.get_children():
		found += _count_meshes(child)
	return found
