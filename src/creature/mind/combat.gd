class_name CreatureCombat
extends RefCounted
## Resolves a fight between two creatures as a series of exchanges.
##
## A resolver, not a behaviour: given two combatants it advances the exchange
## and reports what happened, with no scene, clock or world of its own — the
## same seam discipline as CreatureMind itself (ADR-003), which is what lets
## two differently-taught minds be pitted against each other in a loop and the
## better-taught one *measured* to win.
##
## A combatant is duck-typed: anything whose `mind` property is a CreatureMind
## and whose `object` property is its WorldObject in the registry. `object` may
## be absent — the fight still runs — but neither side can then form a belief
## about the other, so neither learns anything from it.
##
## There is deliberately no stat block. How hard a creature hits is what it has
## been taught: its learned opinion of attacking this opponent sets its
## willingness, its current Anger intensity sets its commitment, and every
## exchange feeds back into the mind through the same intrinsic-feedback path
## the rest of the world uses. A creature rewarded for attacking presses the
## attack; one punished for it holds back; and both walk out changed by the
## fight. The fight is an expression of upbringing, which is the whole point.

const ANGER := &"Anger"
const ATTACK := &"attack"

## Tunables. Plain vars rather than @export on purpose: @export needs a Node or
## a Resource to mean anything, this class is RefCounted, and its owner
## constructs it in code rather than in the inspector.

## Health each combatant enters the fight with.
var starting_health: float = 1.0
## Damage of a full-commitment strike, before ferocity and jitter.
var base_damage: float = 0.12
## Strike-to-strike jitter, as a fraction of the strike. This is what keeps two
## identically-taught creatures out of a perfectly scripted draw: without it
## the outcome of a mirror match is decided by float rounding, which always
## falls the same way.
var damage_variance: float = 0.25
## Seconds between exchanges when the fight is driven through advance().
var exchange_interval: float = 1.0
## Hard ceiling on exchanges, so no pairing can trade blows forever.
var max_exchanges: int = 60
## Ferocity below which a creature refuses the fight. When both sides are under
## it the fight ends: two creatures taught that violence is punished should
## disengage, not stand exchanging token blows until the ceiling.
var disengage_threshold: float = 0.05
## How hard a perfectly calm creature still swings, as a fraction of full
## commitment. Zero would make a fight between two calm creatures a stalemate
## that only the exchange ceiling could end.
var calm_swing: float = 0.4
## Scales one exchange's damage margin into intrinsic feedback in [-1, 1]:
## winning the exchange rewards attacking, taking the worst of it punishes it.
var feedback_scale: float = 6.0

var _a: Object = null
var _b: Object = null
var _health_a: float = 0.0
var _health_b: float = 0.0
var _exchanges: int = 0
var _accumulated: float = 0.0
var _over: bool = false
var _rng := RandomNumberGenerator.new()


func _init(seed_value: int = 0) -> void:
	_rng.seed = seed_value


## Starts a fight between two combatants at full health.
func begin(fighter_a: Object, fighter_b: Object) -> void:
	_a = fighter_a
	_b = fighter_b
	_health_a = starting_health
	_health_b = starting_health
	_exchanges = 0
	_accumulated = 0.0
	_over = false


## Drives the fight on the caller's clock: one exchange per interval crossed.
func advance(delta: float) -> void:
	if _over or _a == null or delta <= 0.0 or is_nan(delta):
		return
	_accumulated += delta
	while _accumulated >= exchange_interval and not _over:
		_accumulated -= exchange_interval
		resolve_exchange(_a, _b)


func is_over() -> bool:
	return _over


func exchanges() -> int:
	return _exchanges


## The side left with more health, or null before the end and on a dead heat.
func winner() -> Object:
	if not _over or _health_a == _health_b:
		return null
	return _a if _health_a > _health_b else _b


## Remaining health of a combatant in this fight; zero for a stranger to it.
func health_of(fighter: Object) -> float:
	if fighter != null and fighter == _a:
		return _health_a
	if fighter != null and fighter == _b:
		return _health_b
	return 0.0


