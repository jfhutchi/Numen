class_name RaidTunables
extends Resource
## Every number the raid system runs on, in one editable place.
##
## Same rule as VillageTunables: no bare constants in the simulation itself.
## Raids are the game's pressure loop — how hard, how often, and what it costs
## to ignore them — and tuning pressure means changing one number and re-running
## the behavioural suite, not hunting constants through three files.

@export_group("Scheduling")
## Grace period before the first raid. Long enough for the player to find their
## feet and bank some prayer power; short enough that the threat is met in the
## first session rather than read about.
@export var first_raid_delay: float = 150.0
## Seconds between raids once they have started. The interval is fixed and the
## *strength* scales with pressure — one knob for "how often", one for "how
## hard", so the two can be tuned without fighting each other.
@export var raid_interval: float = 240.0

@export_group("Pressure")
## Rival belief at which raid pressure reaches zero. Deliberately below a small
## village's conversion threshold (Conversion.threshold_base plus per-head), so
## sustained missionary work starts paying off in quieter raids well before it
## pays out in a conversion.
@export var belief_for_peace: float = 12.0
## Raiders a raid brings even with the rival nearly won over. Raids never fall
## to zero short of conversion itself — conversion, not appeasement, is what
## ends the threat.
@export var base_strength: int = 2
## Extra raiders at zero rival belief, scaled down linearly as belief approaches
## belief_for_peace. This is the punishment for ignoring the rival village.
@export var strength_per_pressure: float = 4.0
## Ceiling on raid size. Bounded so a neglected rival is punishing rather than
## an instant wipe, and so the raid never outnumbers the MultiMesh-free handful
## of registry records the perception scan pays for.
@export var max_strength: int = 8

@export_group("Raiders")
## One lightning bolt (magnitude 1.0 in MiracleLibrary) kills exactly one hale
## raider. Raise this and lightning becomes a softener; lower it and the storm
## clears raids for free.
@export var raider_health: float = 1.0
## Metres per second. Faster than VillageTunables.walk_speed (3.0) on purpose:
## a raider that can never close on a walking villager is scenery, not a threat.
@export var raider_speed: float = 4.0
## How close a raider must be to hurt someone. Matches the scale of the
## village's own arrive_radius rather than a weapon reach.
@export var attack_radius: float = 2.0
## Villager health drained per second of contact, against a health bar of 1.0.
## An order of magnitude above health_regen_per_second (0.004), so a raid always
## outruns convalescence, and well below the heal miracle's 0.5 dose, so one
## timely cast genuinely turns a death into a survivor.
@export var damage_per_second: float = 0.06
## Total damage a raider deals before it withdraws satisfied — two villagers'
## worth of blood at the default. The budget is what bounds an unopposed raid:
## the raid ends by damage done, not by clock, so a repelled raid is exactly one
## whose raiders died before spending this.
@export var raider_damage_budget: float = 2.0
## Radius of the golden-angle ring raiders spawn on around the raid origin, so
## a war band is a cluster rather than a stack of coincident points.
@export var spawn_spread: float = 3.0
## Ground height below which a raider drowns. Compared with strict less-than, so
## the flat zero-height ground headless tests run on counts as land while any
## real seabed does not. This is what makes throwing a raider into the sea kill it.
@export var drown_below: float = 0.0
## Speed below which a raider the hand dropped counts as landed, mirroring
## VillageTunables.hand_settle_speed for the same reason: above it the physics
## body is still in flight and stays authoritative.
@export var hand_settle_speed: float = 0.4

@export_group("Outcome")
## Villagers a raid must kill to count as lost. The player's measure is people,
## not damage: a raid whose every wound was healed back was genuinely survived,
## and one that left a corpse was not.
@export var deaths_to_lose_raid: int = 1
