extends GutTest
## Whole-game save and load: the contract, the 64-bit regression that made a
## reloaded creature diverge, refusing a version this build cannot read, and the
## world registry snapshot.

const REGISTRY := preload("res://src/world/object_registry.gd")
const SAVE_PATH := "user://numen_save_test.json"

## The first integer a double cannot represent. Everything this file is about.
const BEYOND_DOUBLE: int = 9007199254740993


## A minimal participant in the save contract, standing in for a real system.
class FakeSystem:
	extends RefCounted
	var label: String = "untouched"
	var big: int = 0
	var precise: float = 0.0

	func save_id() -> StringName:
		return &"fake"

	func to_dict() -> Dictionary:
		return {"label": label, "big": SaveManager.int_to_json(big), "precise": precise}

	func from_dict(data: Dictionary) -> void:
		label = str(data.get("label", ""))
		big = SaveManager.int_from_json(data.get("big", "0"))
		precise = float(data.get("precise", 0.0))


func after_each() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)


func test_a_registered_system_roundtrips_through_a_file() -> void:
	var source := FakeSystem.new()
	source.label = "learned"
	source.big = BEYOND_DOUBLE

	var writer := SaveManager.new()
	writer.register(source)
	var before: Dictionary = writer.capture()
	assert_eq(writer.save_to(SAVE_PATH), OK, "the save should be written")

	var target := FakeSystem.new()
	var reader := SaveManager.new()
	reader.register(target)
	assert_eq(reader.load_from(SAVE_PATH), OK, "the save should load back")

	var after: Dictionary = reader.capture()
	gut.p("saved:  %s" % JSON.stringify(before))
	gut.p("loaded: %s" % JSON.stringify(after))

	# Compared as text. Dictionary `==` is a shallow comparison, so two payloads
	# whose nested system slices were merely equal-looking would pass it without
	# the contents having survived at all.
	assert_eq(JSON.stringify(after), JSON.stringify(before),
		"a loaded game must capture byte-identically to the one that was saved")
	assert_eq(target.label, "learned", "the system itself should hold the loaded values")


func test_a_64_bit_value_survives_the_round_trip_exactly() -> void:
	# The regression that cost a debugging session. RNG seed and state are 64-bit
	# and JSON numbers parse back as doubles, so everything past 2^53 loses its
	# low bits without a word — and a creature resumed from a *nearly* identical
	# generator diverges within a decision or two.
	var values: Array[int] = [
		BEYOND_DOUBLE,
		-BEYOND_DOUBLE,
		7237005577332262210,  # the shape of a real RandomNumberGenerator state
	]
	gut.p("%22s | %22s | %22s" % ["value", "as a JSON number", "as a JSON string"])
	for value: int in values:
		var probe: Dictionary = JSON.parse_string(JSON.stringify({"n": value}))
		var naive: int = int(probe.get("n", 0))
		var survived: int = SaveManager.int_from_json(SaveManager.int_to_json(value))
		gut.p("%22d | %22d | %22d   (number is off by %d)" % [
			value, naive, survived, value - naive
		])
		assert_eq(survived, value, "a 64-bit value must survive JSON exactly")

	var source := FakeSystem.new()
	source.big = BEYOND_DOUBLE
	var writer := SaveManager.new()
	writer.register(source)
	assert_eq(writer.save_to(SAVE_PATH), OK)

	var target := FakeSystem.new()
	var reader := SaveManager.new()
	reader.register(target)
	assert_eq(reader.load_from(SAVE_PATH), OK)

	gut.p("through a real save file: %d (wanted %d)" % [target.big, source.big])
	assert_eq(target.big, source.big, "a 64-bit field must come back bit for bit")


func test_a_float_survives_the_round_trip_exactly() -> void:
	# The float half of the same problem. JSON.stringify writes only the digits it
	# considers reliable unless asked for full precision, so a double that needs
	# all seventeen is written short and parses back a hair off. Belief,
	# alignment and hunger are all doubles a reload is supposed to resume from
	# rather than approximate.
	#
	# Built by arithmetic instead of written as a literal, so the value is exactly
	# whatever IEEE 754 addition produces rather than whatever the tokenizer makes
	# of a seventeen-digit constant. 0.1 + 0.2 is the textbook double that is not
	# 0.3, and writing it with fourteen digits rounds it to 0.3 exactly.
	var source := FakeSystem.new()
	source.precise = 0.1 + 0.2

	var writer := SaveManager.new()
	writer.register(source)
	assert_eq(writer.save_to(SAVE_PATH), OK)

	var target := FakeSystem.new()
	var reader := SaveManager.new()
	reader.register(target)
	assert_eq(reader.load_from(SAVE_PATH), OK)

	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file != null:
		gut.p("on disk: %s" % file.get_as_text().replace("\n", "").replace("\t", ""))
		file.close()
	gut.p("saved %.20f, loaded %.20f (off by %.20f)" % [
		source.precise, target.precise, target.precise - source.precise
	])
	assert_eq(target.precise, source.precise, "a float must come back bit for bit too")


