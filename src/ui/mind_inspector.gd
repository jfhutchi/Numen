extends PanelContainer
## The Mind Inspector: a live window into why the creature just did that.
##
## A required deliverable, not a debug nicety. Learning that cannot be inspected
## is indistinguishable from a scripted behaviour tree — this panel is how a
## human confirms the creature is actually reasoning from what it was taught.
##
## Shows, live: every desire's intensity, the option it chose and the score that
## won, the route taken through the firing opinion tree, and recent feedback.

const BAR_WIDTH := 150.0

var _mind: CreatureMind

var _desire_rows: Dictionary[StringName, ProgressBar] = {}
var _choice_label: RichTextLabel
var _path_label: RichTextLabel
var _feedback_label: RichTextLabel
var _state_label: Label


func _ready() -> void:
	custom_minimum_size = Vector2(370.0, 0.0)
	_build()


func bind(mind: CreatureMind) -> void:
	_mind = mind


func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	root.add_child(_heading("CREATURE MIND"))

	_state_label = Label.new()
	_state_label.add_theme_font_size_override("font_size", 12)
	root.add_child(_state_label)

	root.add_child(_heading("Desires"))
	for desire: StringName in Desires.ALL:
		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = String(desire)
		name_label.custom_minimum_size = Vector2(96.0, 0.0)
		name_label.add_theme_font_size_override("font_size", 12)
		row.add_child(name_label)

		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.custom_minimum_size = Vector2(BAR_WIDTH, 14.0)
		bar.show_percentage = false
		row.add_child(bar)

		var value_label := Label.new()
		value_label.name = "Value"
		value_label.add_theme_font_size_override("font_size", 12)
		row.add_child(value_label)

		_desire_rows[desire] = bar
		root.add_child(row)

	root.add_child(_heading("Chose"))
	_choice_label = _text_block(52.0)
	root.add_child(_choice_label)

	root.add_child(_heading("Why — path through the opinion tree"))
	_path_label = _text_block(84.0)
	root.add_child(_path_label)

	root.add_child(_heading("Recent feedback"))
	_feedback_label = _text_block(96.0)
	root.add_child(_feedback_label)


func _process(_delta: float) -> void:
	if _mind == null or not visible:
		return
	_refresh()


func _refresh() -> void:
	_state_label.text = (
		"hunger %.2f   fatigue %.2f   idle %.2f\nage %.0fs   alignment %+.2f   temp %.2f"
		% [
			_mind.hunger, _mind.fatigue, _mind.idle,
			_mind.age_seconds, _mind.alignment, _mind.temperature(),
		]
	)

	var levels: Dictionary[StringName, float] = _mind.desires.intensities(_mind.situation())
	for desire: StringName in _desire_rows:
		var bar: ProgressBar = _desire_rows[desire]
		var level: float = levels.get(desire, 0.0)
		bar.value = level
		var value_label: Label = bar.get_parent().get_node_or_null(^"Value")
		if value_label != null:
			value_label.text = "%.2f" % level

	var choice: CreatureMind.Option = _mind.last_choice()
	if choice == null:
		_choice_label.text = "[i]nothing in reach[/i]"
		_path_label.text = ""
	else:
		_choice_label.text = (
			"[b]%s[/b]\ndesire %.2f  ×  opinion [color=%s]%+.2f[/color]  ÷  dist %.1fm"
			+ "\nscore [b]%+.3f[/b]   p=[b]%.1f%%[/b]"
		) % [
			choice.describe(),
			choice.desire_level,
			"#7fdc8a" if choice.opinion >= 0.0 else "#e07a70",
			choice.opinion,
			choice.distance,
			choice.score,
			choice.probability * 100.0,
		]
		_path_label.text = _format_path(choice)

	_feedback_label.text = _format_feedback()


## Renders the actual route taken down the opinion tree. If this is empty the
## creature has no experience of that pair yet, which is itself worth seeing.
func _format_path(choice: CreatureMind.Option) -> String:
	if choice.object == null:
		return "[i]no object[/i]"
	var belief: PackedFloat32Array = _mind.beliefs.belief_for(choice.object)
	var path: Array[Dictionary] = _mind.opinions.decision_path(
		choice.desire, choice.action, belief
	)
	if path.is_empty():
		return "[i]no experience of %s yet — acting on instinct[/i]" % choice.action

	var lines: PackedStringArray = []
	for step: Dictionary in path:
		if step.has("leaf"):
			lines.append("→ expects [b]%+.2f[/b]  (%d memories)" % [
				float(step["value"]), int(step["samples"])
			])
		else:
			lines.append("%s = %.2f (%s)" % [
				ObjectAttributes.name_of(int(step["attribute"])),
				float(step["observed"]),
				["low", "mid", "high"][int(step["bin"])],
			])
	return "\n".join(lines)


func _format_feedback() -> String:
	var entries: Array[Dictionary] = _mind.recent_feedback()
	if entries.is_empty():
		return "[i]nothing yet[/i]"
	var lines: PackedStringArray = []
	# Newest first — the last thing that happened is what you are looking for.
	for i in range(entries.size() - 1, maxi(entries.size() - 7, 0) - 1, -1):
		var entry: Dictionary = entries[i]
		var value: float = float(entry["value"])
		lines.append("[color=%s]%+.2f[/color] %s(%s) ×%.2f [%s]" % [
			"#7fdc8a" if value >= 0.0 else "#e07a70",
			value,
			entry["action"],
			entry["desire"],
			float(entry["weight"]),
			entry["source"],
		])
	return "\n".join(lines)


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.62, 0.78, 0.95))
	return label


func _text_block(height: float) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.custom_minimum_size = Vector2(0.0, height)
	label.add_theme_font_size_override("normal_font_size", 12)
	label.add_theme_font_size_override("bold_font_size", 12)
	label.add_theme_font_size_override("italics_font_size", 12)
	return label
