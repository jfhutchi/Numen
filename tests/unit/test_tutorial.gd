extends GutTest
## The staged tutorial, driven entirely through notify(): no scene, no camera, no
## creature, no waiting on frames.
##
## The two bugs this file exists to catch are the ones that make a tutorial feel
## broken: a step that ticks itself off on an event it was not waiting for, and a
## step whose completion silently swallows the next one.

var _tutorial: Tutorial


func before_each() -> void:
	# Never added to the tree on purpose. The state machine has to run without the
	# panel, and off the tree _ready never fires, so nothing here builds a Control.
	_tutorial = autofree(Tutorial.new())


## The context that satisfies an event is the very dictionary the step demands of
## it, so the table is also the fixture.
func _satisfy(event: StringName, step: Dictionary) -> void:
	var events: Dictionary = step["events"]
	_tutorial.notify(event, events.get(event, {}))


## Fires every event the current step is waiting for, in table order.
func _complete_current() -> void:
	var step: Dictionary = _tutorial.current_step()
	for event: StringName in step["events"]:
		_satisfy(event, step)


func test_the_steps_run_in_order_on_their_own_events() -> void:
	var expected: Array[StringName] = [
		Tutorial.STEP_ORBIT,
		Tutorial.STEP_PAN,
		Tutorial.STEP_HAND,
		Tutorial.STEP_FIND,
		Tutorial.STEP_WATCH,
		Tutorial.STEP_TEACH,
		Tutorial.STEP_INSPECT,
		Tutorial.STEP_MIRACLE,
	]
	assert_eq(_tutorial.step_count(), expected.size(), "the table should hold every step")

	for i in expected.size():
		assert_eq(_tutorial.current_id(), expected[i], "step %d should be '%s'" % [i, expected[i]])
		var step: Dictionary = _tutorial.current_step()
		var events: PackedStringArray = []
		for event: StringName in step["events"]:
			events.append(String(event))
		gut.p("step %d/%d  %s  <- %s" % [
			i + 1, expected.size(), _tutorial.current_id(), ", ".join(events)
		])
		_complete_current()

	assert_true(_tutorial.is_finished(), "the last step should finish the tutorial")
	gut.p("finished after %d steps" % expected.size())


func test_an_unrelated_event_does_not_advance_the_step() -> void:
	# The bug that makes a tutorial feel broken: something else happens in the
	# world and the prompt jumps ahead of the player.
	for i in _tutorial.step_count():
		var step: Dictionary = _tutorial.current_step()
		var wanted: Dictionary = step["events"]
		var before: StringName = _tutorial.current_id()
		for event: StringName in Tutorial.ALL_EVENTS:
			if wanted.has(event):
				continue
			_tutorial.notify(event, {"source": "player"})
			assert_eq(_tutorial.current_id(), before,
				"'%s' should not touch step '%s'" % [event, before])
			assert_eq(_tutorial.step_progress().x, 0,
				"'%s' should not count toward step '%s'" % [event, before])
		gut.p("step '%s' ignored %d unrelated events" % [
			before, Tutorial.ALL_EVENTS.size() - wanted.size()
		])
		_complete_current()


func test_completing_a_step_advances_by_exactly_one() -> void:
	for i in _tutorial.step_count():
		var before: int = _tutorial.current_index()
		_complete_current()
		assert_eq(_tutorial.current_index(), before + 1,
			"completing step %d should advance to %d, never past it" % [before, before + 1])
		if not _tutorial.is_finished():
			assert_eq(_tutorial.step_progress().x, 0,
				"the new step should start with nothing satisfied")


func test_a_two_part_step_waits_for_both_parts() -> void:
	while _tutorial.current_id() != Tutorial.STEP_HAND:
		_complete_current()

	var step: Dictionary = _tutorial.current_step()
	_satisfy(Tutorial.EV_OBJECT_GRABBED, step)
	assert_eq(_tutorial.current_id(), Tutorial.STEP_HAND,
		"grabbing alone is not the lesson; the throw is the other half")
	assert_eq(_tutorial.step_progress(), Vector2i(1, 2), "one of two requirements met")

	# A repeat of the half already satisfied must not stand in for the other half.
	_satisfy(Tutorial.EV_OBJECT_GRABBED, step)
	assert_eq(_tutorial.current_id(), Tutorial.STEP_HAND, "grabbing twice is still one half")

	_satisfy(Tutorial.EV_OBJECT_THROWN, step)
	assert_eq(_tutorial.current_id(), Tutorial.STEP_FIND, "both halves should close the step")
	gut.p("hand step needed grab AND throw, closed at %s" % _tutorial.current_id())


func test_the_teaching_step_only_counts_feedback_the_player_gave() -> void:
	# The heart of the game, and the step most easily faked: the world hands out
	# consequences of its own, and one of those closing this step would rob the
	# player of the one lesson everything else rests on.
	while _tutorial.current_id() != Tutorial.STEP_TEACH:
		_complete_current()

	_tutorial.notify(Tutorial.EV_OPINION_CHANGED, {"source": "intrinsic", "value": -1.0})
	assert_eq(_tutorial.step_progress().x, 0, "the world's own feedback should not count")

	_tutorial.notify(Tutorial.EV_CREATURE_SLAPPED)
	assert_eq(_tutorial.current_id(), Tutorial.STEP_TEACH, "a slap that taught nothing is not it")

	_tutorial.notify(Tutorial.EV_OPINION_CHANGED, {"source": "player", "value": -0.8})
	assert_eq(_tutorial.current_id(), Tutorial.STEP_INSPECT,
		"a slap plus an opinion that actually moved should close the step")
	gut.p("teach step closed only on player feedback; now at %s" % _tutorial.current_id())


