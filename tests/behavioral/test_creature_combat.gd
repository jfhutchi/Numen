extends GutTest
## Creature versus creature: the fight is an expression of upbringing.
##
## The headline is the reason this resolver exists at all: two differently-
## taught minds are pitted against each other headless, over several seeds, and
## the better-taught one measurably wins. One seeded fight proves nothing about
## a stochastic system, so every claim here is counted over seeds and printed.

const REGISTRY := preload("res://src/world/object_registry.gd")
const TUNABLES := preload("res://src/creature/mind/mind_tunables.gd")
const COMBAT := preload("res://src/creature/mind/combat.gd")

const ANGER := &"Anger"
const ATTACK := &"attack"
const CREATURE := &"creature"

## Lessons in a standard upbringing, and how strongly each one lands. Ten at
## 0.9 leaves the learned opinion around +-0.7 after leaf shrinkage — taught,
## but not saturated, so the fight itself still has something to add.
const LESSONS := 10
const TEACH_VALUE := 0.9

## Seeds for the headline. Enough to expose an upset, few enough to stay cheap.
const HEADLINE_SEEDS := 10
## Seeds for the mirror-match split, where the binomial noise needs more room.
const SPLIT_SEEDS := 40


## A combatant exactly as CreatureCombat duck-types one: a mind plus its
## registry record. The resolver never imports the creature body, so neither
## does this test — proving the seam is really as narrow as claimed.
class Fighter:
	extends RefCounted
	var mind: CreatureMind
	var object: WorldObject


## One arena: a bare registry holding two creature records two metres apart,
## each with a mind bound to it and converged on what a creature looks like.
## Without the perceive() warm-up every belief sits at 0.5 and a lesson about
## "that creature" would be a lesson about nothing in particular.
func _arena(seed_value: int) -> Dictionary:
	var world: Node = REGISTRY.new()
	autofree(world)
	var tunables: MindTunables = TUNABLES.new()
	# Re-induce on every example, as the learning tests do: the production
	# schedule saves frame budget, and here it would only blur which exchange
	# changed a mind.
	tunables.reinduce_every = 1
	var a: Fighter = _fighter(world, tunables, Vector3(-1.0, 0.0, 0.0), seed_value * 4 + 1)
	var b: Fighter = _fighter(world, tunables, Vector3(1.0, 0.0, 0.0), seed_value * 4 + 2)
	for i in 6:
		a.mind.perceive()
		b.mind.perceive()
	return {"a": a, "b": b}


func _fighter(
	world: Node, tunables: MindTunables, at: Vector3, seed_value: int
) -> Fighter:
	var fighter := Fighter.new()
	fighter.object = world.add(CREATURE, at)
	fighter.mind = CreatureMind.new(tunables, seed_value)
	fighter.mind.bind_world(world, at)
	fighter.mind.self_object_id = fighter.object.id
	return fighter


## An upbringing: repeated intrinsic feedback about attacking the opponent,
## through the same path a real consequence would arrive by.
func _teach(fighter: Fighter, opponent: Fighter, value: float, lessons: int = LESSONS) -> void:
	for i in lessons:
		fighter.mind.apply_intrinsic_feedback(ANGER, ATTACK, opponent.object, value)


## Runs a fight to its end through advance(), the way the game would drive it.
## The loop bound is generous on purpose: termination is asserted by the tests,
## not enforced by this helper.
func _fight(a: Fighter, b: Fighter, seed_value: int) -> CreatureCombat:
	var combat: CreatureCombat = COMBAT.new(seed_value)
	combat.begin(a, b)
	for i in 200:
		if combat.is_over():
			break
		combat.advance(1.0)
	return combat


## The learned expectation this fighter holds about attacking that opponent.
func _opinion(fighter: Fighter, opponent: Fighter) -> float:
	return fighter.mind.opinions.predict(
		ANGER, ATTACK, fighter.mind.beliefs.belief_for(opponent.object)
	)


func test_a_well_taught_creature_beats_a_badly_taught_one() -> void:
	var taught_wins: int = 0
	var punished_wins: int = 0
	var ties: int = 0

	gut.p("seed | winner   | exchanges | health(taught) | health(punished)")
	for seed_value in HEADLINE_SEEDS:
		var arena: Dictionary = _arena(seed_value)
		var taught: Fighter = arena["a"]
		var punished: Fighter = arena["b"]
		_teach(taught, punished, TEACH_VALUE)
		_teach(punished, taught, -TEACH_VALUE)

		var combat: CreatureCombat = _fight(taught, punished, seed_value)
		var outcome: String = "tie"
		if combat.winner() == taught:
			taught_wins += 1
			outcome = "taught"
		elif combat.winner() == punished:
			punished_wins += 1
			outcome = "punished"
		else:
			ties += 1
		gut.p("%4d | %-8s | %9d | %14.3f | %16.3f" % [
			seed_value, outcome, combat.exchanges(),
			combat.health_of(taught), combat.health_of(punished),
		])

	gut.p("wins over %d seeds: taught %d, punished %d, ties %d" % [
		HEADLINE_SEEDS, taught_wins, punished_wins, ties
	])
	assert_gte(taught_wins, HEADLINE_SEEDS - 1,
		"a creature rewarded for attacking should beat one punished for it, near enough always")
	assert_lte(punished_wins, 1,
		"the punished creature stealing more than an odd upset means teaching does not matter")


