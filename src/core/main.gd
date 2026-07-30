extends Node3D
## Game root. Assembles the island, two villages, the creature, the divine hand,
## the miracle system and the save layer, and wires them to each other.
##
## The world is built in code rather than authored as a .tscn because it is
## procedural anyway — there is nothing a designer would hand-place, and a scene
## file would just be a second place for the same numbers to drift.

const ISLAND := preload("res://src/world/island.gd")
const SCATTER := preload("res://src/world/scatter.gd")
const CAMERA_RIG := preload("res://src/hand/camera_rig.gd")
const HAND := preload("res://src/hand/hand.gd")
const CREATURE := preload("res://src/creature/body/creature.gd")
const MIND_INSPECTOR := preload("res://src/ui/mind_inspector.gd")
const VILLAGE := preload("res://src/village/village.gd")
const CONSCIENCE := preload("res://src/ui/conscience.gd")
const TUTORIAL := preload("res://src/ui/tutorial.gd")
const GESTURE_GUIDE := preload("res://src/ui/gesture_guide.gd")
const CREATURE_THOUGHT := preload("res://src/ui/creature_thought.gd")
const AUDIO_DIRECTOR := preload("res://src/audio/audio_director.gd")

const SAVE_PATH := "user://numen_save.json"
const WATER_SHADER := "res://src/world/water.gdshader"
## Gestures are drawn with the middle mouse button: left is the hand, right is
## the camera, and a modifier would collide with both.
const GESTURE_BUTTON := MOUSE_BUTTON_MIDDLE
## Screen pixels the pointer must travel before a stroke counts as a gesture
## rather than a stray click.
const MIN_STROKE_LENGTH := 40.0

## What the creature can learn to do by watching each miracle, in the mind's own
## action vocabulary. Only miracles whose effect the creature could imitate are
## listed: it can heal and water, but it cannot conjure food from nothing, so food
## and wood teach it nothing and are deliberately absent.
const MIRACLE_LESSONS: Dictionary = {
	&"heal": &"heal",
	&"water": &"water_field",
	&"lightning": &"attack",
}

var island: Node3D
var scatter: Node3D
var camera_rig: Node3D
var hand: Node3D
var creature: CharacterBody3D
var inspector: PanelContainer
var conscience: Conscience
var tutorial: Tutorial
var gesture_guide: GestureGuide
var thought: CreatureThought
var audio: AudioDirector

var home_village: Node3D
var rival_village: Node3D

var prayer: PrayerPower
var influence: Influence
var library: MiracleLibrary
var effects: MiracleEffects
var caster: MiracleCaster
var recognizer: GestureRecognizer
var conversion: Conversion
var alignment: AlignmentTracker
var saves: SaveManager

var _registry: Node
var _hud_label: Label
var _status_label: Label
var _stroke: Line2D
## The stroke drawn in the world itself, at terrain height under the pointer. The
## 2D line stays as the recogniser's input record; this is presentation.
var _trail: GestureTrail
## Last alignment descriptor seen, so drift is reported on the change rather than
## every frame it stays true.
var _last_descriptor: String = ""
var _idle_seconds: float = 0.0
## Seconds of the player doing nothing before the voices suggest something.
var _idle_nudge_after: float = 25.0
## Food in the home store below which the village counts as going hungry.
var _hungry_food_threshold: float = 20.0

var _drawing: bool = false
var _stroke_points: PackedVector2Array = PackedVector2Array()
var _influence_ring: InfluenceRing


