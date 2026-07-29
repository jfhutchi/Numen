class_name Id3
extends RefCounted
## Decision-tree induction by information gain, over the creature's beliefs
## about an object, predicting the feedback it expects from acting on it.
##
## Two deliberate departures from textbook ID3, both in ADR-006 and §5.3 of the
## design doc:
##
## 1. Attributes are floats in [0,1], so each is bucketed into low/mid/high at
##    induction time rather than being categorical to begin with.
## 2. Leaves store the *mean feedback* of the examples that reach them, not a
##    class label. Splits are still chosen by information gain over discretised
##    feedback classes, but the creature needs a value to rank actions by, and
##    a bare "good"/"bad" label throws away the margin it needs to choose
##    between two good options.

const CLASS_BAD := 0
const CLASS_NEUTRAL := 1
const CLASS_GOOD := 2


## One (belief vector -> feedback) observation.
class Experience:
	extends RefCounted
	var attributes: PackedFloat32Array
	var feedback: float
	var weight: float

	func _init(attrs: PackedFloat32Array, value: float, w: float = 1.0) -> void:
		attributes = attrs
		feedback = value
		weight = w


class TreeNode:
	extends RefCounted
	## -1 on a leaf, otherwise the attribute index this node splits on.
	var attribute: int = -1
	## Child per bin: 0 low, 1 mid, 2 high. Empty on a leaf.
	var children: Array[TreeNode] = []
	## Mean feedback of the examples that reached here.
	var value: float = 0.0
	var sample_count: int = 0

	func is_leaf() -> bool:
		return attribute < 0


static func bin_of(value: float, low: float, high: float) -> int:
	if value < low:
		return 0
	if value < high:
		return 1
	return 2


static func class_of(feedback: float, threshold: float) -> int:
	if feedback < -threshold:
		return CLASS_BAD
	if feedback > threshold:
		return CLASS_GOOD
	return CLASS_NEUTRAL


## Induces a tree from experiences. `attribute_count` is the width of the belief
## vector; every attribute is a candidate at every level except those already
## used on the path down.
static func induce(
	experiences: Array, attribute_count: int, tunables: MindTunables
) -> TreeNode:
	var available: Array[int] = []
	for i in attribute_count:
		available.append(i)
	return _build(experiences, available, tunables, tunables.max_tree_depth)


## Expected feedback for a belief vector.
static func predict(root: TreeNode, attributes: PackedFloat32Array, tunables: MindTunables) -> float:
	var node: TreeNode = root
	while node != null and not node.is_leaf():
		var bin: int = bin_of(
			attributes[node.attribute] if node.attribute < attributes.size() else 0.5,
			tunables.bin_low,
			tunables.bin_high
		)
		var next: TreeNode = node.children[bin] if bin < node.children.size() else null
		if next == null or next.sample_count == 0:
			break
		node = next
	return node.value if node != null else 0.0


## The chain of decisions taken for a belief vector, for the Mind Inspector.
## Each entry is {attribute, bin, value, samples}.
static func decision_path(
	root: TreeNode, attributes: PackedFloat32Array, tunables: MindTunables
) -> Array[Dictionary]:
	var path: Array[Dictionary] = []
	var node: TreeNode = root
	while node != null and not node.is_leaf():
		var raw: float = attributes[node.attribute] if node.attribute < attributes.size() else 0.5
		var bin: int = bin_of(raw, tunables.bin_low, tunables.bin_high)
		path.append({
			"attribute": node.attribute,
			"bin": bin,
			"observed": raw,
			"samples": node.sample_count,
		})
		var next: TreeNode = node.children[bin] if bin < node.children.size() else null
		if next == null or next.sample_count == 0:
			break
		node = next
	if node != null:
		path.append({"leaf": true, "value": node.value, "samples": node.sample_count})
	return path


