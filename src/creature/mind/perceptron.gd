class_name Perceptron
extends RefCounted
## A single-layer perceptron: one desire's intensity from the creature's state.
##
## Trained with the delta rule against the feedback the creature receives, with
## a learning rate that decays as it ages — young creatures swing wildly on one
## bad experience, old ones barely budge.

var weights: PackedFloat32Array = PackedFloat32Array()
var bias: float = 0.0


func _init(input_count: int = 0, initial_weight: float = 0.0) -> void:
	if input_count > 0:
		weights.resize(input_count)
		weights.fill(initial_weight)


func size() -> int:
	return weights.size()


## Intensity in [0,1] for the given inputs.
func evaluate(inputs: PackedFloat32Array) -> float:
	var sum: float = bias
	var count: int = mini(inputs.size(), weights.size())
	for i in count:
		sum += inputs[i] * weights[i]
	return _sigmoid(sum)


## One delta-rule step toward `target`. Returns the signed error before the
## update, which is what the caller logs when it wants to see learning happen.
func learn(inputs: PackedFloat32Array, target: float, rate: float) -> float:
	var output: float = evaluate(inputs)
	var error: float = target - output
	# Sigmoid derivative, so updates shrink as the unit saturates rather than
	# oscillating across a confident output.
	var gradient: float = error * output * (1.0 - output)
	var count: int = mini(inputs.size(), weights.size())
	for i in count:
		weights[i] += rate * gradient * inputs[i]
	bias += rate * gradient
	return error


## Sets a weight directly. Used to give a newborn creature its instincts rather
## than making it discover hunger from scratch.
func set_weight(index: int, value: float) -> void:
	if index >= 0 and index < weights.size():
		weights[index] = value


func to_dict() -> Dictionary:
	return {"weights": Array(weights), "bias": bias}


func from_dict(data: Dictionary) -> void:
	var stored: Array = data.get("weights", [])
	weights = PackedFloat32Array()
	weights.resize(stored.size())
	for i in stored.size():
		weights[i] = float(stored[i])
	bias = float(data.get("bias", 0.0))


func _sigmoid(x: float) -> float:
	# Clamped because exp() overflows to inf on large negatives and the result
	# comes back as NaN, which then silently poisons every later decision.
	return 1.0 / (1.0 + exp(-clampf(x, -30.0, 30.0)))
