class_name Miracle
extends Resource
## One castable miracle: what it costs, how it is drawn, and what it does.
##
## A Resource rather than a Dictionary so the five of them are one editable table
## with named, typed fields, and so a designer can retune a cost without touching
## code. `id` doubles as the effect key — miracle_effects.gd dispatches on it —
## which keeps a second parallel enum from drifting out of step with the first.

## Stable key. Also the effect selector in miracle_effects.gd, and the save key.
@export var id: StringName = &""

## Name shown to the player.
@export var display_name: String = ""

## One line of "what this does", for the UI and for the gesture tutorial.
@export var description: String = ""

## Prayer power a single cast consumes.
@export var prayer_cost: float = 0.0

## Name of the $P gesture template that invokes this miracle.
##
## Falls back to the id when none is given, which is only ever a bug — no
## recognised template is named after a miracle. MiracleLibrary passes a real
## one for all five. The gesture module owns the names, so this stays writable:
## rebinding is `library.by_id(&"food").gesture_template = &"scribble"` rather
## than a change in here.
@export var gesture_template: StringName = &""

## Radius in metres the effect reaches around the cast point.
@export var effect_radius: float = 6.0

## How much of the effect happens. Its meaning is per miracle and deliberately
## not abstracted: a count of things spawned for food and wood, an amount of
## water, a fraction of health for heal, a damage value for lightning.
@export var magnitude: float = 1.0

## Moral weight of casting this, from wicked to kind. Phase 6 drives the
## player's alignment from it, which is why it lives on the miracle rather than
## being inferred later from the effect.
@export_range(-1.0, 1.0) var alignment_weight: float = 0.0


func _init(
	miracle_id: StringName = &"",
	name_shown: String = "",
	cost: float = 0.0,
	radius: float = 6.0,
	strength: float = 1.0,
	alignment: float = 0.0,
	summary: String = "",
	gesture: StringName = &""
) -> void:
	id = miracle_id
	display_name = name_shown
	prayer_cost = cost
	effect_radius = radius
	magnitude = strength
	alignment_weight = alignment
	description = summary
	gesture_template = gesture if gesture != &"" else miracle_id


func _to_string() -> String:
	return "Miracle(%s, %.0f power)" % [id, prayer_cost]
