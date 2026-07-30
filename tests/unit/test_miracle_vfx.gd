extends GutTest
## Acceptance tests for the miracle cast visuals.
##
## Casting a miracle is the signature action of the whole genre and it shipped
## with no visual at all. These tests hold the two promises that matter: every
## miracle in the library gets an effect (the drift guard — a sixth miracle
## cannot silently be invisible), and every effect frees itself (the leak guard
## — a cast per second for ten minutes must not accumulate nodes).
##
## Runs headless, where the dummy renderer may never simulate a particle. That
## is the point of the leak test: it proves the failsafe Timer path frees the
## node even when GPUParticles3D.finished never fires.

const VFX := preload("res://src/miracles/vfx/miracle_vfx.gd")

## Shrinks every lifetime so the self-free can be awaited in a fraction of a
## second instead of the seconds a real cast plays for.
const TEST_LIFETIME_SCALE := 0.05
## Slack on top of the failsafe for the queue_free frame to actually process.
const FREE_MARGIN_SECONDS := 0.3

## Two fixed seeds for the bolt determinism test. Any two distinct values work;
## fixed so the test is the same test every run.
const SEED_A := 111
const SEED_B := 222


func test_every_library_miracle_has_a_visual() -> void:
	# The drift guard. for_miracle must return a working effect for every id the
	# library knows, so adding a sixth miracle cannot leave it without a visual.
	var library := MiracleLibrary.new()
	for id: StringName in library.ids():
		var vfx: MiracleVfx = VFX.for_miracle(id)
		autofree(vfx)
		assert_not_null(vfx, "for_miracle must never return null (id: %s)" % id)
		vfx.build()
		var pieces: int = vfx.emitters().size() + vfx.bolt_segment_count()
		gut.p("%s: %d emitters, %d bolt segments" % [
			id, vfx.emitters().size(), vfx.bolt_segment_count()
		])
		assert_gt(pieces, 0, "the %s miracle built no visual at all" % id)


func test_an_unknown_id_gets_a_generic_effect() -> void:
	var vfx: MiracleVfx = VFX.for_miracle(&"earthquake")
	autofree(vfx)
	assert_not_null(vfx, "an unknown miracle gets a shimmer, not a crash")
	vfx.build()
	assert_gt(vfx.emitters().size(), 0, "the generic effect must actually emit something")


func test_every_emitter_is_one_shot() -> void:
	# A looping emitter never fires finished and never frees; one that slipped
	# through would leak a node per cast forever.
	var library := MiracleLibrary.new()
	var ids: Array[StringName] = library.ids()
	ids.append(&"earthquake")
	for id: StringName in ids:
		var vfx: MiracleVfx = VFX.for_miracle(id)
		autofree(vfx)
		vfx.build()
		for emitter: GPUParticles3D in vfx.emitters():
			assert_true(emitter.one_shot,
				"%s/%s must be one_shot or it loops forever" % [id, emitter.name])


func test_play_at_parents_positions_and_frees_itself() -> void:
	# The leak test. Must be able to fail: remove the failsafe and the finished
	# wiring and the node sits in the tree forever, and this times out red.
	var parent := Node3D.new()
	add_child_autofree(parent)
	var target := Vector3(3.0, 1.0, -2.0)

	var vfx: MiracleVfx = VFX.for_miracle(&"food")
	vfx.lifetime_scale = TEST_LIFETIME_SCALE
	vfx.build()
	var wait: float = vfx.failsafe_seconds() + FREE_MARGIN_SECONDS
	vfx.play_at(parent, target)

	assert_eq(vfx.get_parent(), parent, "play_at must parent under what it was handed")
	assert_lt(vfx.global_position.distance_to(target), 0.001,
		"play_at must place the effect at the cast point")

	gut.p("waiting %.2f s for the effect to free itself" % wait)
	await wait_seconds(wait)
	assert_false(is_instance_valid(vfx),
		"the effect must free itself; a cast a second must not accumulate nodes")
	assert_eq(parent.get_child_count(), 0, "nothing may be left behind under the parent")


func test_lightning_builds_a_bolt_of_four_to_seven_segments() -> void:
	var vfx: MiracleVfx = VFX.for_miracle(&"lightning")
	autofree(vfx)
	vfx.bolt_seed = SEED_A
	vfx.build()
	gut.p("bolt built %d segments" % vfx.bolt_segment_count())
	assert_between(vfx.bolt_segment_count(), 4, 7,
		"a bolt is 4-7 stacked segments; fewer is a stub, more is a pole")


func test_same_seed_builds_the_same_bolt() -> void:
	# The bolt is the one runtime-random construction here, so its determinism
	# gets its own proof: same seed, same segment count, same transforms.
	var first: MiracleVfx = VFX.for_miracle(&"lightning")
	autofree(first)
	first.bolt_seed = SEED_A
	first.build()

	var second: MiracleVfx = VFX.for_miracle(&"lightning")
	autofree(second)
	second.bolt_seed = SEED_A
	second.build()

	assert_eq(first.bolt_segment_count(), second.bolt_segment_count(),
		"same seed must build the same number of segments")
	assert_eq(first.bolt_transforms(), second.bolt_transforms(),
		"same seed must place every segment identically")

	var other: MiracleVfx = VFX.for_miracle(&"lightning")
	autofree(other)
	other.bolt_seed = SEED_B
	other.build()
	assert_ne(first.bolt_transforms(), other.bolt_transforms(),
		"a different seed must build a different bolt, or the RNG is decorative")


func test_the_scorch_outlives_the_bolt_fade() -> void:
	# Load-bearing constant relationship: the node frees when its last emitter
	# finishes, and the scorch is lightning's only emitter — if it ended before
	# the bolt's fade tween, the node would free itself mid-fade and truncate
	# the flash. A retune below the fade time must go red here, not in play.
	assert_true(VFX.SCORCH_LIFETIME >= VFX.BOLT_FADE_SECONDS,
		"the scorch emitter must hold the node alive through the bolt fade")
