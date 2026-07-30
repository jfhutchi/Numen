extends GutTest
## Carrying things that are not scatter props.
##
## The hand was written when only trees and rocks were grabbable, and it asked the
## scatter for every carried visual. The scatter has no villager or food mesh, so a
## grabbed villager was an invisible body in a closed hand while the crowd batch
## went on drawing the person elsewhere — reported from play, invisible to every
## test then in the suite, because nothing asserted the grasp contains a MESH.

const HAND := preload("res://src/hand/hand.gd")
const REGISTRY := preload("res://src/world/object_registry.gd")
const ISLAND := preload("res://src/world/island.gd")
const SCATTER := preload("res://src/world/scatter.gd")
const VILLAGE := preload("res://src/village/village.gd")

var _registry: Node
var _island: Node3D
var _village: Node3D
var _hand: Node3D


func before_each() -> void:
	_registry = REGISTRY.new()
	autofree(_registry)
	_island = ISLAND.new()
	add_child_autofree(_island)
	_island.generate(20260729)

	_village = VILLAGE.new()
	_village.auto_simulate = false
	add_child_autofree(_village)
	_village.populate(_island, _registry, 20260729)

	var scatter: Node3D = SCATTER.new()
	scatter.tree_count = 0
	scatter.rock_count = 0
	add_child_autofree(scatter)
	scatter.populate(_island, _registry)

	_hand = HAND.new()
	add_child_autofree(_hand)
	_hand.configure(null, _island, scatter, _registry)


func after_each() -> void:
	for child: Node in get_children():
		if child.name.begins_with("Detached_"):
			child.free()


func _first_villager() -> Villager:
	return _village.villagers()[0]


func _meshes_under(node: Node) -> int:
	var found: int = 0
	var instance := node as MeshInstance3D
	if instance != null and instance.mesh != null:
		found += 1
	for child: Node in node.get_children():
		found += _meshes_under(child)
	return found


func test_a_grabbed_villager_is_visible_in_the_grasp() -> void:
	var villager: Villager = _first_villager()
	assert_true(_hand.grab_at(villager.position), "expected to catch the villager")
	assert_eq(_hand.held_object().type, &"villager")

	var body: RigidBody3D = villager.object.node as RigidBody3D
	assert_not_null(body, "the carry should hang a physics body on the record")
	if body == null:
		return
	# The regression. The old path returned a MeshInstance3D with mesh = null,
	# so this counted zero and the player held nothing they could see.
	var meshes: int = _meshes_under(body)
	gut.p("carried villager body contains %d visible mesh(es)" % meshes)
	assert_gt(meshes, 0, "a carried villager must be visible in the hand")


func test_the_crowd_stops_drawing_a_carried_villager() -> void:
	var villager: Villager = _first_villager()
	var index: int = _village.villagers().find(villager)
	_village.simulate(0.2)
	var before: Vector3 = _village.villager_instance_transform(index).basis.get_scale()
	assert_gt(before.length(), 0.5, "drawn at full size before the grab")

	assert_true(_hand.grab_at(villager.position))
	assert_true(villager.is_hand_held(), "the record should know the hand owns it")
	_village.simulate(0.2)
	var during: Vector3 = _village.villager_instance_transform(index).basis.get_scale()
	gut.p("crowd instance scale before %.3f -> during carry %.6f" % [
		before.length(), during.length()
	])
	assert_lt(during.length(), 0.01,
		"the crowd must hide a carried villager or the player sees two of them")

	# And the neighbours must not vanish with it.
	var other: int = (index + 1) % _village.population()
	assert_gt(_village.villager_instance_transform(other).basis.get_scale().length(), 0.5,
		"hiding one villager should not hide the village")


func test_a_put_down_villager_returns_to_the_crowd() -> void:
	var villager: Villager = _first_villager()
	var index: int = _village.villagers().find(villager)
	assert_true(_hand.grab_at(villager.position))
	_hand.release()

	# The body was released at ground level with no throw; it settles within a few
	# physics frames, and the next village step adopts the position and frees it.
	var recovered := false
	for i in 40:
		await wait_physics_frames(2)
		_village.simulate(0.1)
		if not villager.is_hand_held():
			recovered = true
			break
	assert_true(recovered, "the villager should get its feet back after being put down")
	var after: Vector3 = _village.villager_instance_transform(index).basis.get_scale()
	gut.p("crowd instance scale after put-down: %.3f" % after.length())
	assert_gt(after.length(), 0.5, "and the crowd should draw them again")


func test_a_grabbed_food_pile_carries_its_marker_along() -> void:
	# Food piles are marker-backed: the marker IS the visual, so it must ride in
	# the grasp rather than stay planted where it was picked.
	var marker := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.45
	marker.mesh = mesh
	add_child_autofree(marker)
	var spot := Vector3(0.0, maxf(_island.height_at(0.0, 0.0), 1.0), 0.0)
	marker.position = spot + Vector3.UP * 0.45
	var food: WorldObject = _registry.add(&"food_pile", spot, marker)

	assert_true(_hand.grab_at(spot), "expected to catch the food pile")
	assert_eq(_hand.held_object().id, food.id)

	var body: RigidBody3D = food.node as RigidBody3D
	assert_not_null(body, "the record should now point at the carried body")
	if body == null:
		return
	assert_true(marker.get_parent() == body or body.is_ancestor_of(marker),
		"the marker should have moved into the carried body")
	assert_gt(_meshes_under(body), 0, "and the grasp should contain something visible")
