class_name SaveManager
extends RefCounted
## Whole-game save and load: one JSON document under `user://`, assembled from
## every system that opts in.
##
## THE SAVE CONTRACT. A system participates by exposing three methods:
##
##     save_id() -> StringName        stable key for this system's slice
##     to_dict() -> Dictionary        everything it needs to come back
##     from_dict(data: Dictionary)    restore from exactly that
##
## Nothing else is required and no base class is involved, so a RefCounted mind,
## a Node registry and a plain helper can all be saved side by side.
## `register` checks for the three methods rather than for a type, and refuses
## anything lacking them — a system silently missing from the payload is data
## loss the player only discovers after reloading, by which point the state it
## was meant to hold is gone.
##
## Deliberately a plain RefCounted rather than an autoload. Tests need several
## independent managers in one process (a writer and a reader), which a
## singleton cannot give them.

## Payload format version. Bump when a system's dictionary layout changes in a
## way an older payload cannot satisfy.
const VERSION: int = 1

const KEY_VERSION := "version"
const KEY_SYSTEMS := "systems"

var _systems: Dictionary[StringName, Object] = {}
var _last_error: String = ""


## Adds a system to every subsequent save, under the id it names itself.
## Refuses anything that does not implement the contract.
func register(system: Object) -> void:
	if system == null:
		push_error("[save] refusing to register a null system")
		return
	if not system.has_method("save_id"):
		push_error(
			"[save] %s has no save_id(); it would be dropped from saves without a word"
			% [system]
		)
		return
	register_as(system.save_id(), system)


## Adds a system under an id supplied by the caller.
##
## For classes that predate the contract and expose only `to_dict`/`from_dict`:
## CreatureMind, Influence and PrayerPower are all in that position. Wrapping
## each in an adapter would be three files whose entire job is returning a
## constant, and editing three modules other people own to add one method each
## is not obviously better than letting the wiring name them.
func register_as(id: StringName, system: Object) -> void:
	if system == null:
		push_error("[save] refusing to register a null system as '%s'" % id)
		return
	for required: String in ["to_dict", "from_dict"]:
		if not system.has_method(required):
			push_error(
				"[save] %s has no %s(); it would be dropped from saves without a word"
				% [system, required]
			)
			return
	if _systems.has(id):
		push_error("[save] two systems both claim save id '%s'; the second would win" % id)
		return
	_systems[id] = system


## The whole game state as a dictionary, ready for JSON.
func capture() -> Dictionary:
	var systems: Dictionary = {}
	for id: StringName in _systems:
		# Keys as String, not StringName: JSON has one kind of key and round
		# tripping a StringName key back out of the parser gives a String
		# anyway, so storing one avoids two spellings of the same id.
		systems[String(id)] = _systems[id].to_dict()

	# Built by assignment rather than as a literal. A dictionary literal with a
	# bare constant for a key is the kind of thing that reads as obvious and is
	# worth nobody's afternoon to be wrong about.
	var payload: Dictionary = {}
	payload[KEY_VERSION] = VERSION
	payload[KEY_SYSTEMS] = systems
	return payload


## Pushes a captured dictionary back into the registered systems.
##
## All or nothing. A version this build cannot read is refused outright rather
## than applied best effort: a partial restore leaves half the game in the saved
## state and half in the running one, which is far harder to notice — and far
## harder to debug — than a load that plainly fails. When a format eventually
## does need migrating, that belongs in an explicit upgrade step run before this
## point, not in a pile of defaults scattered through every from_dict.
func restore(data: Dictionary) -> void:
	_last_error = ""
	var version: int = int(data.get(KEY_VERSION, -1))
	if version != VERSION:
		_last_error = "save format version %d, this build reads %d" % [version, VERSION]
		push_error("[save] refusing to load: %s" % _last_error)
		return

	var systems_value: Variant = data.get(KEY_SYSTEMS, {})
	if typeof(systems_value) != TYPE_DICTIONARY:
		_last_error = "payload has no '%s' object" % KEY_SYSTEMS
		push_error("[save] refusing to load: %s" % _last_error)
		return

	var systems: Dictionary = systems_value
	for id: String in systems:
		var system: Object = _systems.get(StringName(id))
		# A slice with no system registered is skipped rather than treated as an
		# error, so a save written by a build with one extra system still
		# restores everything this build does know about.
		if system == null:
			push_warning("[save] no system registered for '%s'; that slice is ignored" % id)
			continue
		var slice: Variant = systems[id]
		if typeof(slice) != TYPE_DICTIONARY:
			push_warning("[save] slice '%s' is not an object; ignored" % id)
			continue
		system.from_dict(slice)


## Writes the current state. Returns OK, or the error that stopped it.
func save_to(path: String) -> Error:
	_last_error = ""
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var open_error: Error = FileAccess.get_open_error()
		_last_error = "could not write %s (error %d)" % [path, open_error]
		push_error("[save] %s" % _last_error)
		return open_error
	# Indented on purpose. Saves are the first thing anyone reads when a reload
	# comes back wrong, and the whitespace costs nothing next to the tree data.
	#
	# Full precision on purpose too. The default writes only the reliable digits
	# of a float, which is fine for eyeballing and lossy for reloading: a belief
	# or an alignment comes back a hair off, and the same class of "nearly
	# identical" divergence the string-encoded ints below exist to prevent
	# creeps back in through the floats instead.
	file.store_string(JSON.stringify(capture(), "\t", true, true))
	file.close()
	return OK


## Reads a save back into the registered systems. Returns OK, or the error that
## stopped it, in which case nothing has been applied.
func load_from(path: String) -> Error:
	_last_error = ""
	if not FileAccess.file_exists(path):
		# Not shouted about: "no save yet" is the normal state of a first run,
		# and what that means is the caller's decision, not ours.
		_last_error = "no save at %s" % path
		return ERR_FILE_NOT_FOUND

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		var open_error: Error = FileAccess.get_open_error()
		_last_error = "could not read %s (error %d)" % [path, open_error]
		push_error("[save] %s" % _last_error)
		return open_error

	var text: String = file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_last_error = "%s is not a JSON object" % path
		push_error("[save] %s" % _last_error)
		return ERR_FILE_CORRUPT

	restore(parsed)
	return OK if _last_error.is_empty() else ERR_INVALID_DATA


## Why the last save or load failed, or "" if it did not.
func last_error() -> String:
	return _last_error


## 64-bit integers are stored as strings, and this is not decoration.
##
## JSON numbers come back from the parser as doubles, so anything past 2^53
## silently loses its low bits. That is exactly how a reloaded creature ended up
## resuming from a *nearly* identical RandomNumberGenerator and diverging within
## a decision or two: the file looked right, the numbers looked right, and the
## behaviour was wrong. Every RNG seed and state goes through these two.
static func int_to_json(value: int) -> String:
	return str(value)


## Reads back what `int_to_json` wrote.
static func int_from_json(value: Variant) -> int:
	match typeof(value):
		TYPE_STRING, TYPE_STRING_NAME:
			return String(value).to_int()
		TYPE_INT, TYPE_FLOAT:
			# Tolerated so a save written before this rule existed still loads,
			# with whatever precision it managed to keep. Deliberately not the
			# path anything new should take.
			return int(value)
	return 0
