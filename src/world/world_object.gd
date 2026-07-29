class_name WorldObject
extends RefCounted
## One thing in the world: something the hand can grab, the villagers can use,
## and the creature can perceive.
##
## Deliberately a plain record rather than a Node. Most scenery lives inside a
## MultiMesh and has no node at all until someone picks it up, and the creature
## needs to reason about thousands of these without touching the scene tree.

var id: int = 0
var type: StringName = &""
var position: Vector3 = Vector3.ZERO

## The scene node backing this object, when it has one. Scattered scenery is
## null here until it is grabbed and a physics body is promoted for it.
var node: Node3D = null

## Index into the scatter's MultiMesh, or -1 for objects that were never
## instanced that way.
var multimesh_index: int = -1

## Cleared when consumed, eaten, or destroyed. Queries skip dead objects rather
## than compacting the store, so ids stay stable for anything holding one.
var alive: bool = true


func _init(object_id: int = 0, object_type: StringName = &"", at: Vector3 = Vector3.ZERO) -> void:
	id = object_id
	type = object_type
	position = at


## Current position, preferring the live node when one exists.
func current_position() -> Vector3:
	if node != null and is_instance_valid(node):
		return node.global_position
	return position


func _to_string() -> String:
	return "WorldObject#%d(%s)" % [id, type]
