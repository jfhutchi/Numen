class_name AudioCues
extends RefCounted
## Which cue each game event plays. The only file that knows both vocabularies.
##
## Kept out of both the synthesiser and the director on purpose, for the same
## reason CreatureActionStates is kept out of both the mind and the animator: the
## creature must not know the game has speakers, and the audio layer must not know
## the game has desires. Callers say
##
##     director.play(AudioCues.for_creature_action(action), position)
##
## and no cue name is ever spelled out at a call site, so renaming a cue is one
## edit here rather than a search through the gameplay code.
##
## There are more events than cues, and several events deliberately share one.
## The sharing is by *shape*, not by meaning — a low descending buzz is the right
## sound for a refused miracle and for a death, and nothing is gained by
## synthesising two of them.

## What an event with no sound maps to. AudioDirector.play treats it as silence.
const NONE := &""

## The creature's thirteen actions. Two of them are silent on purpose:
##
## - `sleep` has no onset to mark; a sound here would fire once and then the
##   creature would lie there silently anyway.
## - `follow_player` is walking, and footsteps belong to the gait that the
##   animator drives, not to the single decision that starts the walk. Playing a
##   footstep here would give one step per decision, which is not a walk.
##
## An action that is not on this list costs silence rather than a wrong sound,
## which is the same bargain CreatureActionStates strikes when it falls back to
## the idle pose: a verb added to the mind before it is added here is quiet, not
## broken.
const FOR_CREATURE_ACTION: Dictionary = {
	&"eat": ProceduralSfx.CUE_EAT,
	&"attack": ProceduralSfx.CUE_SLAP,
	# Stooping to lift something is a soft thud, which is what a footstep is.
	&"pick_up": ProceduralSfx.CUE_FOOTSTEP,
	# The sharp transient of a hurl. Reads as effort whatever is being thrown.
	&"throw": ProceduralSfx.CUE_SLAP,
	# Presenting a gift: the warm one, so a generous creature sounds generous.
	&"give_to_village": ProceduralSfx.CUE_PET,
	&"water_field": ProceduralSfx.CUE_SPLASH,
	&"heal": ProceduralSfx.CUE_PET,
	&"play_with": ProceduralSfx.CUE_PET,
	&"sleep": NONE,
	&"follow_player": NONE,
	&"imitate": ProceduralSfx.CUE_PET,
	&"defecate": ProceduralSfx.CUE_SPLASH,
	&"dance": ProceduralSfx.CUE_BIRTH,
}

## The five miracles. Four of them share the rising sweep so that the sweep comes
## to mean "a miracle happened" — the player has to learn one sound, not five —
## and lightning breaks the rule because a thunderclap is the reason anyone casts
## it.
const FOR_MIRACLE: Dictionary = {
	&"food": ProceduralSfx.CUE_MIRACLE_CAST,
	&"wood": ProceduralSfx.CUE_MIRACLE_CAST,
	&"water": ProceduralSfx.CUE_MIRACLE_CAST,
	&"heal": ProceduralSfx.CUE_MIRACLE_CAST,
	&"lightning": ProceduralSfx.CUE_THUNDER,
}

## Keyed by the names of the signals the village actually emits — `born`, `died`,
## `building_raised` — so a caller connecting one of them does not have to
## translate its name into a different vocabulary on the way here.
const FOR_VILLAGE_EVENT: Dictionary = {
	&"born": ProceduralSfx.CUE_BIRTH,
	# The descending buzz. Not a fanfare, and not silence either.
	&"died": ProceduralSfx.CUE_MIRACLE_REFUSED,
	&"building_raised": ProceduralSfx.CUE_BIRTH,
}


## The cue for one of the mind's actions, or NONE for an action with no sound.
static func for_creature_action(action: StringName) -> StringName:
	var cue: StringName = FOR_CREATURE_ACTION.get(action, NONE)
	return cue


## The cue for a successful cast.
##
## Unmapped miracles fall back to the cast sweep rather than to silence — the
## opposite of the creature's actions, and deliberately so. Every miracle is a
## miracle, so the generic sweep is always defensible, whereas there is no
## generic sound for "the creature did something with its body".
static func for_miracle(miracle_id: StringName) -> StringName:
	var cue: StringName = FOR_MIRACLE.get(miracle_id, ProceduralSfx.CUE_MIRACLE_CAST)
	return cue


## The cue for a refused cast. A function rather than a bare constant so that
## every audio call site in the gameplay code reads the same way.
static func for_miracle_refusal() -> StringName:
	return ProceduralSfx.CUE_MIRACLE_REFUSED


## The cue for a village signal, or NONE for one with no sound.
static func for_village_event(event: StringName) -> StringName:
	var cue: StringName = FOR_VILLAGE_EVENT.get(event, NONE)
	return cue
