extends GutTest
## Phase 4 acceptance tests for the two learning primitives.

const PERCEPTRON := preload("res://src/creature/mind/perceptron.gd")
const ID3 := preload("res://src/creature/mind/id3.gd")
const TUNABLES := preload("res://src/creature/mind/mind_tunables.gd")

var _tunables: MindTunables


func before_each() -> void:
	_tunables = TUNABLES.new()


# --- Perceptron ---------------------------------------------------------------

func test_perceptron_converges() -> void:
	# Acceptance test: a desire perceptron must learn a linearly separable
	# target. "Is the first input high?" stands in for "am I hungry?".
	var unit: Perceptron = PERCEPTRON.new(3, 0.0)
	var samples: Array = [
		[PackedFloat32Array([0.9, 0.2, 0.1]), 1.0],
		[PackedFloat32Array([0.8, 0.7, 0.3]), 1.0],
		[PackedFloat32Array([0.1, 0.3, 0.9]), 0.0],
		[PackedFloat32Array([0.2, 0.8, 0.4]), 0.0],
	]

	var final_error: float = 1.0
	for epoch in 4000:
		var worst: float = 0.0
		for sample: Array in samples:
			worst = maxf(worst, absf(unit.learn(sample[0], sample[1], 0.5)))
		final_error = worst
		if worst < 0.05:
			gut.p("converged after %d epochs (worst error %.4f)" % [epoch + 1, worst])
			break

	assert_lt(final_error, 0.05, "perceptron failed to converge on a separable target")
	assert_gt(unit.evaluate(PackedFloat32Array([0.95, 0.1, 0.1])), 0.8)
	assert_lt(unit.evaluate(PackedFloat32Array([0.05, 0.1, 0.9])), 0.2)


func test_perceptron_survives_extreme_inputs() -> void:
	# exp() overflows on large negatives and returns NaN, which would then
	# poison every downstream decision without ever raising an error.
	var unit: Perceptron = PERCEPTRON.new(2, 500.0)
	var output: float = unit.evaluate(PackedFloat32Array([-1000.0, 1000.0]))
	assert_false(is_nan(output), "sigmoid produced NaN")
	assert_between(output, 0.0, 1.0)


func test_perceptron_round_trips_through_a_dictionary() -> void:
	var unit: Perceptron = PERCEPTRON.new(4, 0.3)
	unit.learn(PackedFloat32Array([0.5, 0.2, 0.7, 0.1]), 1.0, 0.4)

	var restored: Perceptron = PERCEPTRON.new()
	restored.from_dict(unit.to_dict())

	var probe := PackedFloat32Array([0.3, 0.9, 0.2, 0.6])
	assert_almost_eq(restored.evaluate(probe), unit.evaluate(probe), 0.0001)


# --- ID3 ----------------------------------------------------------------------

func _experience(attrs: Array, feedback: float) -> Id3.Experience:
	return ID3.Experience.new(PackedFloat32Array(attrs), feedback)


func test_id3_learns_pattern() -> void:
	# Acceptance test. Attribute 0 decides the outcome; attributes 1 and 2 are
	# noise. The tree must key on 0 and classify a held-out example correctly.
	var experiences: Array = [
		_experience([0.9, 0.1, 0.5], 1.0),
		_experience([0.8, 0.9, 0.2], 1.0),
		_experience([0.95, 0.4, 0.8], 1.0),
		_experience([0.1, 0.2, 0.5], -1.0),
		_experience([0.05, 0.8, 0.1], -1.0),
		_experience([0.2, 0.5, 0.9], -1.0),
	]

	var tree: Id3.TreeNode = ID3.induce(experiences, 3, _tunables)
	assert_false(tree.is_leaf(), "tree should have found a split")
	assert_eq(tree.attribute, 0, "tree should split on the attribute that matters")

	# Held out: never seen these exact vectors.
	var high: float = ID3.predict(tree, PackedFloat32Array([0.85, 0.33, 0.66]), _tunables)
	var low: float = ID3.predict(tree, PackedFloat32Array([0.15, 0.77, 0.44]), _tunables)
	gut.p("held-out predictions: high=%.3f low=%.3f" % [high, low])

	# Signs and separation, not absolute magnitudes: leaf values are now shrunk
	# toward neutral by how little evidence they rest on (three examples per branch
	# carry half their face value), so a threshold of 0.5 was testing the shrinkage
	# constant rather than whether the tree had learned the pattern.
	assert_gt(high, 0.0, "high attribute-0 example should predict good feedback")
	assert_lt(low, 0.0, "low attribute-0 example should predict bad feedback")
	assert_gt(high - low, 0.5, "and the two should be clearly apart")


