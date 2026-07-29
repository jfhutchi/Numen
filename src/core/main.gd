extends Node3D
## Boot scene.
##
## Phase 1 replaces the contents of this scene with the island, orbit camera and
## divine hand. For now it reports the running engine configuration, which is
## also how we verify the 3D physics backend without opening the editor.

@onready var _boot_label: Label = $BootLayer/BootLabel


func _ready() -> void:
	var report: String = "\n".join(boot_report())
	_boot_label.text = report
	print(report)


## Returns the boot banner as lines. Split out from _ready so headless tests can
## assert on it without instancing the scene's UI.
static func boot_report() -> PackedStringArray:
	return PackedStringArray([
		"NUMEN",
		"Godot %s" % Engine.get_version_info().get("string", "unknown"),
		"3D physics: %s" % physics_engine_name(),
		"",
		"Phase 0 - scaffold. See PROGRESS.md for the next action.",
	])


static func physics_engine_name() -> String:
	return str(ProjectSettings.get_setting("physics/3d/physics_engine", "<unset>"))
