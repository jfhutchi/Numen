extends GutTest
## Guards the project configuration the rest of the build assumes.
##
## These are cheap, but they are not tautologies: each one has a failure mode
## that would otherwise surface much later as confusing gameplay behaviour.

const MAIN_SCENE_PATH := "res://src/core/main.tscn"
const MAIN_SCRIPT_PATH := "res://src/core/main.gd"


func test_main_scene_is_the_configured_entry_point() -> void:
	assert_eq(
		str(ProjectSettings.get_setting("application/run/main_scene", "")),
		MAIN_SCENE_PATH,
		"project.godot must boot the main scene"
	)


func test_main_scene_loads_and_instantiates() -> void:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	assert_not_null(packed, "main scene failed to load")
	if packed == null:
		return
	var instance: Node = packed.instantiate()
	assert_not_null(instance, "main scene failed to instantiate")
	if instance != null:
		instance.free()


func test_physics_backend_is_pinned_explicitly() -> void:
	# Godot 4.6 exposes no runtime identifier for the active 3D backend, and it
	# accepts an unknown engine name without so much as a warning (verified by
	# feeding it a bogus value). This pin is therefore the only source of truth.
	# If it silently drifts to DEFAULT, physics behaviour changes underneath the
	# creature and the Phase 1 ballistic test with nothing else going red.
	assert_eq(
		str(ProjectSettings.get_setting("physics/3d/physics_engine", "")),
		"Jolt Physics",
		"3D physics backend must stay pinned, not left on DEFAULT"
	)


func test_boot_report_is_populated() -> void:
	var main_script: GDScript = load(MAIN_SCRIPT_PATH)
	assert_not_null(main_script, "main.gd failed to load")
	if main_script == null:
		return
	var report: PackedStringArray = main_script.boot_report()
	assert_gt(report.size(), 0, "boot report should not be empty")
	assert_eq(report[0], "NUMEN", "boot report should lead with the project name")
