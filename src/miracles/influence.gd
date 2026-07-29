class_name Influence
extends RefCounted
## The ring the player may act inside: where their god actually has reach.
##
## Radius is a pure function of belief, so there is one way for the ring to
## change size and nothing can nudge it behind belief's back.

var centre: Vector3 = Vector3.ZERO
var radius: float = 0.0

var _belief: float = 0.0
var _tunables: MiracleTunables


func _init(tunables: MiracleTunables = null, at: Vector3 = Vector3.ZERO) -> void:
	_tunables = tunables if tunables != null else MiracleTunables.new()
	centre = at
	set_belief(0.0)


## Whether a point lies inside the ring.
##
## Measured flat, in XZ, ignoring height. The ring is a circle painted on the
## ground and the island rises 24 m; measured in 3D, the top of a hill well
## inside the painted circle would refuse miracles, and the player would have no
## way to tell why. Height is not a dimension the player can see the ring in.
func contains(point: Vector3) -> bool:
	var dx: float = point.x - centre.x
	var dz: float = point.z - centre.z
	return dx * dx + dz * dz <= radius * radius


## Sets how strongly the world believes, in followers, and resizes the ring.
##
## Clamped at both ends: a god with no believers keeps a small ring to win them
## back with, and belief past the tunable ceiling stops buying radius so a large
## village cannot quietly swallow the whole island.
func set_belief(value: float) -> void:
	_belief = maxf(value, 0.0)
	var full: float = maxf(_tunables.influence_belief_full, 0.001)
	var t: float = clampf(_belief / full, 0.0, 1.0)
	radius = lerpf(_tunables.influence_min_radius, _tunables.influence_max_radius, t)


func belief() -> float:
	return _belief


func minimum_radius() -> float:
	return _tunables.influence_min_radius


func maximum_radius() -> float:
	return _tunables.influence_max_radius


func to_dict() -> Dictionary:
	return {
		"belief": _belief,
		"centre": [centre.x, centre.y, centre.z],
	}


func from_dict(data: Dictionary) -> void:
	var point: Array = data.get("centre", [0.0, 0.0, 0.0])
	if point.size() == 3:
		centre = Vector3(float(point[0]), float(point[1]), float(point[2]))
	# Radius is derived, never stored: saving it as well would let a hand-edited
	# save hold a ring that belief does not justify.
	set_belief(float(data.get("belief", 0.0)))
