extends GutTest
## Belief spreading to a second village, and the player's own alignment.

const CONVERSION_SAVE_PATH := "user://numen_conversion_test.json"

var _conversion: Conversion
var _announced: Array[StringName] = []


func before_each() -> void:
	_conversion = Conversion.new()
	_announced.clear()
	_conversion.village_converted.connect(_on_village_converted)


func after_each() -> void:
	if FileAccess.file_exists(CONVERSION_SAVE_PATH):
		DirAccess.remove_absolute(CONVERSION_SAVE_PATH)


func _on_village_converted(village_id: StringName) -> void:
	_announced.append(village_id)


func test_belief_decays_without_attention() -> void:
	_conversion.register_village(&"north", Vector3.ZERO, 10)
	_conversion.add_belief(&"north", 20.0)

	gut.p("seconds | belief")
	gut.p("%7d | %6.3f" % [0, _conversion.belief_of(&"north")])
	for step in 3:
		_conversion.advance(30.0)
		gut.p("%7d | %6.3f" % [(step + 1) * 30, _conversion.belief_of(&"north")])

	assert_lt(_conversion.belief_of(&"north"), 20.0, "neglect has to cost something")
	# Three thirty-second steps is one ninety-second half-life.
	assert_almost_eq(_conversion.belief_of(&"north"), 10.0, 0.05,
		"belief should halve over exactly one half-life")


func test_decay_does_not_depend_on_how_often_it_is_ticked() -> void:
	# The regression guard for the decay maths. A linear `belief -= rate * delta`
	# passes the test above and still drifts with frame rate, so a village left
	# alone on a 30 fps machine would keep more faith than one on a 144 fps
	# machine, which is exactly the sort of bug nobody thinks to look for.
	var coarse := Conversion.new()
	var fine := Conversion.new()
	for tracker: Conversion in [coarse, fine]:
		tracker.register_village(&"north", Vector3.ZERO, 10)
		tracker.add_belief(&"north", 20.0)

	coarse.advance(90.0)
	for frame in 90:
		fine.advance(1.0)

	gut.p("one 90 s tick: %.6f     ninety 1 s ticks: %.6f" % [
		coarse.belief_of(&"north"), fine.belief_of(&"north")
	])
	assert_almost_eq(fine.belief_of(&"north"), coarse.belief_of(&"north"), 0.001,
		"decay must be frame-rate independent")


func test_a_large_village_takes_more_belief_than_a_small_one() -> void:
	_conversion.register_village(&"hamlet", Vector3.ZERO, 4)
	_conversion.register_village(&"town", Vector3(200.0, 0.0, 0.0), 40)

	var small: float = _conversion.threshold_for(&"hamlet")
	var large: float = _conversion.threshold_for(&"town")
	gut.p("threshold: hamlet (4 people) = %.1f, town (40 people) = %.1f" % [small, large])
	assert_gt(large, small, "a big village should be more work than a small one")

	_conversion.add_belief(&"hamlet", small)
	_conversion.add_belief(&"town", small)

	gut.p("after %.1f belief each: hamlet converted=%s, town converted=%s" % [
		small, _conversion.is_converted(&"hamlet"), _conversion.is_converted(&"town")
	])
	assert_true(_conversion.is_converted(&"hamlet"))
	assert_false(_conversion.is_converted(&"town"), "the same effort must not convert a town")
	assert_eq(_conversion.converted_count(), 1)


func test_sustained_belief_crosses_the_threshold_and_converts() -> void:
	var centre := Vector3(10.0, 0.0, 0.0)
	_conversion.register_village(&"north", centre, 12)
	gut.p("north (12 people) needs %.1f belief" % _conversion.threshold_for(&"north"))
	gut.p("miracle | belief | converted")

	for cast in 10:
		_conversion.record_act(centre, 4.0)
		# Ten seconds of neglect between miracles, so this measures sustained
		# effort beating the decay rather than one uninterrupted spectacle.
		_conversion.advance(10.0)
		gut.p("%7d | %6.3f | %s" % [
			cast + 1, _conversion.belief_of(&"north"), _conversion.is_converted(&"north")
		])

	assert_true(_conversion.is_converted(&"north"), "sustained effort should win a village")
	assert_eq(_conversion.converted_count(), 1)
	assert_eq(_announced.size(), 1, "conversion should be announced exactly once")
	assert_eq(_announced[0], &"north")