func _ready() -> void:
	# Fetched by path rather than by the `World` autoload identifier: naming the
	# singleton directly makes this script fail to compile anywhere the autoload
	# is not registered, which includes test runs that merely load the scene.
	_registry = get_node(^"/root/World")
	_hud_label = $BootLayer/BootLabel

	_build_environment()

	island = ISLAND.new()
	island.name = "Island"
	add_child(island)
	island.generate()

	_build_water()

	scatter = SCATTER.new()
	scatter.name = "Scatter"
	add_child(scatter)
	scatter.populate(island, _registry)

	# Built and tested in an earlier phase and called by absolutely nothing until
	# now. Created early so the creature and the UI can both be handed it.
	audio = AUDIO_DIRECTOR.new()
	audio.name = "Audio"
	add_child(audio)
	audio.start_ambient()

	_build_villages()
	_scatter_food()

	camera_rig = CAMERA_RIG.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.set_island(island)
	camera_rig.set_focus(home_village.centre_position())

	hand = HAND.new()
	hand.name = "Hand"
	add_child(hand)
	hand.configure(camera_rig.camera, island, scatter, _registry)
	hand.grabbed.connect(_on_grabbed)
	hand.released.connect(_on_released)

	_spawn_creature()
	_build_miracles()
	_build_save_layer()
	_build_ui()

	# The home village already believes; the rival is the one to win over.
	#
	# Seeded here rather than in _build_miracles because crossing the conversion
	# threshold emits village_converted, which the conscience listens for — and the
	# conscience does not exist until _build_ui has run. Doing it during
	# construction called observe() on a null and aborted _ready half-built.
	conversion.add_belief(&"home", 40.0)

	print("\n".join(boot_report()))


func _process(delta: float) -> void:
	# Prayer accrues from everyone worshipping in the home village, and belief
	# widens the ring the player may act inside.
	prayer.accrue(home_village.worshipper_count(), delta)
	conversion.advance(delta)
	influence.set_belief(conversion.total_belief())
	_update_influence_ring()
	_update_status()
	_update_advisors(delta)


## Feeds the voices, the guide and the tutorial the state they watch.
func _update_advisors(delta: float) -> void:
	conscience.set_alignment(alignment.value())
	gesture_guide.update_prayer(prayer.current())

	# Drift is reported off AlignmentTracker.descriptor(), which already owns a
	# threshold, rather than inventing a second one here that could disagree with
	# the words the HUD is showing.
	var descriptor: String = alignment.descriptor()
	if descriptor != _last_descriptor:
		_last_descriptor = descriptor
		if descriptor == "merciful":
			conscience.observe(&"drifting_kind")
		elif descriptor == "cruel":
			conscience.observe(&"drifting_cruel")

	if home_village.store.stock_of(&"food") < _hungry_food_threshold:
		conscience.observe(&"village_hungry")

	# An idle nudge only when the player is doing nothing, so it suggests rather
	# than interrupts. The conscience's own rate limiting stops it nagging.
	if camera_rig.pan_input() != Vector2.ZERO:
		tutorial.notify(Tutorial.EV_CAMERA_PANNED, {"delta": delta})
		_idle_seconds = 0.0

	_idle_seconds += delta
	if _idle_seconds > _idle_nudge_after:
		_idle_seconds = 0.0
		conscience.observe(&"idle_nudge")


# --- construction -------------------------------------------------------------

func _build_villages() -> void:
	home_village = VILLAGE.new()
	home_village.name = "HomeVillage"
	add_child(home_village)
	home_village.populate(island, _registry, _master_seed())
	home_village.born.connect(_on_villager_born)
	home_village.died.connect(_on_villager_died)

	# A second village to convert — Definition of Done item 8. Settled away from
	# the first by biasing its site search; it still refuses unsuitable ground.
	rival_village = VILLAGE.new()
	rival_village.name = "RivalVillage"
	rival_village.search_origin = Vector3(island.extent * 0.26, 0.0, -island.extent * 0.26)
	add_child(rival_village)
	rival_village.populate(island, _registry, _master_seed() + 991)


func _scatter_food() -> void:
	# Loose food for the creature to find, distinct from the villages' stores.
	# The creature needs something edible in the world that is not a person, or
	# the only thing it can learn about eating is the thing we hope it will not.
	var rng := RandomNumberGenerator.new()
	rng.seed = _master_seed() + 17
	for i in 16:
		var spot: Vector3 = _random_land_point(rng)
		var object: WorldObject = _registry.add(&"food_pile", spot)
		var marker := MeshInstance3D.new()
		marker.name = "Food_%d" % object.id
		var mesh := SphereMesh.new()
		mesh.radius = 0.45
		mesh.height = 0.9
		marker.mesh = mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.88, 0.74, 0.30).srgb_to_linear()
		material.roughness = 0.9
		marker.material_override = material
		marker.position = spot + Vector3.UP * 0.45
		add_child(marker)
		object.node = marker


