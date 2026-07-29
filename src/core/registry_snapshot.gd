class_name RegistrySnapshot
extends RefCounted
## Save and load for the world object registry (src/world/object_registry.gd).
##
## Doubles as a participant in the save contract: wrap a registry in one of
## these and hand it to SaveManager.register, or call the two statics directly.
##
## OBJECT IDS ARE PRESERVED EXACTLY, and that is the whole point of the file.
## The creature's belief table is keyed by object id, so remapping ids on load
## would silently reattach every learned opinion to the wrong thing — the rock
## it was slapped for throwing becomes the villager it was petted for feeding,
## with nothing anywhere to indicate that something went wrong. Ids are also
## never reused by the registry, so the counter is saved rather than re-derived.
##
## WHAT IS NOT SAVED: the `node` a WorldObject may be holding. A live scene node
## cannot be rebuilt generically — a villager, a physics-promoted rock and a
## MultiMesh instance are each reconstructed differently, and only the scene's
## owner knows how. The snapshot records type, position and multimesh index,
## flags the rows that had a node, and leaves reconstruction to the caller: walk
## the payload's `objects` rows after restoring, and rebuild the ones whose
## `had_node` is true.

const SAVE_ID := &"world"

var _registry: Node = null


func _init(registry: Node = null) -> void:
	_registry = registry


func save_id() -> StringName:
	return SAVE_ID


## Both entry points refuse a snapshot built without a registry rather than
## crashing inside `capture`/`restore`. SaveManager's contract check only looks
## for the three method names, so a `RegistrySnapshot.new()` with the argument
## forgotten registers happily and then takes the whole save down on the first
## write — long after the mistake was made.
func to_dict() -> Dictionary:
	if _registry == null:
		push_error("[save] world snapshot has no registry; nothing to capture")
		return {}
	return capture(_registry)


func from_dict(data: Dictionary) -> void:
	if _registry == null:
		push_error("[save] world snapshot has no registry; nothing to restore")
		return
	restore(_registry, data)


## Records every live object in the registry.
##
## Positions come from `current_position()`, so a rock the player threw is saved
## where it landed rather than where it grew.
static func capture(registry: Node) -> Dictionary:
	var rows: Array = []
	var highest: int = 0
	for object: WorldObject in registry.all():
		var at: Vector3 = object.current_position()
		rows.append({
			# Plain JSON numbers, unlike RNG state. Ids count up from 1 and will
			# not approach 2^53 in any session, so a double holds them exactly;
			# see SaveManager.int_to_json for the case where that is not true.
			"id": object.id,
			"type": String(object.type),
			"at": [at.x, at.y, at.z],
			"mm": object.multimesh_index,
			"had_node": object.node != null,
		})
		highest = maxi(highest, object.id)

	# Read through `Object.get` rather than `registry._next_id`. The registry
	# keeps its id counter private and offers no accessor, and reaching for an
	# undeclared member on a `Node`-typed variable leans on the compiler's
	# unsafe-access path; `get` is a real method on Object and cannot surprise
	# us. Falling back to the highest id keeps a renamed field from writing a
	# nonsense counter into the save.
	var counter: Variant = registry.get(&"_next_id")
	var next_id: int = highest + 1
	if typeof(counter) == TYPE_INT:
		next_id = int(counter)

	return {
		"objects": rows,
		# Saved rather than derived on load. The highest-numbered object may
		# well have been eaten before the save, and deriving the counter would
		# hand its id to the next new object — aliasing it against every belief
		# the creature still holds about the dead one.
		"next_id": next_id,
	}


## Rebuilds `registry` from a snapshot, replacing everything it currently holds.
##
## Emits the registry's own `object_added` for each row, so anything listening
## rebuilds alongside it.
static func restore(registry: Node, data: Dictionary) -> void:
	registry.clear()

	var rows_value: Variant = data.get("objects", [])
	if typeof(rows_value) != TYPE_ARRAY:
		push_warning("[save] world snapshot has no object array; registry left empty")
		return

	var rows: Array = rows_value
	var highest: int = 0
	for row: Dictionary in rows:
		var id: int = int(row.get("id", 0))
		var at_value: Variant = row.get("at", [])
		var at: Array = []
		if typeof(at_value) == TYPE_ARRAY:
			at = at_value
		if id <= 0 or at.size() < 3:
			push_warning("[save] skipping malformed world object row: %s" % row)
			continue
		# The registry hands out ids from its own counter and offers no way to
		# ask for a specific one, so the counter is steered and `add` does the
		# rest. The alternative is writing straight into its object dictionary,
		# which would reach past two privates instead of one and would skip the
		# `object_added` signal that listeners depend on.
		registry.set(&"_next_id", id)
		registry.add(
			StringName(row.get("type", "")),
			Vector3(float(at[0]), float(at[1]), float(at[2])),
			null,
			int(row.get("mm", -1))
		)
		highest = maxi(highest, id)

	registry.set(&"_next_id", maxi(int(data.get("next_id", 0)), highest + 1))