func test_id3_returns_a_leaf_when_nothing_separates_the_examples() -> void:
	# All the same outcome: splitting would be fitting noise.
	var experiences: Array = [
		_experience([0.9, 0.1, 0.5], 1.0),
		_experience([0.1, 0.9, 0.2], 1.0),
		_experience([0.5, 0.5, 0.8], 1.0),
	]
	var tree: Id3.TreeNode = ID3.induce(experiences, 3, _tunables)
	assert_true(tree.is_leaf())

	# Positive but not yet certain: three unanimous experiences are still only three.
	assert_gt(tree.value, 0.0, "three positive experiences should read positive")
	assert_lt(tree.value, 1.0, "but three of anything is not total conviction")

	# The claim worth testing is that conviction GROWS with evidence, which pins the
	# behaviour rather than the constant. Twelve of the same lesson must land nearer
	# its face value than three did.
	var many: Array = experiences.duplicate()
	for i in 9:
		many.append(_experience([0.4, 0.4, 0.4], 1.0))
	var confident: Id3.TreeNode = ID3.induce(many, 3, _tunables)
	gut.p("unanimous evidence: 3 examples read %.3f, 12 read %.3f" % [
		tree.value, confident.value
	])
	assert_gt(confident.value, tree.value, "more evidence should mean more conviction")
	assert_lt(confident.value, 1.001, "and never overshoot the evidence itself")


func test_id3_handles_no_experience_at_all() -> void:
	var tree: Id3.TreeNode = ID3.induce([], 3, _tunables)
	assert_true(tree.is_leaf())
	assert_eq(ID3.predict(tree, PackedFloat32Array([0.5, 0.5, 0.5]), _tunables), 0.0,
		"a creature with no experience should be neutral, not confident")


func test_id3_respects_the_depth_cap() -> void:
	_tunables.max_tree_depth = 2
	var experiences: Array = []
	for i in 16:
		experiences.append(_experience(
			[float(i & 1), float((i >> 1) & 1), float((i >> 2) & 1), float((i >> 3) & 1)],
			1.0 if (i & 1) == 1 else -1.0
		))
	var tree: Id3.TreeNode = ID3.induce(experiences, 4, _tunables)
	assert_lte(_depth_of(tree), 2, "tree grew past its depth cap")


func test_id3_weights_shift_the_prediction() -> void:
	# Learning by being shown is a weighted example; weight has to actually
	# count for something or the leash teaches nothing.
	var light: Array = [
		ID3.Experience.new(PackedFloat32Array([0.9]), 1.0, 1.0),
		ID3.Experience.new(PackedFloat32Array([0.9]), -1.0, 0.1),
	]
	var tree: Id3.TreeNode = ID3.induce(light, 1, _tunables)
	var predicted: float = ID3.predict(tree, PackedFloat32Array([0.9]), _tunables)
	gut.p("one +1 at weight 1.0 against one -1 at weight 0.1 reads %.3f" % predicted)
	# Positive is the whole claim: the heavy example wins the argument. The margin
	# is a function of the shrinkage constant, not of whether weighting works.
	assert_gt(predicted, 0.0, "the heavily weighted example should dominate")

	# And reversing the weights must reverse the verdict, which no absolute
	# threshold on one direction could establish.
	var flipped: Array = [
		ID3.Experience.new(PackedFloat32Array([0.9]), 1.0, 0.1),
		ID3.Experience.new(PackedFloat32Array([0.9]), -1.0, 1.0),
	]
	assert_lt(ID3.predict(ID3.induce(flipped, 1, _tunables), PackedFloat32Array([0.9]), _tunables),
		0.0, "swapping the weights should swap which lesson wins")


func test_decision_path_explains_the_prediction() -> void:
	# The Mind Inspector is only honest if the path really is the route taken.
	var experiences: Array = [
		_experience([0.9, 0.1], 1.0),
		_experience([0.8, 0.9], 1.0),
		_experience([0.1, 0.2], -1.0),
		_experience([0.05, 0.7], -1.0),
	]
	var tree: Id3.TreeNode = ID3.induce(experiences, 2, _tunables)
	var path: Array[Dictionary] = ID3.decision_path(tree, PackedFloat32Array([0.9, 0.5]), _tunables)

	assert_gt(path.size(), 1, "path should record at least one split and a leaf")
	assert_true(path[path.size() - 1].has("leaf"), "path should end at a leaf")
	assert_almost_eq(
		float(path[path.size() - 1]["value"]),
		ID3.predict(tree, PackedFloat32Array([0.9, 0.5]), _tunables),
		0.0001,
		"the path's leaf must be the value predict() actually returns"
	)


func test_tree_round_trips_through_a_dictionary() -> void:
	var experiences: Array = [
		_experience([0.9, 0.1], 1.0),
		_experience([0.1, 0.2], -1.0),
		_experience([0.85, 0.7], 1.0),
		_experience([0.2, 0.9], -1.0),
	]
	var tree: Id3.TreeNode = ID3.induce(experiences, 2, _tunables)
	var restored: Id3.TreeNode = ID3.from_dict(ID3.to_dict(tree))

	for probe: Array in [[0.9, 0.5], [0.1, 0.5], [0.5, 0.5]]:
		var vector := PackedFloat32Array(probe)
		assert_almost_eq(
			ID3.predict(restored, vector, _tunables),
			ID3.predict(tree, vector, _tunables),
			0.0001,
			"restored tree disagreed at %s" % [probe]
		)


func _depth_of(node: Id3.TreeNode) -> int:
	if node == null or node.is_leaf():
		return 0
	var deepest: int = 0
	for child: Id3.TreeNode in node.children:
		deepest = maxi(deepest, _depth_of(child))
	return deepest + 1