static func _build(
	experiences: Array, available: Array[int], tunables: MindTunables, depth: int
) -> TreeNode:
	var node := TreeNode.new()
	node.sample_count = experiences.size()
	node.value = _mean_feedback(experiences)

	if experiences.is_empty() or depth <= 0 or available.is_empty():
		return node
	if _is_pure(experiences, tunables):
		return node

	var best_attribute: int = -1
	var best_gain: float = 0.0
	var parent_entropy: float = _entropy(experiences, tunables)

	for attribute: int in available:
		var gain: float = parent_entropy - _split_entropy(experiences, attribute, tunables)
		if gain > best_gain:
			best_gain = gain
			best_attribute = attribute

	# No attribute separates these examples any further; stay a leaf and keep
	# the mean rather than splitting on noise.
	if best_attribute < 0:
		return node

	var buckets: Array = _partition(experiences, best_attribute, tunables)
	var remaining: Array[int] = available.duplicate()
	remaining.erase(best_attribute)

	node.attribute = best_attribute
	node.children = []
	for bucket: Array in buckets:
		if bucket.is_empty():
			# Keep an empty placeholder so bin indices stay aligned; predict()
			# falls back to this node's mean when it lands here.
			var empty := TreeNode.new()
			empty.value = node.value
			empty.sample_count = 0
			node.children.append(empty)
		else:
			node.children.append(_build(bucket, remaining, tunables, depth - 1))
	return node


static func _partition(experiences: Array, attribute: int, tunables: MindTunables) -> Array:
	var buckets: Array = [[], [], []]
	for experience: Experience in experiences:
		var raw: float = (
			experience.attributes[attribute] if attribute < experience.attributes.size() else 0.5
		)
		buckets[bin_of(raw, tunables.bin_low, tunables.bin_high)].append(experience)
	return buckets


static func _split_entropy(experiences: Array, attribute: int, tunables: MindTunables) -> float:
	var total: float = _total_weight(experiences)
	if total <= 0.0:
		return 0.0
	var weighted: float = 0.0
	for bucket: Array in _partition(experiences, attribute, tunables):
		if bucket.is_empty():
			continue
		weighted += (_total_weight(bucket) / total) * _entropy(bucket, tunables)
	return weighted


static func _entropy(experiences: Array, tunables: MindTunables) -> float:
	var total: float = _total_weight(experiences)
	if total <= 0.0:
		return 0.0
	var counts := PackedFloat32Array([0.0, 0.0, 0.0])
	for experience: Experience in experiences:
		counts[class_of(experience.feedback, tunables.feedback_class_threshold)] += experience.weight
	var entropy: float = 0.0
	for count: float in counts:
		if count > 0.0:
			var p: float = count / total
			entropy -= p * (log(p) / log(2.0))
	return entropy


static func _is_pure(experiences: Array, tunables: MindTunables) -> bool:
	if experiences.is_empty():
		return true
	var first: int = class_of(
		(experiences[0] as Experience).feedback, tunables.feedback_class_threshold
	)
	for experience: Experience in experiences:
		if class_of(experience.feedback, tunables.feedback_class_threshold) != first:
			return false
	return true


static func _mean_feedback(experiences: Array) -> float:
	var total: float = _total_weight(experiences)
	if total <= 0.0:
		return 0.0
	var sum: float = 0.0
	for experience: Experience in experiences:
		sum += experience.feedback * experience.weight
	return sum / total


static func _total_weight(experiences: Array) -> float:
	var total: float = 0.0
	for experience: Experience in experiences:
		total += experience.weight
	return total


## Serialises a tree. Recursive, and shallow by construction (depth is capped).
static func to_dict(node: TreeNode) -> Dictionary:
	if node == null:
		return {}
	var data: Dictionary = {
		"attribute": node.attribute, "value": node.value, "samples": node.sample_count
	}
	if not node.is_leaf():
		var children: Array = []
		for child: TreeNode in node.children:
			children.append(to_dict(child))
		data["children"] = children
	return data


static func from_dict(data: Dictionary) -> TreeNode:
	if data.is_empty():
		return null
	var node := TreeNode.new()
	node.attribute = int(data.get("attribute", -1))
	node.value = float(data.get("value", 0.0))
	node.sample_count = int(data.get("samples", 0))
	for child: Variant in data.get("children", []):
		node.children.append(from_dict(child))
	return node