func test_a_creature_learns_from_fighting() -> void:
	# Rigged asymmetric on purpose: a taught bully against an untaught victim
	# gives the margin a consistent sign, so the direction of learning is
	# assertable rather than a coin toss.
	var arena: Dictionary = _arena(99)
	var bully: Fighter = arena["a"]
	var victim: Fighter = arena["b"]
	_teach(bully, victim, TEACH_VALUE)

	var bully_before: float = _opinion(bully, victim)
	var victim_before: float = _opinion(victim, bully)

	var combat: CreatureCombat = COMBAT.new(7)
	combat.begin(bully, victim)
	gut.p("exchange | dealt(bully) | dealt(victim) | feedback(bully) | feedback(victim)")
	for i in 5:
		if combat.is_over():
			break
		var report: Dictionary = combat.resolve_exchange(bully, victim)
		gut.p("%8d | %12.4f | %13.4f | %+15.3f | %+16.3f" % [
			int(report["exchange"]), float(report["dealt_a"]), float(report["dealt_b"]),
			float(report["feedback_a"]), float(report["feedback_b"]),
		])

	var bully_after: float = _opinion(bully, victim)
	var victim_after: float = _opinion(victim, bully)
	gut.p("bully  opinion of attack: %+.3f -> %+.3f" % [bully_before, bully_after])
	gut.p("victim opinion of attack: %+.3f -> %+.3f" % [victim_before, victim_after])

	assert_lt(victim_after, victim_before - 0.05,
		"taking a beating should turn the victim against attacking")
	assert_ne(bully_after, bully_before,
		"the winner's opinion should move too — fighting is experience, not a replay")
	assert_gt(bully_after, victim_after,
		"after the fight the two minds should disagree about attacking")


func test_a_fight_terminates_and_the_winner_is_the_one_left_standing() -> void:
	var arena: Dictionary = _arena(3)
	var taught: Fighter = arena["a"]
	var punished: Fighter = arena["b"]
	_teach(taught, punished, TEACH_VALUE)
	_teach(punished, taught, -TEACH_VALUE)

	var combat: CreatureCombat = _fight(taught, punished, 3)
	gut.p("over=%s after %d exchanges (ceiling %d); health %.3f vs %.3f" % [
		str(combat.is_over()), combat.exchanges(), combat.max_exchanges,
		combat.health_of(taught), combat.health_of(punished),
	])
	assert_true(combat.is_over(), "the fight must end on its own")
	assert_lte(combat.exchanges(), combat.max_exchanges)

	var winner: Object = combat.winner()
	assert_not_null(winner, "a one-sided fight should not end in a dead heat")
	var healthier: Fighter = taught \
		if combat.health_of(taught) > combat.health_of(punished) else punished
	assert_eq(winner, healthier, "winner() must agree with who has health left")
	assert_eq(minf(combat.health_of(taught), combat.health_of(punished)), 0.0,
		"this pairing ends by knockout, so the loser should be at zero")


func test_two_creatures_taught_against_violence_disengage() -> void:
	# The other way a fight is allowed to end. Thirty hard lessons each puts
	# both willingnesses under the disengage threshold, and the fight should be
	# over almost before it starts — circling and walking away, not a knockout.
	var arena: Dictionary = _arena(11)
	var a: Fighter = arena["a"]
	var b: Fighter = arena["b"]
	_teach(a, b, -1.0, 30)
	_teach(b, a, -1.0, 30)

	var combat: CreatureCombat = _fight(a, b, 11)
	gut.p("pacifists: over=%s after %d exchanges, health %.3f and %.3f" % [
		str(combat.is_over()), combat.exchanges(),
		combat.health_of(a), combat.health_of(b),
	])
	assert_true(combat.is_over())
	assert_lt(combat.exchanges(), combat.max_exchanges,
		"two creatures taught that violence is punished should disengage, not slug to the ceiling")
	assert_gt(combat.health_of(a), 0.9, "a refused fight should barely scratch anyone")
	assert_gt(combat.health_of(b), 0.9)


func test_identically_taught_creatures_split_wins_evenly() -> void:
	# Fairness of the resolver itself: with the same upbringing on both sides
	# (here: none), the outcome must come from the seeded jitter, not from
	# which seat a combatant sits in. Both strikes are computed from the
	# pre-exchange state, and this is the test that holds that invariant.
	var wins_a: int = 0
	var wins_b: int = 0
	var ties: int = 0
	for seed_value in SPLIT_SEEDS:
		var arena: Dictionary = _arena(1000 + seed_value)
		var combat: CreatureCombat = _fight(arena["a"], arena["b"], seed_value)
		if combat.winner() == arena["a"]:
			wins_a += 1
		elif combat.winner() == arena["b"]:
			wins_b += 1
		else:
			ties += 1

	var decided: int = wins_a + wins_b
	gut.p("mirror match over %d seeds: seat a %d, seat b %d, ties %d" % [
		SPLIT_SEEDS, wins_a, wins_b, ties
	])
	assert_gt(decided, SPLIT_SEEDS / 2, "most mirror matches should still reach a decision")
	assert_gte(mini(wins_a, wins_b), int(float(decided) * 0.25),
		"a %d/%d split means seat order is deciding fights, not teaching" % [wins_a, wins_b])
