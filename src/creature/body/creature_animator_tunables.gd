class_name CreatureAnimatorTunables
extends Resource
## Every number the creature's animation runs on, in one editable place.
##
## Animation is tuned by eye, repeatedly, and hunting a bob amplitude through a
## match statement is a bad afternoon. Priorities and durations live here too
## because they are the actual behaviour of the state machine, not decoration:
## whether a slap can cut off a meal is decided by two numbers on this resource.
##
## Angles are radians, distances metres, frequencies cycles per second.

@export_group("State priority")
## A request only beats a one-shot already playing if its priority is strictly
## higher. Gaps of ten leave room to slot states in later without renumbering.
@export var idle_priority: int = 0
@export var walk_priority: int = 10
@export var sleep_priority: int = 20
@export var play_priority: int = 30
@export var eat_priority: int = 40
@export var celebrate_priority: int = 50
@export var attack_priority: int = 60
## Being hurt outranks everything. A creature that keeps chewing while it is
## being beaten reads as broken.
@export var hurt_priority: int = 100

@export_group("State duration")
## Seconds a one-shot plays before falling back. Looping states report zero
## duration, which is what makes them looping — there is no separate flag.
@export var eat_duration: float = 1.1
@export var attack_duration: float = 0.7
@export var hurt_duration: float = 0.5
@export var celebrate_duration: float = 1.6
## Play is a one-shot rather than a loop so a creature told to play once bounces
## once and settles, instead of bouncing until something else interrupts it.
@export var play_duration: float = 1.4

@export_group("Locomotion")
## Speed in m/s above which the creature is considered to be walking.
@export var walk_speed_threshold: float = 0.5
## Speed the walk cycle is authored against — creature.gd's move_speed.
@export var walk_reference_speed: float = 7.0
## Clamp on the cycle rate multiplier. Without a floor the animation freezes
## into a stiff pose as the creature slows to a stop; without a ceiling a
## creature launched by a miracle vibrates.
@export var walk_rate_min: float = 0.6
@export var walk_rate_max: float = 1.6

@export_group("Idle")
@export var idle_frequency: float = 0.55
@export var idle_bob: float = 0.035
@export var idle_head_nod: float = 0.03
## How much the torso swells as it breathes, as a fraction of its girth.
@export var idle_breath: float = 0.045
@export var idle_tail_sway: float = 0.10
## Ears flick rather than waving: an amplitude, how often, and how much of each
## period the flick occupies. A duty of 1.0 turns the flick into a wave.
@export var idle_ear_twitch: float = 0.32
@export var idle_ear_twitch_period: float = 4.3
@export var idle_ear_twitch_duty: float = 0.12

@export_group("Walk")
## Strides per second at the reference speed.
@export var walk_frequency: float = 1.35
## Lift of the whole body per step. Always upward — the term is an absolute sine —
## because there is no foot IK: a bob that went negative would drive the paws
## through the ground, while one that only rises lifts them off it, which at this
## amplitude reads as bounce rather than as floating.
@export var walk_bob: float = 0.12
@export var walk_roll: float = 0.09
## Constant forward lean while moving. Sells intent more than the bob does.
@export var walk_lean: float = 0.07
@export var walk_head_nod: float = 0.06
## Peak fore-and-aft swing of each leg at the hip. This is the number that has to
## stay small: past about 0.6 the thigh rotates up into the torso and the paw
## comes out of the creature's own ribs.
@export var walk_leg_swing: float = 0.42
## Peak knee flex during the forward half of a leg's cycle.
@export var walk_knee_bend: float = 0.55
@export var walk_tail_sway: float = 0.14

@export_group("Eat")
@export var eat_squash: float = 0.22
@export var eat_sink: float = 0.18
@export var eat_head_dip: float = 0.55
@export var eat_jaw_open: float = 0.45
## Whole chews per meal. Whole numbers only, or the mouth is left hanging open
## when the state ends.
@export var eat_chews: float = 3.0

@export_group("Attack")
@export var attack_lunge: float = 0.9
@export var attack_pitch: float = 0.35
@export var attack_head_thrust: float = 0.25
@export var attack_jaw_open: float = 0.5
## Ears back, the way anything about to bite holds them.
@export var attack_ear_pin: float = 0.35

@export_group("Hurt")
@export var hurt_recoil: float = 0.45
## Rocks backwards, away from whatever hit it.
@export var hurt_pitch: float = 0.22
@export var hurt_roll: float = 0.28
## Shakes over the length of the recoil.
@export var hurt_shakes: float = 2.0
## The flinch: head thrown back, ears flat, tail tucked under.
@export var hurt_head_recoil: float = 0.3
@export var hurt_ear_flatten: float = 0.6
@export var hurt_tail_tuck: float = 0.5

@export_group("Celebrate")
@export var celebrate_hops: float = 3.0
@export var celebrate_hop_height: float = 0.55
## Whole turns over the length of the celebration. Fractional values leave the
## creature facing the wrong way when it ends.
@export var celebrate_spins: float = 1.0
## Tail up and wagging hard. This is the pet response, so it is the one pose the
## player will read as gratitude.
@export var celebrate_tail_lift: float = 0.55
@export var celebrate_tail_wag: float = 0.6
## Whole wags over the length of the celebration.
@export var celebrate_wags: float = 5.0

@export_group("Play")
@export var play_frequency: float = 2.4
@export var play_bob: float = 0.3
@export var play_roll: float = 0.22
@export var play_head_nod: float = 0.2
@export var play_tail_wag: float = 0.4

@export_group("Sleep")
@export var sleep_frequency: float = 0.28
@export var sleep_sink: float = 0.55
@export var sleep_breath: float = 0.07
@export var sleep_head_dip: float = 0.5
@export var sleep_roll: float = 0.12
## Knees folded so the creature is lying rather than standing asleep.
@export var sleep_leg_fold: float = 0.85


## Seconds this state plays before it falls back. Zero means it loops until
## something replaces it.
##
## The state names are spelled out here rather than read from
## CreatureAnimator's constants on purpose: the animator holds a reference to
## this resource, and pointing back at it would make the two scripts a cyclic
## dependency, which GDScript refuses to compile.
func duration_for(state: StringName) -> float:
	match state:
		&"eat":
			return eat_duration
		&"attack":
			return attack_duration
		&"hurt":
			return hurt_duration
		&"celebrate":
			return celebrate_duration
		&"play":
			return play_duration
	return 0.0


## How hard this state defends itself against being replaced mid-play.
func priority_for(state: StringName) -> int:
	match state:
		&"walk":
			return walk_priority
		&"sleep":
			return sleep_priority
		&"play":
			return play_priority
		&"eat":
			return eat_priority
		&"celebrate":
			return celebrate_priority
		&"attack":
			return attack_priority
		&"hurt":
			return hurt_priority
	return idle_priority
