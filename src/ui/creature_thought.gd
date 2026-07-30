class_name CreatureThought
extends Node3D
## Two lines floating over the creature: what it wants, and what it has fixed on.
##
## The Mind Inspector exists to *verify* the learning. This exists to *play* with
## it. The colour is the whole point — an intention the creature has been punished
## for reads differently from one it has been rewarded for, so the player can see
## a bad idea forming and intervene, instead of reading about it afterwards in a
## panel.
##
## All the state that matters is plain: text(), opinion(), colour() and showing()
## are computed with no reference to the Label3D, so the indicator can be driven
## and asserted on with no scene at all. The billboard is a skin over them.

@export_group("Placement")
## Metres above the creature's origin. The body's head sits near 1.6 m, so the
## default clears it without floating off into the sky.
@export var height_offset: float = 2.6:
	set(value):
		height_offset = value
		if _label != null:
			_label.position = Vector3.UP * value

@export_group("Appearance")
@export var font_size: int = 40
@export var pixel_size: float = 0.0075
@export var positive_colour: Color = Color(0.50, 0.90, 0.58)
@export var negative_colour: Color = Color(0.95, 0.46, 0.40)
@export var neutral_colour: Color = Color(0.86, 0.89, 0.94)
## Opinion magnitude below which the creature has no real feeling either way, and
## the thought is shown neutral rather than being coloured on numeric noise.
@export var neutral_band: float = 0.05

@export_group("Timing")
## Seconds between re-reads of the mind. The mind only decides at a few hertz, so
## polling it every frame would be work for nothing.
@export var refresh_interval: float = 0.2
## Opacity change per second. Fading rather than blinking, because a label that
## pops in and out on every decision tick is noise.
@export var fade_speed: float = 5.0

var _mind: CreatureMind = null
var _label: Label3D = null
var _text: String = ""
var _opinion: float = 0.0
var _alpha: float = 0.0
var _since_refresh: float = 0.0


func _ready() -> void:
	_label = Label3D.new()
	_label.name = "ThoughtLabel"
	# Billboarded so it reads from any camera angle, and depth-tested off so a
	# thought is never half-buried in the creature's own shoulder.
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.font_size = font_size
	_label.pixel_size = pixel_size
	_label.outline_size = maxi(font_size / 6, 1)
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.75)
	_label.position = Vector3.UP * height_offset
	add_child(_label)
	_apply()


func bind(mind: CreatureMind) -> void:
	_mind = mind
	refresh()


## Pulls the creature's current intention out of the mind.
func refresh() -> void:
	var choice: CreatureMind.Option = _mind.last_choice() if _mind != null else null
	if choice == null:
		# Blanked rather than left alone. Stale text is worse than none: the
		# player reads "eat villager", slaps the creature, and punishes it for an
		# intention it dropped ten seconds ago.
		_text = ""
		_opinion = 0.0
	else:
		_text = "%s\n%s %s" % [
			choice.desire,
			choice.action,
			"itself" if choice.object == null else String(choice.object.type),
		]
		_opinion = choice.opinion
	_apply()


## Re-reads the mind on the refresh interval and eases the label's opacity toward
## where it should be. Split out of _process so it can be driven a step at a time
## with no frame loop.
func advance(delta: float) -> void:
	_since_refresh += delta
	if _since_refresh >= refresh_interval:
		_since_refresh = 0.0
		refresh()
	_alpha = move_toward(_alpha, 1.0 if showing() else 0.0, fade_speed * delta)
	_apply()


func _process(delta: float) -> void:
	advance(delta)


## Whether there is a live intention to show. False means the creature has nothing
## in reach, and the indicator is showing nothing rather than something old.
func showing() -> bool:
	return not _text.is_empty()


func text() -> String:
	return _text


## The learned expectation behind the current intention, as last_choice() scored
## it: positive for something the creature expects to go well.
func opinion() -> float:
	return _opinion


## The colour the current thought is drawn in. The feedback loop in one value.
func colour() -> Color:
	if not showing():
		return neutral_colour
	if _opinion > neutral_band:
		return positive_colour
	if _opinion < -neutral_band:
		return negative_colour
	return neutral_colour


func alpha() -> float:
	return _alpha


## The billboard itself, so a caller can restyle it and a test can confirm the
## skin really received what refresh() computed.
func label() -> Label3D:
	return _label


func _apply() -> void:
	if _label == null:
		return
	_label.text = _text
	# Authored in sRGB and converted here: Label3D feeds modulate into a 3D
	# material, which consumes linear colour.
	var tint: Color = colour().srgb_to_linear()
	tint.a = _alpha
	_label.modulate = tint
