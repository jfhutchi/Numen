extends GutTest
## Acceptance tests for the two legibility surfaces: the on-screen gesture guide
## and the creature's floating thought.
##
## Both are UI and both are tested with no scene. The guide's rows and the
## thought's text, opinion and colour are plain state on plain methods; the
## Control's _draw() and the Label3D are skins over them.

const REGISTRY := preload("res://src/world/object_registry.gd")

const VILLAGER := &"villager"

var _world: Node


func before_each() -> void:
	# The bare registry, off the tree. The mind cannot tell the difference — that
	# seam is what makes any of this testable headless.
	_world = REGISTRY.new()


func after_each() -> void:
	if _world != null and is_instance_valid(_world):
		_world.free()
		_world = null


# --- the gesture guide --------------------------------------------------------

func test_guide_draws_a_real_stroke_for_every_template() -> void:
	var guide: GestureGuide = _guide()
	var templates: Dictionary = GestureTemplates.all()

	assert_eq(guide.entries().size(), templates.size(),
		"the guide must have a row for every template the recogniser knows")

	for gesture: StringName in templates:
		var entry: GestureGuide.Entry = guide.entry_for(gesture)
		assert_not_null(entry, "the guide has no row for template %s" % gesture)
		if entry == null:
			continue

		var source: PackedVector2Array = templates[gesture]
		var box: Rect2 = _bounds(entry.stroke)
		gut.p("%-8s %3d template points -> %3d drawn, box %.1f x %.1f at (%.1f, %.1f)" % [
			gesture, source.size(), entry.stroke.size(),
			box.size.x, box.size.y, box.position.x, box.position.y,
		])

		# A guide that silently draws nothing is worse than no guide: it looks
		# like the panel works.
		assert_gt(entry.stroke.size(), 2,
			"%s came out as %d points; that draws nothing" % [gesture, entry.stroke.size()])
		assert_eq(entry.stroke.size(), source.size(),
			"%s should keep every template point, not a hand-picked subset" % gesture)

		# Uniform normalisation means the longer side exactly fills the icon box
		# and neither side overflows it.
		assert_almost_eq(maxf(box.size.x, box.size.y), guide.icon_size, 0.01,
			"%s was not scaled into the icon box" % gesture)
		assert_lte(box.end.x, guide.icon_size + 0.01, "%s overflows the icon box" % gesture)
		assert_lte(box.end.y, guide.icon_size + 0.01, "%s overflows the icon box" % gesture)


func test_every_template_maps_to_a_miracle_the_library_knows() -> void:
	var guide: GestureGuide = _guide()
	var library := MiracleLibrary.new()

	for gesture: StringName in GestureTemplates.all():
		var miracle_id: StringName = GestureTemplates.miracle_for(gesture)
		var miracle: Miracle = library.by_id(miracle_id)
		assert_not_null(miracle,
			"template %s casts '%s', which the miracle library has never heard of" % [
				gesture, miracle_id
			])
		if miracle == null:
			continue

		var entry: GestureGuide.Entry = guide.entry_for(gesture)
		gut.p("%-8s -> %-9s '%s'  cost shown %.0f, library says %.0f" % [
			gesture, miracle.id, miracle.display_name, entry.cost, miracle.prayer_cost
		])
		assert_eq(entry.miracle_id, miracle.id)
		assert_eq(entry.display_name, miracle.display_name,
			"the guide's name for %s has drifted from the library's" % gesture)
		assert_almost_eq(entry.cost, miracle.prayer_cost, 0.001,
			"the guide's cost for %s has drifted from the library's" % gesture)


func test_affordability_flips_at_the_cost() -> void:
	var guide: GestureGuide = _guide()

	for entry: GestureGuide.Entry in guide.entries():
		guide.update_prayer(entry.cost - 0.01)
		var below: bool = entry.affordable
		guide.update_prayer(entry.cost)
		var exactly: bool = entry.affordable
		guide.update_prayer(entry.cost + 1.0)
		var above: bool = entry.affordable

		gut.p("%-8s cost %5.1f -> below: %s, exactly: %s, above: %s" % [
			entry.gesture, entry.cost, below, exactly, above
		])
		assert_false(below, "%s should be dimmed below its cost" % entry.gesture)
		# Exactly enough is enough: PrayerPower.spend() refuses only when the
		# cost is strictly greater than the pool.
		assert_true(exactly, "%s should be castable at exactly its cost" % entry.gesture)
		assert_true(above, "%s should be castable above its cost" % entry.gesture)