func test_a_version_mismatch_is_refused_and_changes_nothing() -> void:
	var target := FakeSystem.new()
	var manager := SaveManager.new()
	manager.register(target)

	manager.restore({
		"version": SaveManager.VERSION + 99,
		"systems": {"fake": {"label": "from the future", "big": "42"}},
	})

	gut.p("refusal: %s" % manager.last_error())
	assert_eq(target.label, "untouched", "a refused load must not half-apply")
	assert_eq(target.big, 0, "and must not apply any of it")
	assert_ne(manager.last_error(), "", "the refusal should say why")
	assert_push_error("version", "refusing a save from another format should be loud")


func test_loading_a_future_save_file_returns_an_error() -> void:
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	assert_not_null(file, "the test needs to be able to write to user://")
	if file == null:
		return
	file.store_string(JSON.stringify({
		"version": SaveManager.VERSION + 1,
		"systems": {"fake": {"label": "newer", "big": "42"}},
	}))
	file.close()

	var target := FakeSystem.new()
	var manager := SaveManager.new()
	manager.register(target)
	var result: Error = manager.load_from(SAVE_PATH)

	gut.p("load_from returned %d: %s" % [result, manager.last_error()])
	assert_ne(result, OK, "a save this build cannot read must fail, not load halfway")
	assert_eq(target.label, "untouched")
	assert_push_error("version")


func test_registering_something_that_cannot_save_is_refused_loudly() -> void:
	# Accepting it silently would drop the system from every save, and the player
	# would only find out when their game came back missing a piece.
	var manager := SaveManager.new()
	manager.register(RefCounted.new())

	var payload: Dictionary = manager.capture()
	var systems: Dictionary = payload.get("systems", {})
	assert_eq(systems.size(), 0, "a system that cannot save must not be registered")
	assert_push_error("save_id")


func test_the_creature_mind_saves_under_an_explicit_id() -> void:
	# The path the game itself needs. CreatureMind predates the save contract and
	# has no save_id() of its own, so the wiring names it — and this is the
	# system whose 64-bit RNG state started the whole string-encoding rule.
	var mind := CreatureMind.new(null, 20260729)
	mind.hunger = 0.87
	mind.alignment = -0.42

	var writer := SaveManager.new()
	writer.register_as(&"creature", mind)
	assert_eq(writer.save_to(SAVE_PATH), OK)

	var reloaded := CreatureMind.new(null, 1)
	var reader := SaveManager.new()
	reader.register_as(&"creature", reloaded)
	assert_eq(reader.load_from(SAVE_PATH), OK)

	var saved_state: String = str(mind.to_dict().get("rng_state", ""))
	var loaded_state: String = str(reloaded.to_dict().get("rng_state", ""))
	gut.p("rng state saved %s, reloaded %s" % [saved_state, loaded_state])
	gut.p("hunger %.4f -> %.4f, alignment %.4f -> %.4f" % [
		mind.hunger, reloaded.hunger, mind.alignment, reloaded.alignment
	])
	assert_eq(loaded_state, saved_state, "the generator must resume from the same state")
	assert_almost_eq(reloaded.hunger, mind.hunger, 0.000001)
	assert_almost_eq(reloaded.alignment, mind.alignment, 0.000001)


func test_registry_snapshot_preserves_ids_and_types() -> void:
	var registry: Node = REGISTRY.new()
	autofree(registry)
	var tree: WorldObject = registry.add(&"tree", Vector3(1.5, 2.0, 3.25))
	var rock: WorldObject = registry.add(&"rock", Vector3(4.0, 0.0, -5.0), null, 7)
	var villager: WorldObject = registry.add(&"villager", Vector3(-2.0, 1.0, 0.0))
	var eaten: WorldObject = registry.add(&"food_pile", Vector3(8.0, 0.0, 8.0))
	registry.remove(eaten.id)

	var snapshot: Dictionary = RegistrySnapshot.capture(registry)
	gut.p("snapshot: %s" % JSON.stringify(snapshot))

	var restored: Node = REGISTRY.new()
	autofree(restored)
	# Through JSON rather than straight across, because that is the only path the
	# game will ever actually take.
	RegistrySnapshot.restore(restored, JSON.parse_string(JSON.stringify(snapshot)))

	assert_eq(restored.count(), 3, "the eaten food pile should not come back")
	assert_null(restored.get_object(eaten.id), "a removed object must stay removed")

	var restored_tree: WorldObject = restored.get_object(tree.id)
	var restored_rock: WorldObject = restored.get_object(rock.id)
	var restored_villager: WorldObject = restored.get_object(villager.id)
	assert_not_null(restored_tree, "object ids are what the belief table is keyed by")
	assert_not_null(restored_rock)
	assert_not_null(restored_villager)
	if restored_tree == null or restored_rock == null or restored_villager == null:
		return

	gut.p("ids: tree %d -> %d, rock %d -> %d, villager %d -> %d" % [
		tree.id, restored_tree.id, rock.id, restored_rock.id, villager.id, restored_villager.id
	])
	assert_eq(restored_tree.type, &"tree", "types must survive exactly")
	assert_eq(restored_rock.type, &"rock")
	assert_eq(restored_villager.type, &"villager")
	assert_eq(restored_tree.position, Vector3(1.5, 2.0, 3.25))
	assert_eq(restored_rock.multimesh_index, 7, "the scatter index has to come back too")

	# The id counter is saved, not re-derived: the highest id belonged to the
	# food pile that was eaten, and handing that id out again would alias the new
	# object against everything the creature still believes about the dead one.
	var fresh: WorldObject = restored.add(&"rock", Vector3.ZERO)
	gut.p("next id after load: %d (eaten object was %d)" % [fresh.id, eaten.id])
	assert_gt(fresh.id, eaten.id, "ids must never be reused across a save")


