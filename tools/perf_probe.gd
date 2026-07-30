extends SceneTree
## Measures frame rate with a large village, against the Definition-of-Done line
## of >= 60 fps with 200 villagers.
##
## Run WITHOUT --headless: a headless run uses the dummy renderer and would report
## a meaningless frame rate.
##
##   godot --path . -s tools/perf_probe.gd -- <villagers> <measure_frames>
##
## Population growth is housing-gated and takes sim-hours to reach 200 honestly,
## so the village is fast-forwarded first with `simulate()` driven in a tight loop
## and rendering effectively idle. Only once the population is there does the
## probe hand control back to the frame loop and start sampling. That keeps the
## measurement about drawing and physics rather than about village arithmetic.

const DEFAULT_TARGET := 200
const DEFAULT_FRAMES := 240
## Discarded before sampling: the frames after the population jump include shader
## compilation and instance-buffer growth, which are real costs but not steady
## state. 90 was not nearly enough — at 90 the run reported 14.7% of frames below
## 60 and a 3 fps minimum, all of it warm-up residue; at 600 the same build reports
## a flat 144 with nothing under 60. Measure long enough to be measuring the game.
const WARMUP_FRAMES := 600
const FAST_FORWARD_STEP := 0.2
const FAST_FORWARD_CAP := 40000


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var target: int = int(args[0]) if args.size() >= 1 and args[0].is_valid_int() else DEFAULT_TARGET
	var frames: int = int(args[1]) if args.size() >= 2 and args[1].is_valid_int() else DEFAULT_FRAMES
	var warmup: int = int(args[2]) if args.size() >= 3 and args[2].is_valid_int() else WARMUP_FRAMES

	change_scene_to_file("res://src/core/main.tscn")
	for i in 30:
		await process_frame

	var main: Node3D = current_scene
	var village: Node3D = main.get_node_or_null(^"HomeVillage")
	if village == null:
		print("PERF_FAIL no HomeVillage")
		quit(1)
		return

	# Let it grow to `target`. The store is topped up so growth is not gated on
	# farming, which is not what is being measured.
	#
	# The ceiling is raised after populate() has already run, which the village has
	# to cope with — its instance buffer grows on demand. An earlier version clamped
	# silently instead, and this probe would have reported 200 villagers while
	# drawing 24 of them, then declared PASS.
	village.tunables.max_population = target
	village.auto_simulate = false
	var steps: int = 0
	while village.population() < target and steps < FAST_FORWARD_CAP:
		village.store.add(&"food", 400.0)
		village.store.add(&"wood", 400.0)
		village.simulate(FAST_FORWARD_STEP)
		steps += 1
		# Yield occasionally so the window keeps pumping and the process is not
		# killed as unresponsive.
		if steps % 400 == 0:
			await process_frame
	village.auto_simulate = true

	print("PERF_POPULATION %d after %d sim steps (%.0f sim-seconds)" % [
		village.population(), steps, float(steps) * FAST_FORWARD_STEP
	])

	for i in warmup:
		await process_frame

	var readings: Array[float] = []
	var draw_calls: float = 0.0
	var objects: float = 0.0
	for i in frames:
		await process_frame
		var fps: float = Engine.get_frames_per_second()
		if fps <= 0.0:
			continue
		readings.append(fps)
		draw_calls = maxf(
			draw_calls, Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		)
		objects = maxf(
			objects, Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		)

	if readings.is_empty():
		print("PERF_FAIL no frame-rate samples")
		quit(1)
		return

	var total: float = 0.0
	for fps: float in readings:
		total += fps
	var average: float = total / float(readings.size())

	# The distribution, not just the extremes. A single 27 fps frame among 240 is a
	# hitch; forty of them is a stutter, and an average alone cannot tell those
	# apart — reporting PASS off the mean while a frame took 37 ms would be sloppy.
	var sorted: Array[float] = readings.duplicate()
	sorted.sort()
	var below_60: int = 0
	for fps: float in sorted:
		if fps < 60.0:
			below_60 += 1

	print("PERF_RESULT villagers=%d avg_fps=%.1f min_fps=%.1f samples=%d" % [
		village.population(), average, sorted[0], readings.size()
	])
	print("PERF_DISTRIBUTION p1=%.1f p50=%.1f p99=%.1f frames_below_60=%d (%.1f%%)" % [
		sorted[maxi(int(sorted.size() * 0.01), 0)],
		sorted[int(sorted.size() * 0.5)],
		sorted[mini(int(sorted.size() * 0.99), sorted.size() - 1)],
		below_60,
		100.0 * float(below_60) / float(readings.size()),
	])
	print("PERF_RENDER draw_calls=%d objects=%d" % [int(draw_calls), int(objects)])
	print("PERF_SCENE nodes=%d multimeshes=%d meshinstances=%d" % [
		_count(main, ""), _count(main, "MultiMeshInstance3D"), _count(main, "MeshInstance3D")
	])
	# Both conditions, because the average alone lied: an early run averaged 118 fps
	# while 15% of frames fell under 60, which a player feels as periodic hitching.
	var smooth: bool = below_60 == 0
	var fast: bool = average >= 60.0
	print("PERF_VERDICT %s" % (
		"PASS" if fast and smooth
		else ("STUTTERS" if fast else "BELOW TARGET")
	))
	quit()


## Counts nodes of a class beneath `node`, or every node when `class_wanted` is
## empty. MeshInstance3D counts exclude MultiMeshInstance3D, which is a different
## class, so the two figures together show what the draw-call budget is spent on.
func _count(node: Node, class_wanted: String) -> int:
	var found: int = 1 if class_wanted.is_empty() or node.is_class(class_wanted) else 0
	for child: Node in node.get_children():
		found += _count(child, class_wanted)
	return found