# --- the creature's thought ---------------------------------------------------

func test_thought_colours_a_punished_intention_differently() -> void:
	var villager: WorldObject = _world.add(VILLAGER, Vector3(0.0, 0.0, 5.0))

	var punished: CreatureMind = _taught_mind(villager, -1.0)
	var rewarded: CreatureMind = _taught_mind(villager, 1.0)
	var bad: CreatureThought = _thought(punished)
	var good: CreatureThought = _thought(rewarded)

	gut.p("punished creature: '%s'  opinion %+.2f  colour %s" % [
		bad.text().replace("\n", " / "), bad.opinion(), bad.colour()
	])
	gut.p("rewarded creature: '%s'  opinion %+.2f  colour %s" % [
		good.text().replace("\n", " / "), good.opinion(), good.colour()
	])

	assert_true(bad.showing(), "something is in reach, so there is a thought to show")
	assert_true(good.showing())
	assert_true(bad.text().contains(String(VILLAGER)),
		"the thought should name what the creature has fixed on, got '%s'" % bad.text())
	assert_eq(bad.label().text, bad.text(),
		"the billboard should carry what refresh() computed")

	assert_lt(bad.opinion(), 0.0, "the punished creature should expect this to go badly")
	assert_gt(good.opinion(), 0.0, "the rewarded one should expect it to go well")

	# The one visual that makes the whole feedback loop legible.
	assert_eq(bad.colour(), bad.negative_colour)
	assert_eq(good.colour(), good.positive_colour)
	assert_ne(bad.colour(), good.colour(),
		"a creature about to do something it was punished for must not look like "
		+ "one about to do something it was rewarded for")


func test_nothing_in_reach_shows_nothing_rather_than_stale_text() -> void:
	var villager: WorldObject = _world.add(VILLAGER, Vector3(0.0, 0.0, 5.0))
	var mind: CreatureMind = _taught_mind(villager, -1.0)
	var thought: CreatureThought = _thought(mind)
	assert_true(thought.showing(), "precondition: it had something to think about")

	# Two sub-interval steps, so only the fade moves and it reaches full opacity.
	thought.advance(0.1)
	thought.advance(0.1)
	assert_almost_eq(thought.alpha(), 1.0, 0.001, "a live thought should be fully opaque")

	# The villager is eaten, or wanders out of perception. Whatever the creature
	# was about to do is no longer a live intention.
	_world.remove(villager.id)
	assert_null(mind.choose(), "precondition: nothing left in reach")
	thought.refresh()

	gut.p("target gone: showing=%s text='%s' alpha=%.2f" % [
		thought.showing(), thought.text().replace("\n", " / "), thought.alpha()
	])
	assert_false(thought.showing(), "the indicator should report that it shows nothing")
	assert_eq(thought.text(), "", "stale text would get the creature slapped for nothing")

	thought.advance(0.1)
	thought.advance(0.1)
	gut.p("after fading: alpha=%.2f" % thought.alpha())
	assert_almost_eq(thought.alpha(), 0.0, 0.001, "it should have faded out, not blinked")


# --- helpers ------------------------------------------------------------------

func _guide() -> GestureGuide:
	var guide := GestureGuide.new()
	add_child_autofree(guide)
	return guide


func _thought(mind: CreatureMind) -> CreatureThought:
	var thought := CreatureThought.new()
	add_child_autofree(thought)
	thought.bind(mind)
	thought.refresh()
	return thought


## A mind that has learned one thing very firmly: acting on this object goes
## `value`, whatever the motive.
##
## Every action is taught, not just one, so whichever option the softmax happens
## to pick carries the opinion under test. Teaching under Hunger alone is enough
## for the other desires: OpinionStore pools an unseen (desire, action) pair
## across whatever it has learned about that action elsewhere.
func _taught_mind(object: WorldObject, value: float) -> CreatureMind:
	var mind := CreatureMind.new(null, 20260729)
	mind.bind_world(_world, Vector3.ZERO)
	mind.hunger = 0.95
	mind.beliefs.observe_truth(object)
	for action: StringName in OpinionStore.ALL_ACTIONS:
		mind.apply_intrinsic_feedback(Desires.HUNGER, action, object, value)
	assert_not_null(mind.choose(),
		"precondition: the mind must have something in reach to think about")
	return mind


func _bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var box := Rect2(points[0], Vector2.ZERO)
	for point: Vector2 in points:
		box = box.expand(point)
	return box
