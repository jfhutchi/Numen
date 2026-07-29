class_name VillageTunables
extends Resource
## Every number the village simulation runs on, in one editable place.
##
## Same rule as the creature's mind: no bare constants in the simulation itself.
## A village is a knot of feedback loops — food rate against birth rate against
## build rate — and tuning it means changing one number and re-running the
## twenty-minute sim, not hunting constants through four files.

@export_group("Tick budget")
## Decision ticks per second of simulated time. Deliberately not every frame.
@export var decisions_per_second: float = 5.0
## How many villagers may re-decide on one tick. The population is walked
## round-robin, so this is the whole per-frame AI budget: a village of two
## hundred costs exactly as much per frame as a village of eight, it just takes
## longer to come back round to any one villager.
@export var villagers_per_decision_tick: int = 4
## How often the village re-computes its dominant need for the indicator.
## Cheaper than doing it on every decision tick and nobody can see the lag.
@export var desire_refresh_seconds: float = 1.0

@export_group("Population")
@export var starting_population: int = 8
## Hard ceiling. Growth is meant to be gated by food and housing; this only stops
## a runaway from turning a twenty-minute test into a memory experiment.
@export var max_population: int = 24
@export var house_capacity: int = 4
## Jobs are handed out by cycling this list, so the mix stays proportional as the
## village grows and the assignment is deterministic for a given seed.
@export var job_cycle: Array[StringName] = [
	&"farmer", &"forester", &"farmer", &"builder",
	&"breeder", &"farmer", &"forester", &"priest",
]

@export_group("Needs")
@export var food_per_second: float = 0.02
@export var sleep_per_second: float = 0.008
@export var worship_per_second: float = 0.006
@export var procreate_per_second: float = 0.01
## Need levels are raised to this power before scoring. Linear urgency made
## villagers dither: a need at 0.4 scored nearly as well as one at 0.8, so they
## would break off work to nibble constantly. Squaring keeps a mild need quiet
## and lets a pressing one take over decisively.
@export var need_urgency_exponent: float = 2.0
## Work is always at least this attractive, so nobody stands idle in a village
## that has everything it needs.
@export var work_base_level: float = 0.35
## Ceiling on how attractive work can get, and the reason nobody works
## themselves to death. A need at full strength scores 1.0; work capped at 0.9
## scores 0.9^2 x 1.2 = 0.97, so a villager about to starve always breaks off and
## eats — provided there is food. Before the cap, a builder in a long timber
## shortage kept building through a rising hunger it could have satisfied, and
## starved beside a full larder.
@export var work_max_level: float = 0.9
@export var default_need_weight: float = 1.0
## Per job, how much each need is worth to that villager. Keys are job names,
## values are need-name to weight. A job is nothing but a bias on the same
## utility function everyone runs.
@export var job_need_weights: Dictionary = {
	&"farmer": {&"food": 1.0, &"sleep": 1.0, &"worship": 0.6, &"procreate": 0.5, &"work": 1.2},
	&"forester": {&"food": 1.0, &"sleep": 1.0, &"worship": 0.6, &"procreate": 0.5, &"work": 1.2},
	&"builder": {&"food": 1.0, &"sleep": 1.0, &"worship": 0.6, &"procreate": 0.5, &"work": 1.2},
	&"breeder": {&"food": 1.0, &"sleep": 1.0, &"worship": 0.5, &"procreate": 2.2, &"work": 0.7},
	&"priest": {&"food": 1.0, &"sleep": 1.0, &"worship": 2.0, &"procreate": 0.5, &"work": 1.0},
}
## Spread of starting need levels. Without the jitter the founders drift in
## lockstep and the whole village queues at the store on the same second.
@export var initial_need_spread: float = 0.35
@export var newborn_need_level: float = 0.2

@export_group("Satisfying a need")
@export var meal_food: float = 2.0
@export var meal_relief: float = 0.9
@export var meal_seconds: float = 3.0
@export var sleep_seconds: float = 20.0
@export var sleep_relief: float = 0.95
@export var worship_seconds: float = 8.0
@export var worship_relief: float = 0.9
@export var procreate_seconds: float = 6.0

@export_group("Work")
@export var walk_speed: float = 3.0
## How close counts as arrived. Must stay above zero: it is also the guard that
## keeps the steering normalisation away from a zero-length vector.
@export var arrive_radius: float = 1.2
@export var harvest_seconds: float = 5.0
@export var harvest_food: float = 8.0
## Foraging is what a farmer does when the village has no field yet. Worse than
## farming on purpose, but it exists so a village that loses its fields can still
## feed itself instead of deadlocking.
@export var forage_seconds: float = 8.0
@export var forage_food: float = 3.0
@export var chop_seconds: float = 7.0
@export var chop_wood: float = 6.0
@export var build_seconds: float = 10.0
@export var priest_tend_seconds: float = 6.0
## Work urgency for jobs whose output is not a stored resource.
@export var priest_work_urgency: float = 0.5
## What a builder feels when there is nothing to build. Low, so it goes and helps
## with the timber instead.
@export var builder_idle_urgency: float = 0.2
## Stock the village aims to hold per villager. Work urgency is the shortfall
## against this, which is what makes the village work harder when it is poor.
@export var food_target_per_villager: float = 4.0
@export var wood_target_per_villager: float = 3.0

@export_group("Building")
@export var house_wood_cost: float = 18.0
@export var field_wood_cost: float = 10.0
@export var villagers_per_field: int = 6
@export var starting_houses: int = 2
@export var starting_fields: int = 2
@export var starting_food: float = 40.0
@export var starting_wood: float = 20.0

@export_group("Birth and death")
@export var birth_food_cost: float = 6.0
## Food the village must hold *beyond* the cost of the birth before it will have
## a child. Breeding down to an empty larder is how a village dies.
@export var birth_food_reserve: float = 12.0
@export var birth_cooldown: float = 45.0
## Seconds a villager survives at maximum hunger before it dies.
@export var starve_seconds: float = 120.0

@export_group("The divine hand")
## Speed below which a villager the hand dropped counts as landed. Under it the
## villager takes its position back off the physics body and walks away; above it
## the body is still in flight and stays authoritative. Zero would work only for
## a body the physics server has already put to sleep, and a villager tossed onto
## a slope may creep for a long time before that happens.
@export var hand_settle_speed: float = 0.4

@export_group("Layout")
## Where the village centre may be looked for, as a fraction of island extent.
@export var centre_search_fraction: float = 0.25
@export var house_ring_radius: float = 8.0
@export var field_ring_radius: float = 15.0
## Extra radius per ring once the current one is full.
@export var site_spacing: float = 5.0
## Where foresters go when no tree is registered nearby.
@export var forest_radius: float = 24.0
@export var indicator_height: float = 6.0
