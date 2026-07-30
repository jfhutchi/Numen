class_name Conscience
extends Control
## Two voices that argue over the player's shoulder: one merciful, one cruel.
##
## This is the onboarding, the characterisation and the alignment readout, all in
## one device and none of it a menu. The player is never told "your alignment is
## -0.4"; they notice that the unkind voice has started getting most of the last
## word. And because both voices are commenting on what just happened, the rules
## of the game arrive as opinions about events the player caused rather than as a
## wall of instructions before they have touched anything.
##
## The game calls exactly one method — `observe(topic, context)` — and everything
## else is this node's problem: which voice answers, whether now is the moment to
## say anything at all, and how the line comes and goes.
##
## Restraint is the whole design. Two voices remarking on every event would be
## unbearable within a minute, so a remark must clear three gates: a minimum gap
## since the last one, a per-topic cooldown so the same observation cannot repeat,
## and a priority high enough to interrupt if the gap has not elapsed. All three
## live in plain fields advanced by `advance(delta)`, so the timing is testable
## without a scene, a frame or a clock.

## Emitted whenever a voice actually speaks. The single hook for anything that
## wants to log, subtitle or re-narrate the remarks.
signal remarked(voice: StringName, topic: StringName, line: String)

## A timestamp older than any session, for "this has never happened".
const NEVER := -1.0e9

@export_group("Restraint")
## Seconds of silence between remarks, unless something important interrupts.
@export var minimum_gap := 7.0
## Seconds before the same topic may be remarked on again.
@export var topic_cooldown := 50.0
## The priority at which a topic is allowed to break `minimum_gap`.
@export var preempt_priority := 4

@export_group("Voices")
## How hard alignment pulls the choice of speaker. 0 is a coin toss for ever, 1
## hands the whole conversation to whichever voice the player has been agreeing
## with. The disagreement is the point, hence the floor below.
@export_range(0.0, 1.0, 0.05) var alignment_bias := 0.8
## The minority voice never drops below this share of remarks. Without a floor a
## cruel god eventually stops hearing any objection, and the device dies.
@export_range(0.0, 0.5, 0.05) var minority_floor := 0.2
## Seeded so a replay of the same session hears the same argument. The
## orchestrator can hand over a shared stream instead with `use_rng`.
## Not @export: GDScript runs member initialisers and _init() before a scene or
## the inspector applies overridden values, so an exported seed would be assigned
## after the generator had already been seeded and would silently do nothing. Use
## use_rng() to share a seeded stream instead.
var rng_seed := 8_146_233

@export_group("Presentation")
@export var fade_time := 0.7
@export var hold_time := 4.5
## Distance from the bottom of the screen. The Mind Inspector owns the top-right
## corner, so the voices live along the bottom where nothing can collide with it.
@export var bottom_margin := 92.0
@export var line_height := 56.0
@export var font_size := 17
@export var outline_size := 6
@export var merciful_colour := Color(0.60, 0.87, 0.72)
@export var cruel_colour := Color(0.93, 0.50, 0.43)

@export_group("Audio")
## Cues chosen by shape rather than meaning, exactly as the rest of the audio
## layer does it: the warm one for mercy, the sharp one for cruelty. Exported so
## they can be swapped the day there are purpose-made voice cues.
@export var merciful_cue: StringName = &"pet"
@export var cruel_cue: StringName = &"slap"

var _alignment := 0.0
var _now := 0.0
var _last_spoke_at := NEVER
var _topic_spoken_at: Dictionary[StringName, float] = {}
## Last alternative used per "topic/voice", so a repeat picks different words.
var _last_index: Dictionary[String, int] = {}
var _remark_count := 0
var _last_voice: StringName = &""
var _last_line := ""
## Seconds since the current remark began, driving the fade envelope.
var _elapsed := 0.0

var _label: Label
var _audio: AudioDirector
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	# Seeded here rather than in _ready so a caller that hands over its own
	# generator between construction and entering the tree is not overwritten.
	_rng.seed = rng_seed


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -(bottom_margin + line_height)
	offset_bottom = -bottom_margin
	# The hand reaches through this node. It must never swallow a click.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


func _process(delta: float) -> void:
	advance(delta)


## The single entry point. `context` may carry `priority` to override the topic's
## own — an ordinary event can be urgent this once (the villager the creature ate
## was the last one alive) without inventing a second topic for it.
func observe(topic: StringName, context: Dictionary = {}) -> void:
	var priority := int(context.get("priority", ConscienceLines.priority_of(topic)))
	if not may_speak(topic, priority):
		return
	var voice := _pick_voice(topic)
	var line := _pick_line(topic, voice)
	# No line means the table has nothing for this topic. Stay silent, and do not
	# spend the rate limit on a remark that never happened.
	if line.is_empty():
		return
	_speak(voice, topic, line)


