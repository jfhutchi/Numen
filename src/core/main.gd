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

const SAVE_PATH := "user://numen_save.json"
## Gestures are drawn with the middle mouse button: left is the hand, right is
## the camera, and a modifier would collide with both.
const GESTURE_BUTTON := MOUSE_BUTTON_MIDDLE
## Screen pixels the pointer must travel before a stroke counts as a gesture
## rather than a stray click.
const MIN_STROKE_LENGTH := 40.0

var island: Node3D
var scatter: Node3D
var camera_rig: Node3D
var hand: Node3D
var creature: CharacterBody3D
var inspector: PanelContainer

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
var _drawing: bool = false
var _stroke_points: PackedVector2Array = PackedVector2Array()
var _influence_ring: MeshInstance3D


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

	print("\n".join(boot_report()))


func _process(delta: float) -> void:
	# Prayer accrues from everyone worshipping in the home village, and belief
	# widens the ring the player may act inside.
	prayer.accrue(home_village.worshipper_count(), delta)
	conversion.advance(delta)
	influence.set_belief(conversion.total_belief())
	_update_influence_ring()
	_update_status()


# --- construction -------------------------------------------------------------

func _build_villages() -> void:
	home_village = VILLAGE.new()
	home_village.name = "HomeVillage"
	add_child(home_village)
	home_village.populate(island, _registry, _master_seed())

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
	# player will be teaching it about.
	creature.global_position = home_village.centre_position() + Vector3(9.0, 1.5, 9.0)
	creature.configure(_registry, island, null, _master_seed())
	creature.chose.connect(_on_creature_chose)

	var self_entry: WorldObject = _registry.add(&"creature", creature.global_position, creature)
	creature.mind.self_object_id = self_entry.id


func _build_miracles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _master_seed() + 31

	prayer = PrayerPower.new()
	influence = Influence.new(null, home_village.centre_position())
	library = MiracleLibrary.new()
	# The village must be passed, or a wood miracle silently grows trees on the
	# village square instead of filling the storehouse.
	effects = MiracleEffects.new(_registry, rng, home_village)
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
	# The home village already believes; the rival is the one to win over.
	conversion.add_belief(&"home", 40.0)

	alignment = AlignmentTracker.new()

	_influence_ring = MeshInstance3D.new()
	_influence_ring.name = "InfluenceRing"
	var ring := TorusMesh.new()
	ring.inner_radius = 0.9
	ring.outer_radius = 1.0
	_influence_ring.mesh = ring
	var ring_material := StandardMaterial3D.new()
	ring_material.albedo_color = Color(0.55, 0.75, 1.0, 0.45).srgb_to_linear()
	ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_influence_ring.material_override = ring_material
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

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.position = Vector2(16.0, 128.0)
	_status_label.add_theme_font_size_override("font_size", 13)
	$BootLayer.add_child(_status_label)

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
		KEY_V:
			camera_rig.set_focus(home_village.centre_position())
			_hud_label.text = "camera on the village"
		KEY_TAB:
			inspector.visible = not inspector.visible
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


func _extend_stroke(at: Vector2) -> void:
	_stroke_points.append(at)
	_stroke.points = _stroke_points


## Recognises the drawn stroke and casts the miracle it names, at the ground
## point under where the stroke ended.
func _finish_stroke() -> void:
	_drawing = false
	_stroke.points = PackedVector2Array()
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

func _on_cast_performed(result: Dictionary) -> void:
	var miracle: Miracle = library.by_id(result.get("id", &""))
	if miracle != null:
		# Miracles shape the player's alignment, and impressive acts near a
		# village earn its belief. Both read the same signed weight.
		alignment.record(miracle.alignment_weight)
		conversion.record_act(result.get("at", Vector3.ZERO), absf(miracle.alignment_weight) * 12.0)
	_hud_label.text = "cast %s" % result.get("id", "?")


func _on_cast_refused(result: Dictionary) -> void:
	_hud_label.text = "refused: %s" % result.get("reason", "?")


func _on_village_converted(village_id: StringName) -> void:
	_hud_label.text = "the %s village believes in you" % village_id


func _on_grabbed(object: WorldObject) -> void:
	_hud_label.text = "holding %s" % object


func _on_released(object: WorldObject, throw_velocity: Vector3) -> void:
	_hud_label.text = "threw %s at %.1f m/s" % [object, throw_velocity.length()]
	# The creature watches what the player does with the world. Off the leash of
	# learning this is only weak imitation.
	creature.witness(&"throw", object, -0.2)


func _on_creature_chose(option: CreatureMind.Option) -> void:
	_hud_label.text = "creature: %s  (p=%.0f%%)" % [option.describe(), option.probability * 100.0]


# --- presentation -------------------------------------------------------------

func _update_influence_ring() -> void:
	var centre: Vector3 = influence.centre
	_influence_ring.global_position = Vector3(
		centre.x, maxf(island.height_at(centre.x, centre.z), 0.0) + 0.6, centre.z
	)
	_influence_ring.scale = Vector3(influence.radius, 1.0, influence.radius)


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

	var sky := Sky.new()
	sky.sky_material = sky_material

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.6
	environment.fog_enabled = true
	# Enough haze to swallow the water plane's far edge at the horizon.
	environment.fog_density = 0.0035
	environment.fog_light_color = Color(0.72, 0.78, 0.84)

	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-52.0), deg_to_rad(38.0), 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)


func _build_water() -> void:
	var plane := PlaneMesh.new()
	# Wide enough that its edge is never on screen at full zoom-out.
	plane.size = Vector2(island.extent * 10.0, island.extent * 10.0)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.13, 0.32, 0.44, 0.80)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.12
	material.metallic = 0.25

	var water := MeshInstance3D.new()
	water.name = "Water"
	water.mesh = plane
	water.material_override = material
	add_child(water)


## Returns the boot banner as lines. Split out so headless tests can assert on
## it without instancing the scene's UI.
static func boot_report() -> PackedStringArray:
	return PackedStringArray([
		"NUMEN",
		"Godot %s" % Engine.get_version_info().get("string", "unknown"),
		"3D physics: %s" % physics_engine_name(),
		"",
		"Left mouse: grab / throw    Right mouse: orbit    Wheel: zoom    Arrows: pan",
		"Middle mouse drag: draw a miracle gesture",
		"P: pet    L: slap    1-4: leash    F: find creature    V: find village",
		"Tab: mind inspector    F5: save    F9: load",
	])


static func physics_engine_name() -> String:
	return str(ProjectSettings.get_setting("physics/3d/physics_engine", "<unset>"))
