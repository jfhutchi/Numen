class_name Tutorial
extends Control
## The staged first-steps guide: one line at a time, and it only moves on once
## the player has actually done the thing.
##
## Every step waits on a real action — the camera yawing, the hand letting go of
## a rock, an opinion inside the creature's mind actually shifting. Nothing here
## can be clicked through, because a guide you dismiss with Next only teaches
## the player to press Next. The deepest system in the game is the one nobody
## finds, so the middle of this sequence points straight at it: catch the
## creature doing something you hate, punish it while the act is fresh, and see
## its opinion move.
##
## `notify(event, context)` is the only way in. The game reports what happened;
## the tutorial alone decides what it means. That keeps the state machine
## drivable with no scene, no camera and no creature — see
## tests/unit/test_tutorial.gd, which walks the whole progression through
## `notify()` and nothing else. The panel is a skin that reads `current_prompt()`.

## Fired as each step is satisfied, with the id of the step that just closed.
signal step_completed(id: StringName)
## Fired once, when the last step closes or the player dismisses the guide.
signal finished()

## Events the game reports. Constants rather than bare strings so the wiring
## cannot misspell one: a notify() with a typo is a step that never completes and
## nothing, anywhere, would say a word about it.
const EV_CAMERA_ORBITED := &"camera_orbited"
const EV_CAMERA_PANNED := &"camera_panned"
const EV_OBJECT_GRABBED := &"object_grabbed"
const EV_OBJECT_THROWN := &"object_thrown"
const EV_CREATURE_FOUND := &"creature_found"
const EV_CREATURE_CHOSE := &"creature_chose"
const EV_CREATURE_SLAPPED := &"creature_slapped"
const EV_OPINION_CHANGED := &"opinion_changed"
const EV_INSPECTOR_OPENED := &"inspector_opened"
const EV_MIRACLE_CAST := &"miracle_cast"

## Every event any step waits for. Tested against the step table, so a step
## listening for something no constant names is caught rather than shipped.
const ALL_EVENTS: Array[StringName] = [
	EV_CAMERA_ORBITED,
	EV_CAMERA_PANNED,
	EV_OBJECT_GRABBED,
	EV_OBJECT_THROWN,
	EV_CREATURE_FOUND,
	EV_CREATURE_CHOSE,
	EV_CREATURE_SLAPPED,
	EV_OPINION_CHANGED,
	EV_INSPECTOR_OPENED,
	EV_MIRACLE_CAST,
]

## Step ids. Also the save keys — progress is stored by id, not by index, so
## inserting a step does not teleport a returning player somewhere else.
const STEP_ORBIT := &"orbit"
const STEP_PAN := &"pan"
const STEP_HAND := &"hand"
const STEP_FIND := &"find"
const STEP_WATCH := &"watch"
const STEP_TEACH := &"teach"
const STEP_INSPECT := &"inspect"
const STEP_MIRACLE := &"miracle"

const KEY_STEP := "step"
const KEY_SATISFIED := "satisfied"
const KEY_FINISHED := "finished"

## Pixels of right-drag that count as having looked around. Enough that a stray
## right-click with a twitch of the mouse does not tick the step off.
@export var orbit_pixels: float = 140.0
## Seconds of held pan input that count as having panned.
@export var pan_seconds: float = 0.5
@export var panel_width: float = 430.0

var _steps: Array[Dictionary] = []
var _index: int = 0
## Which of the current step's required events have arrived. Cleared on every
## advance, so nothing carries over into the next step.
var _satisfied: Dictionary[StringName, bool] = {}
var _done: bool = false

var _rig: Node = null
var _orbit_seen: float = 0.0
var _pan_seen: float = 0.0

var _heading: Label
var _prompt: Label
var _hint: Label


