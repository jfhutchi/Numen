extends Node3D
## Game root. Builds the island, its scenery, the camera and the divine hand.
##
## The world is assembled in code rather than authored as a .tscn because it is
## procedural anyway — there is nothing a designer would hand-place, and a scene
## file would just be a second place for the same numbers to drift.

const ISLAND := preload("res://src/world/island.gd")
const SCATTER := preload("res://src/world/scatter.gd")
const CAMERA_RIG := preload("res://src/hand/camera_rig.gd")
const HAND := preload("res://src/hand/hand.gd")
const CREATURE := preload("res://src/creature/body/creature.gd")
const MIND_INSPECTOR := preload("res://src/ui/mind_inspector.gd")

var island: Node3D
var scatter: Node3D
var camera_rig: Node3D
var hand: Node3D
var creature: CharacterBody3D
var inspector: PanelContainer

@onready var _hud_label: Label = $BootLayer/BootLabel


func _ready() -> void:
	# Fetched by path rather than by the `World` autoload identifier: naming the
	# singleton directly makes this script fail to compile anywhere the autoload
	# is not registered, which includes test runs that merely load the scene.
	var registry: Node = get_node(^"/root/World")

	_build_environment()

	island = ISLAND.new()
	island.name = "Island"
	add_child(island)
	island.generate()

	_build_water()

	scatter = SCATTER.new()
	scatter.name = "Scatter"
	add_child(scatter)
	scatter.populate(island, registry)

	camera_rig = CAMERA_RIG.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.set_island(island)

	hand = HAND.new()
	hand.name = "Hand"
	add_child(hand)
	hand.configure(camera_rig.camera, island, scatter, registry)
	hand.grabbed.connect(_on_grabbed)
	hand.released.connect(_on_released)

	_scatter_food(registry)
	_spawn_creature(registry)
	_build_inspector()

	_hud_label.text = "\n".join(boot_report())
	print("\n".join(boot_report()))


func _on_grabbed(object: WorldObject) -> void:
	_hud_label.text = "holding %s" % object


func _on_released(object: WorldObject, throw_velocity: Vector3) -> void:
	_hud_label.text = "threw %s at %.1f m/s" % [object, throw_velocity.length()]


## Villagers arrive in Phase 2; for now the island gets food piles and a few
## stand-in people, so the creature has both a good and a bad thing to eat and
## the player has something to teach it about.
func _scatter_food(registry: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = Rng_seed()
	for entry: Array in [[&"food_pile", 14, Color(0.85, 0.72, 0.30)], [&"villager", 8, Color(0.85, 0.78, 0.70)]]:
		var type: StringName = entry[0]
		for i in int(entry[1]):
			var spot: Vector3 = _random_land_point(rng)
			var object: WorldObject = registry.add(type, spot)
			var marker := MeshInstance3D.new()
			marker.name = "%s_%d" % [type, object.id]
			var mesh := SphereMesh.new()
			mesh.radius = 0.45 if type == &"food_pile" else 0.4
			mesh.height = 0.9 if type == &"food_pile" else 1.6
			marker.mesh = mesh
			var material := StandardMaterial3D.new()
			material.albedo_color = (entry[2] as Color).srgb_to_linear()
			material.roughness = 0.9
			marker.material_override = material
			marker.position = spot + Vector3.UP * mesh.height * 0.5
			add_child(marker)
			object.node = marker


func _spawn_creature(registry: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = Rng_seed() + 7
	creature = CREATURE.new()
	creature.name = "Creature"
	add_child(creature)
	creature.global_position = _random_land_point(rng) + Vector3.UP * 1.0
	creature.configure(registry, island, null, Rng_seed())
	creature.chose.connect(_on_creature_chose)
	var self_entry: WorldObject = registry.add(&"creature", creature.global_position, creature)
	creature.mind.self_object_id = self_entry.id


func _build_inspector() -> void:
	inspector = MIND_INSPECTOR.new()
	inspector.name = "MindInspector"
	inspector.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	inspector.position = Vector2(-386.0, 12.0)
	inspector.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	$BootLayer.add_child(inspector)
	inspector.bind(creature.mind)


func _random_land_point(rng: RandomNumberGenerator) -> Vector3:
	var half: float = island.extent * 0.35
	for attempt in 64:
		var x: float = rng.randf_range(-half, half)
		var z: float = rng.randf_range(-half, half)
		var h: float = island.height_at(x, z)
		if h > 1.0 and h < 16.0:
			return Vector3(x, h, z)
	return Vector3(0.0, maxf(island.height_at(0.0, 0.0), 1.0), 0.0)


func Rng_seed() -> int:
	var service: Node = get_node_or_null(^"/root/Rng")
	return service.get_master_seed() if service != null else 20260729


func _on_creature_chose(option: CreatureMind.Option) -> void:
	_hud_label.text = "creature: %s  (p=%.0f%%)" % [option.describe(), option.probability * 100.0]


func _unhandled_input(event: InputEvent) -> void:
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
		KEY_TAB:
			inspector.visible = not inspector.visible


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
		"P: pet    L: slap    1-4: leash (none/learning/compassion/aggression)    Tab: inspector",
	])


static func physics_engine_name() -> String:
	return str(ProjectSettings.get_setting("physics/3d/physics_engine", "<unset>"))
