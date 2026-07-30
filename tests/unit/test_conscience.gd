extends GutTest
## The two advisory voices: their script, and their restraint.
##
## Two things are being defended here. One is the writing table — a topic with
## only one voice's opinion is a hole the player will find, and no line may
## contain a name we have no right to use. The other is the rate limiting, which
## matters more than the prose: a pair of voices that comment on everything is a
## pair of voices the player switches off in their head.
##
## Every clock in this file is advanced by hand. Nothing awaits a frame.

## Topics the table rates below the interrupt threshold, so they queue politely.
const LOW_TOPICS: Array[StringName] = [
	&"grabbed", &"threw", &"idle_nudge", &"petted", &"creature_slept",
]

## Names that must never appear in the writing. A legal constraint, so it gets an
## assertion rather than a promise.
const FORBIDDEN: Array[String] = ["black & white", "lionhead", "populous"]

var _voice: Conscience


func before_each() -> void:
	_voice = _make()


## A conscience with its own clock and nothing else. `_process` is off so that a
## frame slipping past between GUT's own awaits cannot nudge the timers under an
## assertion — `advance()` is the only thing that moves time in this file.
func _make(alignment: float = 0.0) -> Conscience:
	var conscience := Conscience.new()
	add_child_autofree(conscience)
	conscience.set_process(false)
	conscience.set_alignment(alignment)
	return conscience


func test_every_topic_has_lines_for_both_voices() -> void:
	var topics: Array[StringName] = ConscienceLines.topics()
	assert_gt(topics.size(), 10, "the table should cover what the game can observe")

	var total := 0
	for topic: StringName in topics:
		for voice: StringName in ConscienceLines.VOICES:
			var lines := ConscienceLines.lines_for(topic, voice)
			assert_gt(lines.size(), 1,
				"%s needs alternatives for the %s voice, or it repeats itself" % [topic, voice])
			for line: String in lines:
				assert_false(line.strip_edges().is_empty(),
					"empty line for %s / %s" % [topic, voice])
			total += lines.size()

	gut.p("%d topics, both voices, %d lines in all" % [topics.size(), total])


func test_no_line_borrows_a_name_we_do_not_own() -> void:
	var checked := 0
	for topic: StringName in ConscienceLines.topics():
		for voice: StringName in ConscienceLines.VOICES:
			for line: String in ConscienceLines.lines_for(topic, voice):
				var lowered := line.to_lower()
				for forbidden: String in FORBIDDEN:
					assert_false(lowered.contains(forbidden),
						"%s / %s uses '%s'" % [topic, voice, forbidden])
				checked += 1
	# Guards the loop itself: an empty table would otherwise pass in silence.
	assert_gt(checked, 0, "nothing was checked, so nothing was proved")
	gut.p("%d lines checked against %d forbidden names" % [checked, FORBIDDEN.size()])


func test_a_burst_of_events_in_one_instant_yields_at_most_one_remark() -> void:
	for i in 20:
		_voice.observe(LOW_TOPICS[i % LOW_TOPICS.size()])
	gut.p("20 events in the same instant produced %d remark(s)" % _voice.remark_count())
	assert_eq(_voice.remark_count(), 1, "the voices must not talk over an event storm")

	# The gap elapses and a fresh topic is heard from again.
	_voice.advance(_voice.minimum_gap + 0.5)
	_voice.observe(&"creature_ate_food")
	assert_eq(_voice.remark_count(), 2, "after the minimum gap a remark should be allowed")


func test_a_topic_cannot_repeat_until_its_cooldown_expires() -> void:
	_voice.observe(&"petted")
	assert_eq(_voice.remark_count(), 1)

	_voice.advance(_voice.minimum_gap + 1.0)
	assert_false(_voice.may_speak(&"petted"), "the same topic is still on cooldown")
	_voice.observe(&"petted")
	assert_eq(_voice.remark_count(), 1, "the same observation must not repeat back to back")

	assert_true(_voice.may_speak(&"slapped"), "a different topic is free to speak")
	_voice.observe(&"slapped")
	assert_eq(_voice.remark_count(), 2, "a different topic should still be allowed")


func test_alignment_biases_which_voice_speaks_without_silencing_the_other() -> void:
	var cruel_split: Dictionary = _draw_voices(-1.0, 400)
	var cruel_count := int(cruel_split[ConscienceLines.CRUEL])
	var merciful_count := int(cruel_split[ConscienceLines.MERCIFUL])
	gut.p("at alignment -1.00: cruel %d, merciful %d of 400" % [cruel_count, merciful_count])
	assert_gt(cruel_count, merciful_count * 2,
		"a cruel god should hear mostly from the cruel voice")
	assert_gt(merciful_count, 0,
		"the merciful voice must keep turning up — the disagreement is the point")

	var kind_split: Dictionary = _draw_voices(1.0, 400)
	var kind_merciful := int(kind_split[ConscienceLines.MERCIFUL])
	var kind_cruel := int(kind_split[ConscienceLines.CRUEL])
	gut.p("at alignment +1.00: merciful %d, cruel %d of 400" % [kind_merciful, kind_cruel])
	assert_gt(kind_merciful, kind_cruel * 2, "the bias must be signed, not merely lopsided")
	assert_gt(kind_cruel, 0, "the cruel voice must keep its objection")


