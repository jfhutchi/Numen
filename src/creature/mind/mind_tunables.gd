class_name MindTunables
extends Resource
## Every number the creature's mind runs on, in one editable place.
##
## The mind code below must contain no bare constants. Learning behaviour is
## tuned against feel as much as against tests, and hunting magic numbers
## through eight files to find why a creature will not stop eating people is a
## bad afternoon.

@export_group("Perception")
## How far the creature notices things, in metres.
@export var perception_radius: float = 30.0
## Score falloff with distance: score is divided by (1 + distance/this).
@export var distance_falloff: float = 12.0
## How fast a belief moves toward what was actually observed, per observation.
@export var belief_learning_rate: float = 0.35
## How strongly a fresh instance inherits what the creature knows about its
## type. 0 leaves it at pure uncertainty; 1 copies the prior outright.
@export_range(0.0, 1.0) var type_prior_strength: float = 0.75
## How fast the per-type prior itself moves. Slower than instance beliefs, so
## one odd individual does not rewrite the whole category.
@export var type_prior_learning_rate: float = 0.12

@export_group("Desires")
@export var desire_learning_rate: float = 0.25
## Learning rate is divided by (1 + age_seconds/this): the creature becomes set
## in its ways.
@export var desire_rate_age_halflife: float = 600.0
## How many of the strongest desires are considered each decision.
@export var top_desires: int = 3

@export_group("Opinions")
## Maximum decision-tree depth. Deeper trees overfit a short life.
@export var max_tree_depth: int = 6
## Experiences kept per (desire, action) pair before eviction begins.
@export var max_experiences: int = 200
## New experiences required before a tree is re-induced. Re-inducing on every
## example is pure waste — the tree barely moves and induction is the expensive
## part of the whole mind.
@export var reinduce_every: int = 8
## Attribute bins for ID3. Textbook ID3 splits categorical attributes; ours are
## floats, so they are bucketed. See ADR-006.
@export var bin_low: float = 0.34
@export var bin_high: float = 0.67
## Feedback magnitude above which an experience counts as clearly good or bad
## rather than neutral.
@export var feedback_class_threshold: float = 0.15

@export_group("Action selection")
## Decision ticks per second. Deliberately not every frame.
@export var decision_hz: float = 5.0
## Random jitter on the tick interval so a herd of creatures does not think in
## lockstep and spike one frame.
@export var decision_jitter: float = 0.25
## Softmax temperature when newborn: higher means less decisive.
##
## Must be scaled to the range of scores, which is roughly [-1,1] after the
## distance falloff. At 0.85 the creature was nearly indifferent to everything
## it had learned — a fully punished option still kept 40% of its original
## probability. Exploration in a young creature does not come from temperature
## anyway: an inexperienced mind predicts 0 for everything, so the softmax is
## uniform whatever the temperature. Temperature governs how decisively it acts
## on what it *does* know.
@export var start_temperature: float = 0.30
## Temperature it decays toward with age: low means exploit what it has learned.
@export var end_temperature: float = 0.08
## Seconds of life over which temperature decays from start to end.
@export var temperature_halflife: float = 420.0

@export_group("Feedback")
## Seconds after an action during which a pet or slap still credits it.
@export var feedback_window: float = 6.0
## Weight of an action the player performed while the creature watched.
@export var shown_weight: float = 0.6
## Weight of an action merely observed elsewhere. Lower — imitation should be a
## nudge, not a lesson.
@export var imitation_weight: float = 0.25
## How fast alignment tracks recent behaviour. Higher forgets faster.
@export_range(0.0, 1.0) var alignment_smoothing: float = 0.04
