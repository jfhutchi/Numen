class_name AlignmentTracker
extends RefCounted
## The player's alignment: an exponential moving average of the moral weight of
## what they have done, in [-1,1].
##
## Kept separate from CreatureMind.alignment on purpose. The creature's number is
## what it was rewarded for; this one is what the player did. A player who slaps
## their creature for every kindness should read as cruel while the creature
## reads as meek, and a single number could not say both.
##
## Participates in the save contract (see src/core/save_manager.gd).

## How far the average moves toward each new act.
##
## Low means a long memory: at 0.04 one atrocity barely registers, and it takes
## about seventeen acts of the same kind to cover half the distance to that
## extreme (ln 0.5 / ln 0.96). Raise it and alignment becomes twitchy and
## trivially gamed by whatever the player did last; lower it and they cannot
## tell their choices are landing at all.
##
## Matched to MindTunables.alignment_smoothing so the player and their creature
## drift at the same pace and the two HUD numbers stay comparable.
var smoothing: float = 0.04
## Magnitude at which `descriptor` stops saying "neutral".
var descriptor_threshold: float = 0.33

var _value: float = 0.0
var _samples: int = 0


## Records one act. `valence` is on the same scale the creature is taught on:
## +1 a clear kindness, -1 a clear cruelty, and anything between.
func record(valence: float) -> void:
	# Non-finite input is dropped rather than clamped. A NaN would poison the
	# average permanently — every later act averages into NaN and the descriptor
	# sticks for the rest of the session — and it always means a bug upstream,
	# never a genuinely infinite atrocity.
	if is_nan(valence) or is_inf(valence):
		return
	_value = lerpf(_value, clampf(valence, -1.0, 1.0), clampf(smoothing, 0.0, 1.0))
	# Clamped as well as bounded by construction. Interpolating toward a value
	# inside [-1,1] can never leave it in exact arithmetic, but float error
	# accumulated over a long session can, and a HUD reading "cruel" at
	# 1.0000001 would be a genuinely baffling afternoon.
	_value = clampf(_value, -1.0, 1.0)
	_samples += 1


func value() -> float:
	return _value


func sample_count() -> int:
	return _samples


## A word for the HUD. Three bands rather than a fine-grained ladder: the player
## needs to know which way they are drifting, and a descriptor that changed
## every few acts would say less, not more.
func descriptor() -> String:
	if _value > descriptor_threshold:
		return "merciful"
	if _value < -descriptor_threshold:
		return "cruel"
	return "neutral"


func save_id() -> StringName:
	return &"alignment"


func to_dict() -> Dictionary:
	return {"value": _value, "samples": _samples}


func from_dict(data: Dictionary) -> void:
	_value = clampf(float(data.get("value", 0.0)), -1.0, 1.0)
	_samples = int(data.get("samples", 0))