func _spawn_creature() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _master_seed() + 7
	creature = CREATURE.new()
	creature.name = "Creature"
	add_child(creature)
	# Beside the home village, so the first thing it meets is the people the
	# player will be teaching it about — but only if that spot is dry. A blind
	# offset put it in the sea whenever the village settled near a shore, and it
	# sank without a floor to catch it.
	creature.global_position = _land_near(
		home_village.centre_position(), 9.0
	) + Vector3.UP * 1.5
	creature.configure(_registry, island, null, _master_seed())
	creature.chose.connect(_on_creature_chose)

	var self_entry: WorldObject = _registry.add(&"creature", creature.global_position, creature)
	creature.mind.self_object_id = self_entry.id
	creature.acted_on.connect(_on_creature_acted)
	creature.feedback_shown.connect(_on_creature_feedback)

	# What the creature wants, over its head, so the player can watch an intention
	# form and intervene before it acts. The Mind Inspector verifies the AI; this is
	# for playing with it.
	thought = CREATURE_THOUGHT.new()
	thought.name = "Thought"
	creature.add_child(thought)
	thought.bind(creature.mind)


func _build_miracles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _master_seed() + 31

	prayer = PrayerPower.new()
	influence = Influence.new(null, home_village.centre_position())
	library = MiracleLibrary.new()
	# BOTH villages, not just the home one. They share the object registry, so a
	# miracle cast over the rival village finds its fields and villagers and plays
	# an effect on them — but with only home_village bound, nothing actually
	# changed and the cast reported zero. Casting kind miracles near the rival is
	# precisely how its belief is earned, so that was the main path broken.
	effects = MiracleEffects.new(_registry, rng, [home_village, rival_village])
	caster = MiracleCaster.new(prayer, influence, library)
	caster.bind_effects(effects)
	caster.cast_performed.connect(_on_cast_performed)
	caster.cast_refused.connect(_on_cast_refused)

	recognizer = GestureRecognizer.new()
	recognizer.load_default_templates()

	conversion = Conversion.new()
	conversion.register_village(&"home", home_village.centre_position(), home_village.population())
	conversion.register_village(&"rival", rival_village.centre_position(), rival_village.population())
	conversion.village_converted.connect(_on_village_converted)

	alignment = AlignmentTracker.new()

	# The third shape this ring has worn. The torus intersected hills as a blue
	# band; a flat shader disc was depth-tested away by the terrain over land. The
	# ribbon drapes the boundary over the ground itself.
	_influence_ring = InfluenceRing.new()
	_influence_ring.set_island(island)
	add_child(_influence_ring)


func _build_save_layer() -> void:
	saves = SaveManager.new()
	# CreatureMind, PrayerPower and Influence predate the save contract and
	# expose only to_dict/from_dict, so the wiring names them. Conversion,
	# AlignmentTracker and RegistrySnapshot carry their own save_id().
	saves.register_as(&"creature_mind", creature.mind)
	saves.register_as(&"prayer", prayer)
	saves.register_as(&"influence", influence)
	saves.register(conversion)
	saves.register(alignment)
	saves.register(RegistrySnapshot.new(_registry))


func _build_ui() -> void:
	inspector = MIND_INSPECTOR.new()
	inspector.name = "MindInspector"
	inspector.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	inspector.position = Vector2(-386.0, 12.0)
	inspector.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	$BootLayer.add_child(inspector)
	inspector.bind(creature.mind)

	# The two voices. Alignment comes from the AlignmentTracker, NOT from
	# creature.mind.alignment: those are deliberately different numbers, and
	# src/village/alignment_tracker.gd exists to say so. The creature's EMA is what
	# it was *rewarded* for; the tracker is what the *player* did. A god who slaps
	# their creature for every kindness should hear the cruel voice while the
	# creature itself reads as meek — feeding the creature's number here would have
	# had that player comforted by the merciful voice 80% of the time.
	conscience = CONSCIENCE.new()
	conscience.name = "Conscience"
	$BootLayer.add_child(conscience)
	conscience.bind_audio(audio)
	conscience.set_alignment(alignment.value())
	conscience.observe(&"first_boot")

	tutorial = TUTORIAL.new()
	tutorial.name = "Tutorial"
	$BootLayer.add_child(tutorial)

	gesture_guide = GESTURE_GUIDE.new()
	gesture_guide.name = "GestureGuide"
	$BootLayer.add_child(gesture_guide)
	gesture_guide.bind_library(library)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.position = Vector2(16.0, 220.0)
	_status_label.add_theme_font_size_override("font_size", 13)
	$BootLayer.add_child(_status_label)

	_trail = GestureTrail.new()
	_trail.set_island(island)
	add_child(_trail)

	# The stroke the player is drawing, so a gesture is something you can see
	# rather than something you hope registered.
	_stroke = Line2D.new()
	_stroke.name = "GestureStroke"
	_stroke.width = 3.0
	_stroke.default_color = Color(0.75, 0.86, 1.0, 0.9)
	$BootLayer.add_child(_stroke)

	_hud_label.text = "\n".join(boot_report())