func test_snapshot_records_where_an_object_is_now_not_where_it_spawned() -> void:
	# A rock the player threw has to be saved where it landed.
	var registry: Node = REGISTRY.new()
	autofree(registry)
	var node := Node3D.new()
	add_child_autofree(node)
	var rock: WorldObject = registry.add(&"rock", Vector3.ZERO, node)
	node.global_position = Vector3(12.0, 3.0, -4.0)

	var snapshot: Dictionary = RegistrySnapshot.capture(registry)
	var restored: Node = REGISTRY.new()
	autofree(restored)
	RegistrySnapshot.restore(restored, snapshot)

	var back: WorldObject = restored.get_object(rock.id)
	assert_not_null(back)
	if back == null:
		return
	gut.p("spawned at %s, thrown to %s, saved at %s" % [
		Vector3.ZERO, node.global_position, back.position
	])
	assert_eq(back.position, Vector3(12.0, 3.0, -4.0), "the stale spawn point must not win")
	assert_null(back.node, "a live scene node cannot be rebuilt generically")

	var rows: Array = snapshot.get("objects", [])
	assert_eq(rows.size(), 1)
	var row: Dictionary = rows[0]
	assert_true(bool(row.get("had_node", false)),
		"the snapshot must flag which objects the caller has to rebuild nodes for")


func test_the_registry_participates_in_the_save_contract() -> void:
	var registry: Node = REGISTRY.new()
	autofree(registry)
	registry.add(&"tree", Vector3(3.0, 0.0, 3.0))
	registry.add(&"villager", Vector3(0.0, 1.0, 0.0))

	var writer := SaveManager.new()
	writer.register(RegistrySnapshot.new(registry))
	assert_eq(writer.save_to(SAVE_PATH), OK)

	var loaded: Node = REGISTRY.new()
	autofree(loaded)
	var reader := SaveManager.new()
	reader.register(RegistrySnapshot.new(loaded))
	assert_eq(reader.load_from(SAVE_PATH), OK)

	gut.p("registry restored %d of %d objects" % [loaded.count(), registry.count()])
	assert_eq(loaded.count(), registry.count())
	assert_eq(
		JSON.stringify(RegistrySnapshot.capture(loaded)),
		JSON.stringify(RegistrySnapshot.capture(registry)),
		"the world should come back identical through the save manager"
	)


func test_a_snapshot_with_no_registry_refuses_instead_of_crashing() -> void:
	# `RegistrySnapshot.new()` with the argument forgotten satisfies the contract
	# check — it has all three methods — and would otherwise take the whole save
	# down on the first write, a long way from the line that made the mistake.
	var manager := SaveManager.new()
	manager.register(RegistrySnapshot.new())

	var payload: Dictionary = manager.capture()
	var systems: Dictionary = payload.get("systems", {})
	gut.p("world slice from a registry-less snapshot: %s" % JSON.stringify(systems))
	assert_eq(systems.get("world", null), {}, "an empty slice, not a crash")
	assert_push_error("registry", "and the mistake should be shouted about")


func test_a_missing_save_is_not_treated_as_corruption() -> void:
	# A first run has no save file. That is normal, not an error worth shouting
	# about, and the caller decides what it means.
	var manager := SaveManager.new()
	manager.register(FakeSystem.new())
	var result: Error = manager.load_from("user://numen_no_such_save.json")
	gut.p("loading a save that does not exist: error %d, %s" % [result, manager.last_error()])
	assert_eq(result, ERR_FILE_NOT_FOUND)