## One exchange. Both strikes are computed from the pre-exchange state and land
## simultaneously, so neither side gains anything from being the first
## argument: the same two minds in swapped seats fight the mirrored fight.
func resolve_exchange(a: Object, b: Object) -> Dictionary:
	if a != _a or b != _b:
		begin(a, b)
	if _over:
		return _report(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false)

	var ferocity_a: float = ferocity_of(a, b)
	var ferocity_b: float = ferocity_of(b, a)
	var dealt_a: float = _strike(ferocity_a)
	var dealt_b: float = _strike(ferocity_b)

	_health_a = maxf(_health_a - dealt_b, 0.0)
	_health_b = maxf(_health_b - dealt_a, 0.0)
	_mirror_damage(a, _health_a)
	_mirror_damage(b, _health_b)

	# The lesson is the margin, not the victory: a creature that took a beating
	# while landing nothing learns attacking was a bad idea in proportion, and a
	# close scrap teaches almost nothing either way.
	var feedback_a: float = clampf((dealt_a - dealt_b) * feedback_scale, -1.0, 1.0)
	var feedback_b: float = clampf((dealt_b - dealt_a) * feedback_scale, -1.0, 1.0)
	_learn(a, b, feedback_a)
	_learn(b, a, feedback_b)

	_exchanges += 1
	var disengaged: bool = (
		ferocity_a < disengage_threshold and ferocity_b < disengage_threshold
	)
	_over = (
		_health_a <= 0.0 or _health_b <= 0.0
		or _exchanges >= max_exchanges or disengaged
	)
	return _report(dealt_a, dealt_b, ferocity_a, ferocity_b, feedback_a, feedback_b, disengaged)


## How hard this creature fights right now, in [0, 1]: what it has learned
## about attacking this opponent, scaled by how angry it currently is. Public
## so a fight's story can be read out and printed by the tests and the UI.
func ferocity_of(fighter: Object, opponent: Object) -> float:
	var mind: CreatureMind = _mind_of(fighter)
	if mind == null:
		return 0.0
	var opinion: float = mind.opinions.predict(ANGER, ATTACK, _belief_of(mind, opponent))
	# Opinion is a feedback expectation in [-1, 1]; folded so "no opinion" lands
	# at half — an untaught creature fights, tentatively, rather than not at all.
	var willingness: float = clampf(0.5 + opinion * 0.5, 0.0, 1.0)
	var anger: float = float(mind.desires.intensities(mind.situation()).get(ANGER, 0.0))
	# The same per-desire bias the leashes apply everywhere else, so a leash of
	# aggression leans the fight the way it leans every other decision.
	anger = clampf(anger * float(mind.desire_bias.get(ANGER, 1.0)), 0.0, 1.0)
	return willingness * lerpf(calm_swing, 1.0, anger)


func _strike(ferocity: float) -> float:
	return base_damage * ferocity * _rng.randf_range(
		1.0 - damage_variance, 1.0 + damage_variance
	)


## Feeds one exchange's outcome back through the same path world consequences
## use, so fighting teaches exactly the way eating or being slapped does.
func _learn(fighter: Object, opponent: Object, value: float) -> void:
	var mind: CreatureMind = _mind_of(fighter)
	if mind == null:
		return
	mind.apply_intrinsic_feedback(ANGER, ATTACK, _record_of(opponent), value)


## Keeps the mind's damage sense in step with the fight, so Anger and Fear read
## the beating as it happens rather than after it is over.
func _mirror_damage(fighter: Object, health: float) -> void:
	var mind: CreatureMind = _mind_of(fighter)
	if mind == null:
		return
	mind.damage = clampf(1.0 - health / maxf(starting_health, 0.001), 0.0, 1.0)


## The fighter's current belief about its opponent, or blank ignorance when the
## opponent has no registry record to hold a belief about.
func _belief_of(mind: CreatureMind, opponent: Object) -> PackedFloat32Array:
	var record: WorldObject = _record_of(opponent)
	if record == null:
		var blank := PackedFloat32Array()
		blank.resize(ObjectAttributes.COUNT)
		blank.fill(ObjectAttributes.UNKNOWN)
		return blank
	# A creature in a fight is certainly looking at what it is fighting.
	mind.beliefs.observe_truth(record)
	return mind.beliefs.belief_for(record)


func _mind_of(fighter: Object) -> CreatureMind:
	if fighter == null:
		return null
	return fighter.get("mind") as CreatureMind


func _record_of(fighter: Object) -> WorldObject:
	if fighter == null:
		return null
	return fighter.get("object") as WorldObject


func _report(
	dealt_a: float, dealt_b: float,
	ferocity_a: float, ferocity_b: float,
	feedback_a: float, feedback_b: float,
	disengaged: bool
) -> Dictionary:
	return {
		"exchange": _exchanges,
		"dealt_a": dealt_a,
		"dealt_b": dealt_b,
		"ferocity_a": ferocity_a,
		"ferocity_b": ferocity_b,
		"feedback_a": feedback_a,
		"feedback_b": feedback_b,
		"health_a": _health_a,
		"health_b": _health_b,
		"disengaged": disengaged,
		"over": _over,
	}
