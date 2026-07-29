extends GutTest
## The reproducibility guarantee every behavioural test in this project rests on.

var _rng: Node


func before_each() -> void:
	# Deliberately not added to the tree: the service needs no tree for stream
	# derivation, and keeping it out avoids _ready's boot log on every test.
	_rng = load("res://src/core/rng.gd").new()
	autofree(_rng)
	_rng.set_master_seed(1234)


func test_same_seed_reproduces_the_same_sequence() -> void:
	var first: Array[float] = []
	for i in 10:
		first.append(_rng.stream(&"ai").randf())

	_rng.set_master_seed(1234)
	var second: Array[float] = []
	for i in 10:
		second.append(_rng.stream(&"ai").randf())

	assert_eq(first, second, "the same master seed must replay the same sequence")


func test_different_seeds_diverge() -> void:
	var first: float = _rng.stream(&"ai").randf()
	_rng.set_master_seed(4321)
	var second: float = _rng.stream(&"ai").randf()
	assert_ne(first, second, "a different master seed should produce different values")


func test_streams_are_independent_of_each_other() -> void:
	# The property that actually matters: drawing from one stream must not
	# perturb another. Without this, adding a particle effect would change what
	# the creature decides, and every behavioural test would be quietly fragile.
	var baseline: Array[float] = []
	for i in 5:
		baseline.append(_rng.stream(&"ai").randf())

	_rng.set_master_seed(1234)
	for i in 100:
		_rng.stream(&"vfx").randf()
	var after_vfx_traffic: Array[float] = []
	for i in 5:
		after_vfx_traffic.append(_rng.stream(&"ai").randf())

	assert_eq(baseline, after_vfx_traffic,
		"heavy traffic on one stream must not shift another stream's sequence")


func test_distinct_streams_produce_distinct_values() -> void:
	var ai: float = _rng.stream(&"ai").randf()
	var world: float = _rng.stream(&"world").randf()
	assert_ne(ai, world, "streams should be seeded apart, not aliased onto one sequence")


func test_similar_stream_names_get_unrelated_seeds() -> void:
	var a: int = _rng.derive_seed(&"villager_1")
	var b: int = _rng.derive_seed(&"villager_2")
	assert_ne(a, b, "adjacent stream names must not collide")
	assert_gt(absi(a - b), 1,
		"adjacent names should not yield adjacent seeds, which correlate early draws")


func test_reset_stream_rewinds_only_that_stream() -> void:
	var ai_first: float = _rng.stream(&"ai").randf()
	var world_first: float = _rng.stream(&"world").randf()

	_rng.reset_stream(&"ai")
	assert_eq(_rng.stream(&"ai").randf(), ai_first, "reset stream should replay from the start")
	assert_ne(_rng.stream(&"world").randf(), world_first, "other streams should keep advancing")