# --- input --------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		# Reported here rather than from the rig: the rig does not know the drag was
		# the player's doing, and set_focus() is called programmatically too.
		tutorial.notify(
			Tutorial.EV_CAMERA_ORBITED,
			{"pixels": (event as InputEventMouseMotion).relative.length()}
		)

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == GESTURE_BUTTON:
			if button.pressed:
				_begin_stroke(button.position)
			else:
				_finish_stroke()
			return
	elif event is InputEventMouseMotion and _drawing:
		_extend_stroke((event as InputEventMouseMotion).position)
		return

	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).keycode:
		KEY_P:
			creature.pet()
			_hud_label.text = "petted the creature"
		KEY_L:
			creature.slap()
			_hud_label.text = "slapped the creature"
		KEY_1:
			creature.set_leash(creature.LEASH_NONE)
			_hud_label.text = "leash: none"
		KEY_2:
			creature.set_leash(creature.LEASH_LEARNING)
			_hud_label.text = "leash: learning"
		KEY_3:
			creature.set_leash(creature.LEASH_COMPASSION)
			_hud_label.text = "leash: compassion"
		KEY_4:
			creature.set_leash(creature.LEASH_AGGRESSION)
			_hud_label.text = "leash: aggression"
		KEY_F:
			# The creature roams a 160 m island and there is no follow-cam, so
			# without this the first thing a player does is hunt for it.
			camera_rig.set_focus(creature.global_position)
			_hud_label.text = "camera on the creature"
			tutorial.notify(Tutorial.EV_CREATURE_FOUND)
		KEY_G:
			gesture_guide.toggle()
		KEY_V:
			camera_rig.set_focus(home_village.centre_position())
			_hud_label.text = "camera on the village"
		KEY_TAB:
			inspector.visible = not inspector.visible
			if inspector.visible:
				tutorial.notify(Tutorial.EV_INSPECTOR_OPENED)
		KEY_F5:
			_hud_label.text = (
				"saved to %s" % SAVE_PATH if saves.save_to(SAVE_PATH) == OK
				else "save failed: %s" % saves.last_error()
			)
		KEY_F9:
			_hud_label.text = (
				"loaded %s" % SAVE_PATH if saves.load_from(SAVE_PATH) == OK
				else "load failed: %s" % saves.last_error()
			)


func _begin_stroke(at: Vector2) -> void:
	_drawing = true
	_stroke_points = PackedVector2Array([at])
	_stroke.points = _stroke_points
	_trail.begin()
	_trail.extend(hand.hand_point())


func _extend_stroke(at: Vector2) -> void:
	_stroke_points.append(at)
	_stroke.points = _stroke_points
	_trail.extend(hand.hand_point())


## Recognises the drawn stroke and casts the miracle it names, at the ground
## point under where the stroke ended.
func _finish_stroke() -> void:
	_drawing = false
	_stroke.points = PackedVector2Array()
	_trail.end_stroke()
	if _stroke_points.size() < 4 or _stroke_length() < MIN_STROKE_LENGTH:
		_stroke_points = PackedVector2Array()
		return

	var result: Dictionary = recognizer.recognize(_stroke_points)
	_stroke_points = PackedVector2Array()
	if result.is_empty():
		return

	# A confidence floor, or every scribble spends prayer power on whichever
	# miracle happens to be nearest in point-cloud distance.
	if not recognizer.is_confident(result):
		_hud_label.text = "gesture not recognised (best %s, %.2f)" % [
			result.get("name", "?"), float(result.get("score", 0.0))
		]
		return

	var target: Vector3 = hand.hand_point()
	var cast: Dictionary = caster.cast_from_gesture(result["name"], target)
	if not bool(cast.get("ok", false)):
		_hud_label.text = "%s refused: %s" % [result["name"], cast.get("reason", "?")]