func test_a_second_village_can_be_converted_too() -> void:
	# The slice is not finished until a second village comes over. Two villages
	# far enough apart that neither is in earshot of the other's miracles, each
	# driven past its own threshold by sustained effort.
	var north := Vector3(20.0, 0.0, 0.0)
	var south := Vector3(-200.0, 0.0, 0.0)
	_conversion.register_village(&"north", north, 8)
	_conversion.register_village(&"south", south, 4)
	gut.p("north (8 people) needs %.1f belief, south (4 people) needs %.1f" % [
		_conversion.threshold_for(&"north"), _conversion.threshold_for(&"south")
	])

	gut.p("miracle | north | south | converted")
	for cast in 10:
		_conversion.record_act(north, 4.0)
		_conversion.record_act(south, 4.0)
		_conversion.advance(10.0)
		gut.p("%7d | %5.2f | %5.2f | %d" % [
			cast + 1,
			_conversion.belief_of(&"north"),
			_conversion.belief_of(&"south"),
			_conversion.converted_count(),
		])

	assert_true(_conversion.is_converted(&"north"))
	assert_true(_conversion.is_converted(&"south"))
	assert_eq(_conversion.converted_count(), 2, "a second village has to be winnable")
	assert_eq(_announced.size(), 2, "each village announces itself exactly once")
	assert_has(_announced, &"north")
	assert_has(_announced, &"south")


func test_one_spectacle_is_not_enough() -> void:
	var centre := Vector3(10.0, 0.0, 0.0)
	_conversion.register_village(&"north", centre, 12)
	_conversion.record_act(centre, 4.0)
	var peak: float = _conversion.belief_of(&"north")
	_conversion.advance(300.0)

	gut.p("one miracle: %.3f belief, then %.3f five minutes later (need %.1f)" % [
		peak, _conversion.belief_of(&"north"), _conversion.threshold_for(&"north")
	])
	assert_false(_conversion.is_converted(&"north"))
	assert_lt(_conversion.belief_of(&"north"), peak * 0.2,
		"a player who casts one miracle and wanders off should end up back where they started")


func test_conversion_survives_the_belief_bleeding_away() -> void:
	_conversion.register_village(&"north", Vector3.ZERO, 2)
	_conversion.add_belief(&"north", 100.0)
	assert_true(_conversion.is_converted(&"north"), "100 belief should convert a village of two")

	_conversion.advance(900.0)
	gut.p("after fifteen minutes of neglect: belief %.4f, still converted %s" % [
		_conversion.belief_of(&"north"), _conversion.is_converted(&"north")
	])
	assert_lt(_conversion.belief_of(&"north"), 1.0, "belief should have gone")
	assert_true(_conversion.is_converted(&"north"), "a converted village must not flicker back")
	assert_eq(_conversion.converted_count(), 1)
	assert_eq(_announced.size(), 1, "and must not be announced twice")


func test_only_villages_that_saw_the_act_are_impressed() -> void:
	_conversion.register_village(&"near", Vector3(5.0, 0.0, 0.0), 10)
	_conversion.register_village(&"middling", Vector3(30.0, 0.0, 0.0), 10)
	_conversion.register_village(&"far", Vector3(500.0, 0.0, 0.0), 10)

	var credited: float = _conversion.record_act(Vector3.ZERO, 10.0)
	gut.p("a magnitude-10 act at the origin credited %.3f: near(5m)=%.3f middling(30m)=%.3f far(500m)=%.3f" % [
		credited,
		_conversion.belief_of(&"near"),
		_conversion.belief_of(&"middling"),
		_conversion.belief_of(&"far"),
	])

	assert_gt(_conversion.belief_of(&"near"), _conversion.belief_of(&"middling"),
		"an act should impress more the closer it happens")
	assert_gt(_conversion.belief_of(&"middling"), 0.0)
	assert_eq(_conversion.belief_of(&"far"), 0.0, "a miracle nobody saw should impress nobody")
	assert_almost_eq(credited, _conversion.total_belief(), 0.0001,
		"the reported credit should be what was actually banked")


func test_cruelty_in_sight_of_a_village_costs_ground_but_cannot_go_negative() -> void:
	_conversion.register_village(&"north", Vector3.ZERO, 10)
	_conversion.add_belief(&"north", 5.0)
	_conversion.add_belief(&"north", -2.0)
	assert_almost_eq(_conversion.belief_of(&"north"), 3.0, 0.0001)

	_conversion.add_belief(&"north", -100.0)
	gut.p("belief after a debt of 100: %.3f" % _conversion.belief_of(&"north"))
	assert_eq(_conversion.belief_of(&"north"), 0.0,
		"a village must not bank a grudge that later kindness has to pay off invisibly")


func test_an_act_reports_the_ground_actually_lost_not_the_ground_intended() -> void:
	# Because belief floors at zero, a village holding one cannot lose ten. The
	# HUD reads what record_act returns, so reporting the intended share would
	# tell the player they had just squandered ground they never had.
	var centre := Vector3(3.0, 0.0, 0.0)
	_conversion.register_village(&"north", centre, 10)
	_conversion.add_belief(&"north", 1.0)

	var credited: float = _conversion.record_act(centre, -10.0)
	gut.p("a cruelty worth -10 in front of a village holding 1: reported %.3f, belief now %.3f" % [
		credited, _conversion.belief_of(&"north")
	])
	assert_eq(_conversion.belief_of(&"north"), 0.0, "belief still cannot go negative")
	assert_almost_eq(credited, -1.0, 0.0001,
		"only the belief that was there can actually be taken away")


