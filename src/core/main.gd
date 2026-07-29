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

var island: Node3D
var scatter: Node3D
var camera_rig: Node3D
var hand: Node3D

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

	_hud_label.text = "\n".join(boot_report())
	print("\n".join(boot_report()))


func _on_grabbed(object: WorldObject) -> void:
	_hud_label.text = "holding %s" % object


func _on_released(object: WorldObject, throw_velocity: Vector3) -> void:
	_hud_label.text = "threw %s at %.1f m/s" % [object, throw_velocity.length()]


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
		"Left mouse: grab / throw    Right mouse: orbit",
		"Wheel: zoom    Arrows: pan",
	])


static func physics_engine_name() -> String:
	return str(ProjectSettings.get_setting("physics/3d/physics_engine", "<unset>"))