func test_skip_all_finishes_it_and_a_finished_tutorial_ignores_events() -> void:
	_tutorial.skip_all()
	assert_true(_tutorial.is_finished(), "skip_all should dismiss the guide")
	assert_eq(_tutorial.current_id(), &"", "a finished tutorial has no current step")
	assert_eq(_tutorial.current_prompt(), "", "and nothing to say")

	for event: StringName in Tutorial.ALL_EVENTS:
		_tutorial.notify(event, {"source": "player"})
	assert_true(_tutorial.is_finished(), "events after the end should change nothing")
	assert_eq(_tutorial.current_index(), _tutorial.step_count(), "and must not rewind it")


func test_skip_step_passes_only_the_steps_that_allow_it() -> void:
	assert_false(_tutorial.skip_step(), "the first step is not one to pass on")
	assert_eq(_tutorial.current_id(), Tutorial.STEP_ORBIT, "so nothing should have moved")

	while _tutorial.current_id() != Tutorial.STEP_WATCH:
		_complete_current()
	assert_true(_tutorial.skip_step(), "waiting on the creature is a step the player may pass")
	assert_eq(_tutorial.current_id(), Tutorial.STEP_TEACH, "and it advances by exactly one")


func test_progress_survives_a_save_and_resumes_where_it_stopped() -> void:
	for i in 3:
		_complete_current()
	# Half of a two-part step, to prove partial progress is kept too.
	while _tutorial.current_id() != Tutorial.STEP_TEACH:
		_complete_current()
	_tutorial.notify(Tutorial.EV_CREATURE_SLAPPED)

	# Through JSON, because that is what SaveManager actually writes: StringName
	# keys, bools and arrays all come back as something slightly different.
	var payload: Variant = JSON.parse_string(JSON.stringify(_tutorial.to_dict()))
	assert_eq(typeof(payload), TYPE_DICTIONARY, "the slice should survive JSON")

	var restored: Tutorial = autofree(Tutorial.new())
	assert_eq(restored.current_id(), Tutorial.STEP_ORBIT, "a fresh guide starts at the beginning")
	restored.from_dict(payload)

	assert_eq(restored.current_id(), _tutorial.current_id(),
		"a restored guide resumes on the step it stopped on, not at step one")
	assert_eq(restored.step_progress(), _tutorial.step_progress(),
		"including how much of that step was already done")
	assert_false(restored.is_finished(), "and it is not finished")
	gut.p("resumed at '%s' with %s of its requirements" % [
		restored.current_id(), restored.step_progress()
	])

	# And it carries on from there rather than needing the earlier steps again.
	restored.notify(Tutorial.EV_OPINION_CHANGED, {"source": "player", "value": -0.5})
	assert_eq(restored.current_id(), Tutorial.STEP_INSPECT, "a resumed step still completes")


func test_a_finished_tutorial_stays_finished_across_a_save() -> void:
	_tutorial.skip_all()
	var restored: Tutorial = autofree(Tutorial.new())
	restored.from_dict(_tutorial.to_dict())
	assert_true(restored.is_finished(), "a dismissed guide must not come back next launch")


func test_a_save_naming_a_step_this_build_lacks_starts_over() -> void:
	var restored: Tutorial = autofree(Tutorial.new())
	restored.from_dict({Tutorial.KEY_STEP: "ride_the_dragon", Tutorial.KEY_FINISHED: false})
	assert_eq(restored.current_id(), Tutorial.STEP_ORBIT,
		"an unknown step should restart, not drop the player into the middle")


func test_every_step_is_worded_and_reachable() -> void:
	var seen: Dictionary[StringName, StringName] = {}
	var ids: Dictionary[StringName, bool] = {}
	for step: Dictionary in Tutorial.step_data():
		var id: StringName = step["id"]
		assert_false(ids.has(id), "step id '%s' should appear once" % id)
		ids[id] = true
		assert_false(String(step["prompt"]).strip_edges().is_empty(),
			"step '%s' needs something to say" % id)
		assert_true(step.has("skippable"), "step '%s' must say whether it can be passed" % id)

		var events: Dictionary = step["events"]
		assert_gt(events.size(), 0, "step '%s' needs a way to be completed" % id)
		for event: StringName in events:
			assert_true(Tutorial.ALL_EVENTS.has(event),
				"step '%s' waits for '%s', which nothing reports" % [id, event])
			# Two steps sharing an event would make the order ambiguous, and the
			# second of them unreachable without the first firing twice.
			assert_false(seen.has(event),
				"'%s' is already awaited by step '%s'" % [event, seen.get(event, &"")])
			seen[event] = id

	# The other direction: an event constant no step listens for is a wire the
	# orchestrator would connect to nothing.
	for event: StringName in Tutorial.ALL_EVENTS:
		assert_true(seen.has(event), "no step ever waits for '%s'" % event)
	gut.p("%d steps, %d events, all wired" % [ids.size(), seen.size()])
