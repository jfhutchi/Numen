class_name PrayerPower
extends RefCounted
## The pool of divine power villagers pray into and miracles spend.
##
## Deliberately knows nothing about villages. Worshippers arrive as a plain int,
## so the village module and the tests feed it the same way and this stays a
## RefCounted with no scene, no tree and no autoload.

var maximum: float = 0.0
## Power earned per worshipper per second. Copied out of the tunables at
## construction so a caller can nudge one pool without editing the shared
## resource every other system reads.
var per_worshipper: float = 0.0

var _current: float = 0.0


func _init(tunables: MiracleTunables = null) -> void:
	var config: MiracleTunables = tunables if tunables != null else MiracleTunables.new()
	maximum = config.prayer_maximum
	per_worshipper = config.prayer_per_worshipper
	_current = clampf(config.prayer_initial, 0.0, maximum)


## Adds the power `worshipper_count` villagers earn over `delta` seconds.
##
## Negative counts and negative deltas are ignored rather than clamped into a
## drain: a paused or rewound clock, or a village reporting a transiently
## negative headcount, must never take power away from the player.
func accrue(worshipper_count: int, delta: float) -> void:
	if worshipper_count <= 0 or delta <= 0.0:
		return
	_current = minf(_current + float(worshipper_count) * per_worshipper * delta, maximum)


## Spends `amount`, or spends nothing and returns false.
##
## All-or-nothing on purpose. A partial spend would leave the caster having paid
## for a miracle it then has to refuse, and the pool must never go negative —
## a negative pool reads as "in debt to your own followers", which is not a
## mechanic this game has.
func spend(amount: float) -> bool:
	# A negative spend would top the pool up for free, so it is a refusal rather
	# than a gift. Reached by any miracle that ends up with a negative cost.
	if amount < 0.0:
		return false
	if amount > _current:
		return false
	_current = maxf(_current - amount, 0.0)
	return true


func current() -> float:
	return _current


## Sets the pool directly, for debug tooling and for tests that need a known
## starting balance. Clamped into range like everything else.
func set_current(value: float) -> void:
	_current = clampf(value, 0.0, maximum)


## How full the pool is, in [0,1]. The number a UI meter wants.
func fraction() -> float:
	return _current / maximum if maximum > 0.0 else 0.0


func to_dict() -> Dictionary:
	# Plain floats, so unlike the RNG state in mind.gd these survive JSON
	# unharmed — doubles hold a float32 pool exactly.
	return {"current": _current, "maximum": maximum, "per_worshipper": per_worshipper}


func from_dict(data: Dictionary) -> void:
	maximum = float(data.get("maximum", maximum))
	per_worshipper = float(data.get("per_worshipper", per_worshipper))
	_current = clampf(float(data.get("current", 0.0)), 0.0, maximum)