func _stroke_length() -> float:
	var total: float = 0.0
	for i in range(1, _stroke_points.size()):
		total += _stroke_points[i].distance_to(_stroke_points[i - 1])
	return total


# --- reactions ----------------------------------------------------------------

## What the creature just did, translated for the voices, the tutorial and the ear.
func _on_creature_acted(action: StringName, object: WorldObject) -> void:
	audio.play(AudioCues.for_creature_action(action), creature.global_position)
	if object == null:
		return
	match action:
		&"eat":
			conscience.observe(
				&"creature_ate_villager" if object.type == &"villager" else &"creature_ate_food"
			)
		&"attack":
			conscience.observe(&"creature_attacked")
		&"sleep":
			conscience.observe(&"creature_slept")


func _on_creature_feedback(value: float) -> void:
	if value >= 0.0:
		conscience.observe(&"petted")
		audio.play(&"pet", creature.global_position)
		return
	conscience.observe(&"slapped")
	audio.play(&"slap", creature.global_position)
	tutorial.notify(Tutorial.EV_CREATURE_SLAPPED)
	# The step after slapping asks the player to see the opinion move, which is the
	# one moment the whole project turns on. The mind has already recorded the
	# feedback by the time this fires, so the change is real, not anticipated.
	tutorial.notify(Tutorial.EV_OPINION_CHANGED)


func _on_cast_performed(result: Dictionary) -> void:
	var miracle: Miracle = library.by_id(result.get("id", &""))
	# The signature action of the whole genre, invisible until now. The effect
	# frees itself when its emitters finish; a cast per second accumulates nothing.
	MiracleVfx.for_miracle(result.get("id", &"")).play_at(
		self, result.get("at", Vector3.ZERO)
	)
	if miracle != null:
		# Miracles shape the player's alignment, and impressive acts near a
		# village earn its belief. Both read the same signed weight.
		alignment.record(miracle.alignment_weight)
		conversion.record_act(result.get("at", Vector3.ZERO), absf(miracle.alignment_weight) * 12.0)
		# miracle_topic() falls back to a generic topic, so a sixth miracle gets a
		# remark rather than silence.
		conscience.observe(ConscienceLines.miracle_topic(miracle.id))
		audio.play(AudioCues.for_miracle(miracle.id), result.get("at", Vector3.ZERO))
		_teach_from_miracle(miracle, result)
	tutorial.notify(Tutorial.EV_MIRACLE_CAST)
	_hud_label.text = "cast %s" % result.get("id", "?")


## Teaching by demonstration: the player heals a villager while the creature
## watches, and the creature learns that healing villagers is a good thing to do.
##
## This is the closest thing the genre had to a thesis — you taught the creature by
## doing, not by pressing buttons — and until now it was reachable only by
## accident, from a single hardcoded call when a thrown object happened to be
## released. The actions used are the mind's own vocabulary, so what the creature
## learns here is the same knowledge it consults when choosing for itself.
func _teach_from_miracle(miracle: Miracle, result: Dictionary) -> void:
	var action: StringName = MIRACLE_LESSONS.get(miracle.id, &"")
	if action == &"":
		return
	# Only what the miracle actually touched, so a heal cast over open ground
	# teaches nothing rather than teaching something false.
	for id: Variant in result.get("affected", []):
		var object: WorldObject = _registry.get_object(int(id))
		if object == null:
			continue
		# Signed by the miracle's own moral weight, so the creature draws the same
		# conclusion the alignment tracker does and the two cannot disagree.
		if creature.witness(action, object, signf(miracle.alignment_weight) * 0.7):
			_hud_label.text = "the creature watched you %s" % action