## The steps, in order, as data. A step is its id, one imperative line of copy,
## the events that close it, and whether the player may pass on it.
##
## `events` maps an event to the context it must carry. An empty dictionary means
## any occurrence will do; named keys must match, and extra keys the game happens
## to report are ignored. All of a step's events are required, in any order.
##
## Static so the table can be inspected — and asserted on — without a Tutorial,
## a scene or a game.
static func step_data() -> Array[Dictionary]:
	return [
		{
			"id": STEP_ORBIT,
			"prompt": "Hold the right mouse button and drag. Look around your island.",
			"events": {EV_CAMERA_ORBITED: {}},
			"skippable": false,
		},
		{
			"id": STEP_PAN,
			"prompt": "Now travel: hold W, A, S or D to move over the land.",
			"events": {EV_CAMERA_PANNED: {}},
			"skippable": false,
		},
		{
			"id": STEP_HAND,
			"prompt": "Your hand is the left mouse button. Take hold of something, "
				+ "carry it, and fling it.",
			"events": {EV_OBJECT_GRABBED: {}, EV_OBJECT_THROWN: {}},
			"skippable": false,
		},
		{
			"id": STEP_FIND,
			"prompt": "Press F. That animal is yours, and it is the only thing here that learns.",
			"events": {EV_CREATURE_FOUND: {}},
			"skippable": false,
		},
		{
			"id": STEP_WATCH,
			"prompt": "Leave it alone and watch. Wait until it decides something for itself.",
			"events": {EV_CREATURE_CHOSE: {}},
			"skippable": true,
		},
		{
			# The whole game, in one step. Feedback only lands on what the creature
			# did in the last few seconds, so the second half of this cannot be
			# faked: an opinion has to actually move.
			"id": STEP_TEACH,
			"prompt": "Catch it doing something you hate — eating one of your people — "
				+ "and slap it with L while the act is fresh. Late blame teaches nothing.",
			"events": {
				EV_CREATURE_SLAPPED: {},
				# Only feedback the player gave. The world hands out consequences of
				# its own all day, and one of those closing this step would rob the
				# player of the single lesson the game is built on.
				EV_OPINION_CHANGED: {"source": "player"},
			},
			"skippable": true,
		},
		{
			"id": STEP_INSPECT,
			"prompt": "Press Tab. That panel is its mind — read the path it took to its choice.",
			"events": {EV_INSPECTOR_OPENED: {}},
			"skippable": false,
		},
		{
			"id": STEP_MIRACLE,
			"prompt": "Drag a shape with the middle mouse button — a spiral, a bolt — "
				+ "and spend your belief on a miracle.",
			"events": {EV_MIRACLE_CAST: {}},
			"skippable": false,
		},
	]


## Built here rather than in the member initialiser so a bare `Tutorial.new()`,
## with no tree and no _ready, already has its steps.
func _init() -> void:
	_steps = step_data()


func _ready() -> void:
	# The guide sits over the world and must never eat a click meant for the hand.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_refresh()


# --- the state machine --------------------------------------------------------

## The game reporting that something happened. Advances the current step only if
## this is one of the events that step is waiting for.
func notify(event: StringName, context: Dictionary = {}) -> void:
	if _done or event == &"":
		return
	var step: Dictionary = current_step()
	if step.is_empty():
		return

	var events: Dictionary = step["events"]
	# The wrong event moves nothing at all. This is the entire reason notify() is
	# the only door in: a step closes on its own condition or it does not close.
	if not events.has(event) or _satisfied.has(event):
		return
	if not _matches(context, events[event]):
		return

	_satisfied[event] = true
	if _satisfied.size() < events.size():
		_refresh()
		return
	_close_step()


## Passes on the current step, if it is one the player is allowed to pass on.
## Returns whether it moved.
func skip_step() -> bool:
	if _done:
		return false
	var step: Dictionary = current_step()
	if step.is_empty() or not bool(step["skippable"]):
		return false
	_close_step()
	return true


## Dismisses the guide for good.
func skip_all() -> void:
	if not _done:
		_finish()


func is_finished() -> bool:
	return _done


func current_index() -> int:
	return _index


func step_count() -> int:
	return _steps.size()


## The current step, or an empty dictionary when there is none left.
func current_step() -> Dictionary:
	if _done or _index < 0 or _index >= _steps.size():
		return {}
	return _steps[_index]


func current_id() -> StringName:
	var step: Dictionary = current_step()
	return step["id"] if not step.is_empty() else &""


func current_prompt() -> String:
	var step: Dictionary = current_step()
	return step["prompt"] if not step.is_empty() else ""


## How many of the current step's requirements have arrived, and how many there
## are. Useful to a caller showing progress, and to a test proving a step that
## needs two events does not close on one.
func step_progress() -> Vector2i:
	var step: Dictionary = current_step()
	if step.is_empty():
		return Vector2i.ZERO
	var events: Dictionary = step["events"]
	return Vector2i(_satisfied.size(), events.size())


## Closes the current step and moves on by exactly one.
func _close_step() -> void:
	var id: StringName = current_id()
	_index += 1
	# The event that closed this step is deliberately NOT offered to the next one:
	# clearing here, and returning to the caller without re-testing, is what stops
	# a single notify() marching the player through two steps.
	_satisfied.clear()
	_orbit_seen = 0.0
	_pan_seen = 0.0
	step_completed.emit(id)
	if _index >= _steps.size():
		_finish()
	else:
		_refresh()


func _finish() -> void:
	_done = true
	_index = _steps.size()
	_satisfied.clear()
	visible = false
	set_process(false)
	finished.emit()


## True when `context` carries everything the step demands of this event. Only
## the named keys are checked; the game is free to report more detail than the
## step cares about.
static func _matches(context: Dictionary, expected: Dictionary) -> bool:
	for key: String in expected:
		if context.get(key) != expected[key]:
			return false
	return true