func test_conversion_state_roundtrips_through_the_save_manager() -> void:
	_conversion.register_village(&"north", Vector3(10.0, 2.0, -3.0), 12)
	_conversion.register_village(&"south", Vector3(-40.0, 0.0, 8.0), 5)
	_conversion.add_belief(&"north", 30.0)
	_conversion.add_belief(&"south", 4.0)
	assert_true(_conversion.is_converted(&"north"))
	assert_false(_conversion.is_converted(&"south"))

	var writer := SaveManager.new()
	writer.register(_conversion)
	assert_eq(writer.save_to(CONVERSION_SAVE_PATH), OK)

	var loaded := Conversion.new()
	# Connected before the load, not after. The assertion at the bottom is about
	# the load staying quiet, and an instance nobody was listening to could not
	# have announced anything either way — the test would pass without testing.
	loaded.village_converted.connect(_on_village_converted)
	var reader := SaveManager.new()
	reader.register(loaded)
	assert_eq(reader.load_from(CONVERSION_SAVE_PATH), OK)

	gut.p("saved:  %s" % JSON.stringify(_conversion.to_dict()))
	gut.p("loaded: %s" % JSON.stringify(loaded.to_dict()))
	assert_eq(JSON.stringify(loaded.to_dict()), JSON.stringify(_conversion.to_dict()),
		"village belief must come back byte-identical")
	assert_true(loaded.is_converted(&"north"))
	assert_eq(loaded.converted_count(), 1)
	assert_almost_eq(loaded.threshold_for(&"north"), _conversion.threshold_for(&"north"), 0.0001,
		"population has to survive, or the threshold moves under the player")
	assert_eq(_announced.size(), 1,
		"restoring a converted village must not announce the same triumph again")


func test_sustained_cruelty_drives_alignment_negative() -> void:
	var tracker := AlignmentTracker.new()
	assert_eq(tracker.descriptor(), "neutral", "a player starts with nothing held against them")

	gut.p("acts | alignment | descriptor")
	gut.p("%4d | %9.4f | %s" % [0, tracker.value(), tracker.descriptor()])
	for block in 6:
		for act in 10:
			tracker.record(-1.0)
		gut.p("%4d | %9.4f | %s" % [(block + 1) * 10, tracker.value(), tracker.descriptor()])

	assert_lt(tracker.value(), -0.5, "sixty cruelties should read as clearly cruel")
	assert_eq(tracker.descriptor(), "cruel")

	for act in 200:
		tracker.record(1.0)
	gut.p("after 200 kindnesses: %.4f (%s)" % [tracker.value(), tracker.descriptor()])
	assert_gt(tracker.value(), 0.5, "a player has to be able to change")
	assert_eq(tracker.descriptor(), "merciful")


func test_alignment_stays_clamped_under_extreme_input() -> void:
	var tracker := AlignmentTracker.new()
	for act in 500:
		tracker.record(1000.0)
	gut.p("after 500 acts of valence 1000: %.9f" % tracker.value())
	assert_lte(tracker.value(), 1.0, "alignment must stay inside [-1,1]")

	for act in 500:
		tracker.record(-1000000000.0)
	gut.p("after 500 acts of valence -1e9: %.9f" % tracker.value())
	assert_gte(tracker.value(), -1.0)

	# A NaN would otherwise poison the average permanently: every later act
	# averages into NaN and the descriptor sticks for the rest of the session.
	var before: float = tracker.value()
	tracker.record(NAN)
	tracker.record(INF)
	gut.p("after a NaN and an INF: %.9f (was %.9f)" % [tracker.value(), before])
	assert_eq(tracker.value(), before, "a bad number must be dropped, not absorbed")
	assert_eq(tracker.sample_count(), 1000, "and must not count as an act")


func test_alignment_roundtrips_through_the_save_manager() -> void:
	# Through a real file rather than straight across a JSON string: the tracker
	# implements the save contract, and the contract is what the game depends on.
	var tracker := AlignmentTracker.new()
	for act in 20:
		tracker.record(-1.0)

	var writer := SaveManager.new()
	writer.register(tracker)
	assert_eq(writer.save_to(CONVERSION_SAVE_PATH), OK)

	var restored := AlignmentTracker.new()
	var reader := SaveManager.new()
	reader.register(restored)
	assert_eq(reader.load_from(CONVERSION_SAVE_PATH), OK)

	gut.p("alignment %.9f (%s) -> %.9f (%s)" % [
		tracker.value(), tracker.descriptor(), restored.value(), restored.descriptor()
	])
	assert_almost_eq(restored.value(), tracker.value(), 0.000001)
	assert_eq(restored.descriptor(), tracker.descriptor())
	assert_eq(restored.sample_count(), 20)