## Drives the clock and the fade. Called from `_process` in a running game, and
## directly from tests so the timing needs no frames.
func advance(delta: float) -> void:
	_now += delta
	_elapsed += delta
	if _label != null:
		_label.modulate = Color(1.0, 1.0, 1.0, text_alpha())


## Follows the player's alignment, +1 kind to -1 cruel.
func set_alignment(value: float) -> void:
	_alignment = clampf(value, -1.0, 1.0)


## Optional. Null is a perfectly good AudioDirector as far as this node cares.
func bind_audio(director: AudioDirector) -> void:
	_audio = director


## Share the game's seeded stream instead of this node's own generator.
func use_rng(generator: RandomNumberGenerator) -> void:
	if generator != null:
		_rng = generator


## Whether a remark on `topic` would be allowed right now. Public because the
## three gates are the interesting behaviour and deserve to be asserted directly.
func may_speak(topic: StringName, priority: int = -1) -> bool:
	var weight := priority if priority >= 0 else ConscienceLines.priority_of(topic)
	# The topic cooldown is absolute: even an interrupt may not repeat itself.
	if _now - float(_topic_spoken_at.get(topic, NEVER)) < topic_cooldown:
		return false
	if _now - _last_spoke_at < minimum_gap and weight < preempt_priority:
		return false
	return true


## Opacity of the current remark, 0 when nothing is showing. Exposed so the
## envelope can be checked without a rendered frame.
func text_alpha() -> float:
	if _remark_count == 0:
		return 0.0
	var fade := maxf(fade_time, 0.001)
	var total := fade * 2.0 + hold_time
	if _elapsed >= total:
		return 0.0
	if _elapsed < fade:
		return _elapsed / fade
	if _elapsed < fade + hold_time:
		return 1.0
	return (total - _elapsed) / fade


func remark_count() -> int:
	return _remark_count


func last_line() -> String:
	return _last_line


func last_voice() -> StringName:
	return _last_voice


## Which voice answers. Weighted by alignment, floored so the other one keeps
## turning up: a god who only ever hears agreement is being flattered, not
## advised.
func _pick_voice(topic: StringName) -> StringName:
	var cruel_chance := clampf(
		0.5 - _alignment * 0.5 * alignment_bias, minority_floor, 1.0 - minority_floor
	)
	var voice: StringName = (
		ConscienceLines.CRUEL if _rng.randf() < cruel_chance else ConscienceLines.MERCIFUL
	)
	# A voice with nothing to say on this topic yields rather than falling silent.
	if ConscienceLines.lines_for(topic, voice).is_empty():
		voice = ConscienceLines.other_voice(voice)
	return voice


func _pick_line(topic: StringName, voice: StringName) -> String:
	var lines := ConscienceLines.lines_for(topic, voice)
	if lines.is_empty():
		return ""
	var key := "%s/%s" % [topic, voice]
	var index := _rng.randi() % lines.size()
	# Never the same words twice running, whatever the draw says.
	if lines.size() > 1 and index == int(_last_index.get(key, -1)):
		index = (index + 1) % lines.size()
	_last_index[key] = index
	return lines[index]


func _speak(voice: StringName, topic: StringName, line: String) -> void:
	_last_spoke_at = _now
	_topic_spoken_at[topic] = _now
	_remark_count += 1
	_last_voice = voice
	_last_line = line
	_elapsed = 0.0
	if _label != null:
		_label.text = line
		_label.add_theme_color_override(&"font_color", _colour_of(voice))
		_label.modulate = Color(1.0, 1.0, 1.0, text_alpha())
	_play_cue(voice)
	remarked.emit(voice, topic, line)


func _colour_of(voice: StringName) -> Color:
	return merciful_colour if voice == ConscienceLines.MERCIFUL else cruel_colour


func _play_cue(voice: StringName) -> void:
	if _audio == null:
		return
	# The voices are in the player's head, not in the world, so the default
	# position is deliberate — there is nowhere for them to come from.
	_audio.play(cruel_cue if voice == ConscienceLines.CRUEL else merciful_cue)


## One outlined label across the bottom of the screen. Deliberately not a panel:
## a framed box reads as a menu, and the whole point is that the game has none.
##
## Colours go in untouched, as the Mind Inspector's do. The linear-space
## conversion this project applies to 3D albedo does not belong on a theme
## colour, which the UI draws as authored.
func _build() -> void:
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override(&"font_size", font_size)
	# An outline instead of a background, so the line stays legible over grass,
	# sea or a lightning flash without putting a box on the screen.
	_label.add_theme_constant_override(&"outline_size", outline_size)
	_label.add_theme_color_override(&"font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_label.modulate = Color(1.0, 1.0, 1.0, 0.0)
	add_child(_label)
	# After parenting, so the label is stretched against a real rect.
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
