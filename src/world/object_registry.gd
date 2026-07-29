extends Node
## The world's ground truth, autoloaded as `World`.
##
## Everything the hand can grab, the villagers can use, or the creature can
## perceive is registered here. This is the single seam the creature's
## perception reads through (see src/creature/mind/world_view.gd), which is what
## lets the whole learning system be tested headless with no scene at all.

signal object_added(object: WorldObject)
signal object_removed(object: WorldObject)

var _objects: Dictionary[int, WorldObject] = {}
var _next_id: int = 1


func clear() -> void:
	_objects.clear()
	_next_id = 1


func add(type: StringName, at: Vector3, node: Node3D = null, multimesh_index: int = -1) -> WorldObject:
	var object := WorldObject.new(_next_id, type, at)
	object.node = node
	object.multimesh_index = multimesh_index
	_objects[object.id] = object
	_next_id += 1
	object_added.emit(object)
	return object


## Marks an object dead and drops it from the store. Ids are never reused.
func remove(id: int) -> void:
	var object: WorldObject = _objects.get(id)
	if object == null:
		return
	object.alive = false
	_objects.erase(id)
	object_removed.emit(object)


func get_object(id: int) -> WorldObject:
	return _objects.get(id)


func count() -> int:
	return _objects.size()


func all() -> Array[WorldObject]:
	var result: Array[WorldObject] = []
	for object: WorldObject in _objects.values():
		if object.alive:
			result.append(object)
	return result


## Objects of the given types within `radius` of `centre`.
## Pass an empty `types` array to accept every type.
##
## ponytail: linear scan. Fine for the low hundreds of objects at a 5 Hz
## decision tick; swap in a spatial hash if profiling ever says otherwise.
func query_near(centre: Vector3, radius: float, types: Array = []) -> Array[WorldObject]:
	var result: Array[WorldObject] = []
	var radius_squared: float = radius * radius
	var filtering: bool = not types.is_empty()
	for object: WorldObject in _objects.values():
		if not object.alive:
			continue
		if filtering and not types.has(object.type):
			continue
		if object.current_position().distance_squared_to(centre) <= radius_squared:
			result.append(object)
	return result


## Nearest live object of the given types, or null when nothing is in range.
func nearest(centre: Vector3, radius: float, types: Array = []) -> WorldObject:
	var best: WorldObject = null
	var best_distance: float = INF
	for object: WorldObject in query_near(centre, radius, types):
		var distance: float = object.current_position().distance_squared_to(centre)
		if distance < best_distance:
			best_distance = distance
			best = object
	return best