func _on_cast_refused(result: Dictionary) -> void:
	_hud_label.text = "refused: %s" % result.get("reason", "?")
	conscience.observe(&"miracle_refused")
	audio.play(&"miracle_refused")


func _on_village_converted(village_id: StringName) -> void:
	_hud_label.text = "the %s village believes in you" % village_id
	conscience.observe(&"village_converted")


func _on_villager_born(_villager: Villager) -> void:
	conscience.observe(&"villager_born")
	audio.play(&"born", home_village.centre_position())


func _on_villager_died(_villager: Villager) -> void:
	conscience.observe(&"villager_died")
	audio.play(&"died", home_village.centre_position())


func _on_grabbed(object: WorldObject) -> void:
	_hud_label.text = "holding %s" % object
	conscience.observe(&"grabbed")
	audio.play(&"pick_up", hand.hand_point())
	tutorial.notify(Tutorial.EV_OBJECT_GRABBED)


func _on_released(object: WorldObject, throw_velocity: Vector3) -> void:
	_hud_label.text = "threw %s at %.1f m/s" % [object, throw_velocity.length()]
	conscience.observe(&"threw")
	audio.play(&"throw", hand.hand_point())
	tutorial.notify(Tutorial.EV_OBJECT_THROWN)
	# The creature watches what the player does with the world. Off the leash of
	# learning this is only weak imitation.
	# Throwing a person is cruel; throwing a rock is just throwing a rock. The
	# creature should learn the distinction rather than that throwing is bad.
	var lesson: float = -0.6 if object.type == &"villager" else 0.15
	if creature.witness(&"throw", object, lesson):
		_hud_label.text = "%s — the creature was watching" % _hud_label.text


func _on_creature_chose(option: CreatureMind.Option) -> void:
	_hud_label.text = "creature: %s  (p=%.0f%%)" % [option.describe(), option.probability * 100.0]
	tutorial.notify(Tutorial.EV_CREATURE_CHOSE)


# --- presentation -------------------------------------------------------------

func _update_influence_ring() -> void:
	_influence_ring.set_centre(influence.centre)
	_influence_ring.set_radius(influence.radius)
	# Brightness follows prayer: a ring that dims as power runs out tells the
	# player they cannot cast before the refusal does.
	_influence_ring.set_strength(prayer.fraction())


func _update_status() -> void:
	_status_label.text = (
		"prayer %.0f/%.0f    belief %.0f    alignment %+.2f (%s)\n"
		+ "villages: home %d, rival %d    converted %d/2"
	) % [
		prayer.current(), prayer.maximum,
		conversion.total_belief(),
		alignment.value(), alignment.descriptor(),
		home_village.population(), rival_village.population(),
		conversion.converted_count(),
	]


## A dry spot roughly `radius` from `origin`, tried around a full circle before
## giving up and returning the origin itself.
func _land_near(origin: Vector3, radius: float) -> Vector3:
	for i in 12:
		var angle: float = TAU * float(i) / 12.0
		var x: float = origin.x + cos(angle) * radius
		var z: float = origin.z + sin(angle) * radius
		var h: float = island.height_at(x, z)
		if h > 1.0:
			return Vector3(x, h, z)
	return origin


func _random_land_point(rng: RandomNumberGenerator) -> Vector3:
	var half: float = island.extent * 0.35
	for attempt in 64:
		var x: float = rng.randf_range(-half, half)
		var z: float = rng.randf_range(-half, half)
		var h: float = island.height_at(x, z)
		if h > 1.0 and h < 16.0:
			return Vector3(x, h, z)
	return Vector3(0.0, maxf(island.height_at(0.0, 0.0), 1.0), 0.0)


func _master_seed() -> int:
	var service: Node = get_node_or_null(^"/root/Rng")
	return service.get_master_seed() if service != null else 20260729