## Counts who answers over `draws` remarks at a fixed alignment. The restraint is
## switched off rather than waited out — this test is about the weighting, and the
## gaps have their own tests.
func _draw_voices(alignment: float, draws: int) -> Dictionary:
	var conscience := _make(alignment)
	conscience.minimum_gap = 0.0
	conscience.topic_cooldown = 0.0
	var tally: Dictionary = {ConscienceLines.MERCIFUL: 0, ConscienceLines.CRUEL: 0}
	for i in draws:
		conscience.observe(&"threw")
		tally[conscience.last_voice()] = int(tally[conscience.last_voice()]) + 1
	assert_eq(conscience.remark_count(), draws, "every draw should have produced a remark")
	return tally


func test_an_important_event_interrupts_but_an_ordinary_one_waits() -> void:
	_voice.observe(&"petted")
	assert_eq(_voice.remark_count(), 1)

	_voice.observe(&"grabbed")
	assert_eq(_voice.remark_count(), 1, "picking up a rock must not interrupt anything")

	_voice.observe(&"village_converted")
	assert_eq(_voice.remark_count(), 2, "a village turning to you has to get through")

	var expected := ConscienceLines.lines_for(&"village_converted", _voice.last_voice())
	assert_true(expected.has(_voice.last_line()),
		"the remark that interrupted should be the converted village's, not the old line")
	gut.p("interrupting remark (%s): %s" % [_voice.last_voice(), _voice.last_line()])


func test_a_topic_the_voices_have_no_opinion_on_stays_silent_and_costs_nothing() -> void:
	_voice.observe(&"an_event_nobody_wrote_lines_for")
	assert_eq(_voice.remark_count(), 0, "an unknown topic should say nothing")
	# And must not have spent the rate limit on that silence.
	_voice.observe(&"threw")
	assert_eq(_voice.remark_count(), 1, "silence must not consume the gap")


func test_a_remark_fades_in_holds_and_leaves() -> void:
	assert_eq(_voice.text_alpha(), 0.0, "nothing is showing before anyone has spoken")
	_voice.observe(&"villager_born")

	_voice.advance(_voice.fade_time * 0.5)
	assert_almost_eq(_voice.text_alpha(), 0.5, 0.05, "should be halfway faded in")

	_voice.advance(_voice.fade_time * 0.5 + _voice.hold_time * 0.5)
	assert_almost_eq(_voice.text_alpha(), 1.0, 0.001, "should be fully up during the hold")

	_voice.advance(_voice.hold_time + _voice.fade_time * 2.0)
	assert_eq(_voice.text_alpha(), 0.0, "the line must clear the screen on its own")
	gut.p("envelope: %.1fs in, %.1fs held, %.1fs out"
		% [_voice.fade_time, _voice.hold_time, _voice.fade_time])


# --- Cross-module drift guards ------------------------------------------------

func test_every_miracle_the_game_has_maps_to_a_topic_with_lines() -> void:
	# The suite's other topic test iterates LINES' OWN keys, so it can never notice
	# the table's vocabulary drifting away from the game's. Renaming a miracle id
	# would leave the suite green and the advisors silent on every cast — which is
	# the failure mode this file's own docstring calls the one nobody notices.
	var library := MiracleLibrary.new()
	for id: StringName in library.ids():
		var topic: StringName = ConscienceLines.miracle_topic(id)
		for voice: StringName in ConscienceLines.VOICES:
			assert_gt(ConscienceLines.lines_for(topic, voice).size(), 0,
				"miracle '%s' resolves to topic '%s', which has no %s line" % [id, topic, voice])
	gut.p("%d miracles, all mapped to a topic with lines for both voices" % library.ids().size())


func test_an_unknown_miracle_falls_back_to_a_topic_that_has_lines() -> void:
	# A sixth miracle should get a generic remark rather than silence.
	var topic: StringName = ConscienceLines.miracle_topic(&"some_miracle_added_later")
	for voice: StringName in ConscienceLines.VOICES:
		assert_gt(ConscienceLines.lines_for(topic, voice).size(), 0,
			"the fallback topic '%s' has no %s line" % [topic, voice])


func test_the_costs_the_voices_quote_are_the_costs_the_game_charges() -> void:
	# Five lines spell prayer costs out in prose ("Eighteen prayers for planks").
	# Nothing else pins those numbers: test_miracles only asserts the costs are
	# distinct and positive. Retune lightning to 30 and the cruel voice carries on
	# saying forty, so the advisor starts lying about a mechanic — against this
	# module's whole purpose of telling the player something true.
	var library := MiracleLibrary.new()
	var quoted: Dictionary = {
		&"food": 12.0, &"wood": 18.0, &"water": 8.0, &"heal": 25.0, &"lightning": 40.0,
	}
	for id: StringName in quoted:
		var miracle: Miracle = library.by_id(id)
		assert_not_null(miracle, "no miracle '%s'" % id)
		if miracle == null:
			continue
		assert_eq(miracle.prayer_cost, float(quoted[id]),
			"the voices quote %s at %.0f prayers in words — retune the prose in "
			% [id, quoted[id]] + "src/ui/conscience_lines.gd to match")
