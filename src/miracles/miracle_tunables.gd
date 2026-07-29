class_name MiracleTunables
extends Resource
## Every number the miracle economy runs on, in one editable place.
##
## Same rule as MindTunables: the code below contains no bare constants. Prayer
## income and the size of the influence ring are pure feel — they will be retuned
## against play, repeatedly, and hunting them through four files each time is a
## bad afternoon. Per-miracle numbers (cost, radius, magnitude) live on the
## Miracle resource instead, because they vary per miracle rather than globally.

@export_group("Prayer power")
## Power earned per worshipper per second of worship.
##
## Sized against the miracle costs in miracle_library.gd: six villagers praying
## take about six seconds to pay for a food miracle, which is long enough that
## the player notices the village is the source and short enough that they are
## not stood waiting.
@export var prayer_per_worshipper: float = 0.35
## Ceiling on the pool. The cap is what stops a large village idling into an
## infinite reserve and makes losing followers actually hurt.
@export var prayer_maximum: float = 120.0
## What a new game starts with, so the first miracle needs no wait.
@export var prayer_initial: float = 20.0

@export_group("Influence")
## Radius with no followers at all. Not zero: the player must be able to act
## around their own temple to win the first believer back.
@export var influence_min_radius: float = 25.0
## Radius a fully believed-in god reaches. The island is 160 m across, so this
## is deliberately short of covering it — expansion has to stay a goal.
@export var influence_max_radius: float = 90.0
## Belief at which the ring reaches its maximum radius. Belief is measured in
## followers, so this is "about forty villagers believe in you".
@export var influence_belief_full: float = 40.0
