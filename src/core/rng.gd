extends Node
## Seeded random number service. Autoloaded as `Rng`.
##
## All gameplay randomness routes through here so behavioural tests reproduce.
## Randomness is split into independently seeded named streams — `&"world"`,
## `&"ai"`, `&"vfx"` and so on.
##
## The stream split is the point. With one shared generator, drawing one extra
## number anywhere shifts every subsequent draw everywhere, so adding a particle
## effect would silently change what the creature decides. Per-stream seeds
## derived from the master seed keep the creature's sequence stable no matter
## what the rest of the game does.

## Emitted whenever the master seed changes, so systems holding cached values
## can re-derive them.
signal reseeded(new_seed: int)

var _master_seed: int = 0
var _streams: Dictionary[StringName, RandomNumberGenerator] = {}


func _ready() -> void:
	# A run with no explicit seed still gets a recorded one, so any session can
	# be replayed after the fact.
	if _master_seed == 0:
		set_master_seed(_random_nonzero_seed())
	# Logged once at boot, not inside set_master_seed, so headless test runs that
	# reseed constantly do not bury their own output.
	print("[rng] master seed: %d" % _master_seed)


## Sets the master seed and rebuilds every stream from it.
func set_master_seed(new_seed: int) -> void:
	_master_seed = new_seed
	_streams.clear()
	reseeded.emit(_master_seed)


func get_master_seed() -> int:
	return _master_seed


## Returns the generator for a named stream, creating it on first use.
func stream(stream_name: StringName) -> RandomNumberGenerator:
	var existing: RandomNumberGenerator = _streams.get(stream_name)
	if existing != null:
		return existing
	var generator := RandomNumberGenerator.new()
	generator.seed = derive_seed(stream_name)
	_streams[stream_name] = generator
	return generator


## Rewinds one stream to its starting state without disturbing the others.
func reset_stream(stream_name: StringName) -> void:
	_streams.erase(stream_name)


## Deterministic per-stream seed. Mixing the name into the string (rather than
## XOR-ing a raw hash) avoids the near-identical seeds that similarly named
## streams would otherwise get.
func derive_seed(stream_name: StringName) -> int:
	return hash("numen:%s:%d" % [stream_name, _master_seed])


func _random_nonzero_seed() -> int:
	var generator := RandomNumberGenerator.new()
	generator.randomize()
	var candidate: int = generator.randi()
	return candidate if candidate != 0 else 1
