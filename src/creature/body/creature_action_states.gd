class_name CreatureActionStates
extends RefCounted
## Translates the mind's action names into animation states.
##
## Kept out of both the mind and the animator on purpose. The mind must not know
## it has a body — that seam is what lets the whole learning system run headless
## (ADR-003) — and the animator must not know the game has desires. This is the
## only file that speaks both vocabularies, so it is the only file to change
## when the mind learns a new verb.
##
## There are thirteen actions and eight states, so several actions share one.
## The mapping is by posture rather than by meaning: what the creature's body
## does is the same for picking something up as for stooping to eat it.

const FOR_ACTION: Dictionary = {
	&"eat": CreatureAnimator.EAT,
	&"attack": CreatureAnimator.ATTACK,
	# A stoop toward the ground, which is exactly the eat pose.
	&"pick_up": CreatureAnimator.EAT,
	# A lunging hurl. Reads as an attack whatever the creature is throwing.
	&"throw": CreatureAnimator.ATTACK,
	# Presenting a gift: the proud, showy one.
	&"give_to_village": CreatureAnimator.CELEBRATE,
	&"water_field": CreatureAnimator.EAT,
	# No dedicated tending pose. The gentle bounce of play reads as fussing over
	# someone far better than the hop-and-spin of celebrate does.
	&"heal": CreatureAnimator.PLAY,
	&"play_with": CreatureAnimator.PLAY,
	&"sleep": CreatureAnimator.SLEEP,
	# Following is just walking with someone else picking the direction.
	&"follow_player": CreatureAnimator.WALK,
	&"imitate": CreatureAnimator.PLAY,
	&"defecate": CreatureAnimator.EAT,
	&"dance": CreatureAnimator.CELEBRATE,
}


## The animation state for one of the mind's actions. Unknown actions fall back
## to idle, so a verb added to the mind before it is added here costs a dull
## creature rather than a crash.
static func for_action(action: StringName) -> StringName:
	if FOR_ACTION.has(action):
		return FOR_ACTION[action]
	return CreatureAnimator.IDLE
