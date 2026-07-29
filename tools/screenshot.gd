extends SceneTree
## Boots the game, lets it settle, and writes a PNG of the viewport.
##
## Used for eyeballing the world without a human at the keyboard, and for
## dropping a capture into docs/. Needs a real rendering context, so run it
## WITHOUT --headless:
##
##   godot --path . -s tools/screenshot.gd -- <frames> <output.png>

const DEFAULT_FRAMES := 90
const DEFAULT_OUTPUT := "user://numen_smoke.png"


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var frames: int = DEFAULT_FRAMES
	var output: String = DEFAULT_OUTPUT
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() >= 1 and args[0].is_valid_int():
		frames = int(args[0])
	if args.size() >= 2:
		output = args[1]

	change_scene_to_file("res://src/core/main.tscn")

	for i in frames:
		await process_frame
	await RenderingServer.frame_post_draw

	var image: Image = root.get_texture().get_image()
	if image == null:
		push_error("no viewport image; is this running headless?")
		quit(1)
		return

	var error: int = image.save_png(output)
	if error != OK:
		push_error("failed to write %s (error %d)" % [output, error])
		quit(1)
		return

	print("screenshot: %s (%dx%d)" % [
		ProjectSettings.globalize_path(output), image.get_width(), image.get_height()
	])
	quit()