func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_horizon_color = Color(0.68, 0.75, 0.82)
	sky_material.ground_horizon_color = Color(0.55, 0.58, 0.55)
	sky_material.sky_top_color = Color(0.28, 0.47, 0.78)
	# A visible sun, and clouds. The sky was a bare two-colour gradient, which gave
	# the island nothing to sit under.
	sky_material.sun_angle_max = 6.0
	sky_material.sun_curve = 0.12
	sky_material.use_debanding = true

	var sky := Sky.new()
	sky.sky_material = sky_material

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.6
	environment.fog_enabled = true
	# Enough haze to swallow the water plane's far edge at the horizon, and no more.
	# 0.0035 was tuned when there was no tonemapping and nothing else lifting the
	# image; with filmic tonemapping and glow on top it washed the whole scene to
	# pale grey and the island lost its colour entirely.
	environment.fog_density = 0.0007
	environment.fog_sky_affect = 0.35
	environment.fog_aerial_perspective = 0.25
	environment.fog_light_color = Color(0.72, 0.78, 0.84)

	# Everything below is new. The game had fog and ambient light and nothing else:
	# no tonemapping, no glow, no occlusion, so flat-shaded low-poly rendered
	# genuinely flat and objects appeared to hover rather than sit on the ground.
	#
	# Filmic rather than linear, so the sky and the surf highlights roll off instead
	# of clipping to white.
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.0
	environment.tonemap_white = 2.4

	# Contact shadow where geometry meets geometry. This is the single cheapest
	# thing that makes low-poly read as solid: without it a hut and the hill behind
	# it are two flat greens meeting at a line.
	environment.ssao_enabled = true
	environment.ssao_radius = 2.2
	environment.ssao_intensity = 2.6
	environment.ssao_power = 1.6
	environment.ssao_detail = 0.4

	# Kept subtle. It exists mostly for the miracle VFX of the next phase, which
	# need somewhere bright to bloom into; on the landscape it only catches the sun
	# and the surf.
	environment.glow_enabled = true
	environment.glow_intensity = 0.5
	environment.glow_bloom = 0.08
	environment.glow_hdr_threshold = 1.05
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	# A touch of saturation, because filmic tonemapping desaturates and the palette
	# is the flat-colour kind that needs its greens.
	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.12
	environment.adjustment_contrast = 1.04

	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-52.0), deg_to_rad(38.0), 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	# The default 100-unit shadow range is far shorter than this island is wide, so
	# the split boundary cut a visible hard edge across the world. Four splits over
	# 520 units covers the island and its approaches, and the fade takes the edge off
	# what is left.
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 520.0
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.16
	sun.directional_shadow_split_3 = 0.42
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.92
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.4
	add_child(sun)


func _build_water() -> void:
	var plane := PlaneMesh.new()
	# Wide enough that its edge is never on screen at full zoom-out.
	plane.size = Vector2(island.extent * 10.0, island.extent * 10.0)

	var water := MeshInstance3D.new()
	water.name = "Water"
	water.mesh = plane

	# The sea used to be a flat translucent StandardMaterial3D — a sheet of blue
	# plastic that framed every screenshot. The shader reconstructs how deep the
	# water is at each pixel and drives colour, transparency and a surf line off
	# that, so the shore reads as shallow without anything telling it where the
	# shore is.
	if ResourceLoader.exists(WATER_SHADER):
		var shaded := ShaderMaterial.new()
		shaded.shader = load(WATER_SHADER)
		water.material_override = shaded
	else:
		var fallback := StandardMaterial3D.new()
		fallback.albedo_color = Color(0.13, 0.32, 0.44, 0.80)
		fallback.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fallback.roughness = 0.12
		fallback.metallic = 0.25
		water.material_override = fallback

	# A 1600-unit transparent plane must not cast shadow. It was throwing a hard
	# wedge of shade right across the sea and a slab of it over the island — a
	# shadow from the very surface you are looking through.
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)


## Returns the boot banner as lines. Split out so headless tests can assert on
## it without instancing the scene's UI.
static func boot_report() -> PackedStringArray:
	return PackedStringArray([
		"NUMEN",
		"Godot %s" % Engine.get_version_info().get("string", "unknown"),
		"3D physics: %s" % physics_engine_name(),
		"",
		"Left mouse: grab / throw    Right mouse: orbit    Wheel: zoom    WASD/arrows: pan",
		"Middle mouse drag: draw a miracle gesture",
		"P: pet    L: slap    1-4: leash    F: find creature    V: find village",
		"Tab: mind inspector    F5: save    F9: load",
	])


static func physics_engine_name() -> String:
	return str(ProjectSettings.get_setting("physics/3d/physics_engine", "<unset>"))