func _index_of(id: StringName) -> int:
	for i in _steps.size():
		if _steps[i]["id"] == id:
			return i
	# An id this build does not know: start again rather than guess. Repeating the
	# first steps is a small annoyance; being dropped into step six with no idea
	# what the last five said is not.
	return 0


# --- save contract ------------------------------------------------------------

func save_id() -> StringName:
	return &"tutorial"


func to_dict() -> Dictionary:
	var satisfied: Array[String] = []
	for event: StringName in _satisfied:
		satisfied.append(String(event))
	var data: Dictionary = {}
	# By id, not index: see STEP_ORBIT above.
	data[KEY_STEP] = String(current_id())
	data[KEY_SATISFIED] = satisfied
	data[KEY_FINISHED] = _done
	return data


func from_dict(data: Dictionary) -> void:
	_satisfied.clear()
	_orbit_seen = 0.0
	_pan_seen = 0.0
	if bool(data.get(KEY_FINISHED, false)):
		_finish()
		return

	_done = false
	visible = true
	set_process(true)
	_index = _index_of(StringName(str(data.get(KEY_STEP, ""))))

	var step: Dictionary = current_step()
	var events: Dictionary = step["events"] if not step.is_empty() else {}
	# A save file is a trust boundary: a field of the wrong type is ignored rather
	# than assigned into a typed local, which would fail the whole restore.
	var stored_value: Variant = data.get(KEY_SATISFIED, [])
	var stored: Array = stored_value if typeof(stored_value) == TYPE_ARRAY else []
	for value: Variant in stored:
		var event := StringName(str(value))
		# Anything the current step does not ask for is dropped. A leftover from an
		# older step table would otherwise sit in the set and close a step early.
		if events.has(event):
			_satisfied[event] = true
	if not events.is_empty() and _satisfied.size() >= events.size():
		# Fully satisfied when it was saved but not yet closed — close it now, or it
		# waits forever on an event that has already been and gone.
		_close_step()
	_refresh()


# --- the two steps with no signal to listen to --------------------------------

## Binds the camera rig, whose `pan_input()` the pan step reads. Orbiting and
## panning are the only steps with nothing to connect to: the rig emits no
## signals, so the guide watches the input itself.
func bind_camera_rig(rig: Node) -> void:
	if rig != null and not rig.has_method("pan_input"):
		push_error("[tutorial] %s has no pan_input(); the pan step will not detect panning" % rig)
		return
	_rig = rig


func _process(delta: float) -> void:
	if _done or _rig == null or current_id() != STEP_PAN:
		return
	var move: Vector2 = _rig.pan_input()
	if move == Vector2.ZERO:
		# Reset rather than accumulate, so single taps on the way past somewhere
		# else do not silently add up to a completed step.
		_pan_seen = 0.0
		return
	_pan_seen += delta
	if _pan_seen >= pan_seconds:
		notify(EV_CAMERA_PANNED)


func _unhandled_input(event: InputEvent) -> void:
	if _done:
		return

	if event is InputEventMouseMotion:
		if current_id() != STEP_ORBIT:
			return
		var motion := event as InputEventMouseMotion
		if (motion.button_mask & MOUSE_BUTTON_MASK_RIGHT) == 0:
			return
		# Horizontal only: dragging up and down is pitch, and the step asks the
		# player to swing the view around the island.
		_orbit_seen += absf(motion.relative.x)
		if _orbit_seen >= orbit_pixels:
			notify(EV_CAMERA_ORBITED)
		return

	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo or key.keycode != KEY_ESCAPE:
			return
		if key.shift_pressed:
			skip_all()
		else:
			skip_step()


# --- the skin -----------------------------------------------------------------

func _build() -> void:
	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size = Vector2(panel_width, 0.0)
	add_child(panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	_heading = Label.new()
	_heading.add_theme_font_size_override("font_size", 13)
	_heading.add_theme_color_override("font_color", Color(0.62, 0.78, 0.95))
	box.add_child(_heading)

	_prompt = _line(14, Color(0.94, 0.94, 0.92))
	box.add_child(_prompt)

	_hint = _line(11, Color(0.62, 0.62, 0.60))
	box.add_child(_hint)


func _line(size: int, colour: Color) -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(panel_width - 24.0, 0.0)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	return label


func _refresh() -> void:
	# Null off the tree: the state machine runs in tests with no UI at all.
	if _prompt == null or _done:
		return
	var step: Dictionary = current_step()
	if step.is_empty():
		return

	_heading.text = "FIRST STEPS   %d / %d" % [_index + 1, _steps.size()]
	_prompt.text = current_prompt()

	var hints: PackedStringArray = []
	var progress: Vector2i = step_progress()
	if progress.y > 1:
		hints.append("%d of %d done" % [progress.x, progress.y])
	if bool(step["skippable"]):
		hints.append("Esc: pass on this")
	hints.append("Shift+Esc: dismiss the guide")
	_hint.text = "     ".join(hints)
