extends Node3D
## Procedural island: a noise heightmap turned into a rendered ArrayMesh plus a
## collision shape, with a bilinear ground-height query for placing things on it.
##
## Generated rather than authored, so it costs no assets and no licence surface.
## The shape is deterministic for a given seed — see src/core/rng.gd.

const RNG_STREAM := &"world"

## Surface colours, authored in sRGB and converted on use.
const SAND := Color(0.80, 0.73, 0.52)
const GRASS_LOW := Color(0.26, 0.42, 0.17)
const GRASS_HIGH := Color(0.38, 0.51, 0.23)
const ROCK := Color(0.44, 0.42, 0.40)

## Samples per side. Kept at (2^n)+1 because Jolt's height-field collision wants
## square, power-of-two-plus-one dimensions; a stray value silently degrades to
## a slower fallback shape.
@export var resolution: int = 129
## World size of one side, in metres.
@export var extent: float = 160.0
## Peak land height above water.
@export var height_scale: float = 24.0
## How deep the sea floor sits at the map edge.
@export var sea_floor_depth: float = 10.0
## Fraction of the radius that stays full-height land before the shore falls away.
@export var shore_start: float = 0.45
## Where the surface materials sit. Sand fades out over this height; rock takes
## over between these two steepness values regardless of height.
@export var sand_band: float = 2.2
@export_range(0.0, 1.0) var rock_slope_start: float = 0.34
@export_range(0.0, 1.0) var rock_slope_full: float = 0.62

@export var noise_frequency: float = 0.012
@export var noise_octaves: int = 5

var _heights: PackedFloat32Array = PackedFloat32Array()
var _mesh_instance: MeshInstance3D
var _body: StaticBody3D
var _collision: CollisionShape3D


func _ready() -> void:
	if _heights.is_empty():
		generate()


## Builds the heightmap, mesh and collision. Safe to call again to regenerate.
func generate(world_seed: int = 0) -> void:
	if world_seed == 0:
		world_seed = _default_seed()
	_build_heights(world_seed)
	_build_mesh()
	_build_collision()


func _default_seed() -> int:
	var rng_service: Node = get_node_or_null(^"/root/Rng")
	if rng_service != null:
		return rng_service.derive_seed(RNG_STREAM)
	# Tests may exercise the island without the autoload present.
	return hash("numen:island")


## Distance in metres between adjacent heightmap samples.
func cell_size() -> float:
	return extent / float(resolution - 1)


## Ground height at a world-space XZ position, bilinearly interpolated.
## Returns the sea-floor depth outside the island bounds.
func height_at(world_x: float, world_z: float) -> float:
	var half: float = extent * 0.5
	var fx: float = (world_x + half) / cell_size()
	var fz: float = (world_z + half) / cell_size()
	if fx < 0.0 or fz < 0.0 or fx > float(resolution - 1) or fz > float(resolution - 1):
		return -sea_floor_depth

	var ix: int = clampi(int(fx), 0, resolution - 2)
	var iz: int = clampi(int(fz), 0, resolution - 2)
	var tx: float = fx - float(ix)
	var tz: float = fz - float(iz)

	var h00: float = _sample(ix, iz)
	var h10: float = _sample(ix + 1, iz)
	var h01: float = _sample(ix, iz + 1)
	var h11: float = _sample(ix + 1, iz + 1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## True when the given world position is above the waterline.
func is_land(world_x: float, world_z: float) -> bool:
	return height_at(world_x, world_z) > 0.0


func get_heights() -> PackedFloat32Array:
	return _heights


func _sample(ix: int, iz: int) -> float:
	return _heights[iz * resolution + ix]


func _build_heights(world_seed: int) -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = world_seed
	noise.frequency = noise_frequency
	noise.fractal_octaves = noise_octaves

	_heights = PackedFloat32Array()
	_heights.resize(resolution * resolution)

	var half: float = float(resolution - 1) * 0.5
	for iz in resolution:
		for ix in resolution:
			# Radial falloff turns an open noise field into an island: full
			# height in the middle, sea floor past the shore.
			var nx: float = (float(ix) - half) / half
			var nz: float = (float(iz) - half) / half
			var radial: float = sqrt(nx * nx + nz * nz)
			var falloff: float = clampf(inverse_lerp(1.0, shore_start, radial), 0.0, 1.0)
			falloff = smoothstep(0.0, 1.0, falloff)

			var n: float = noise.get_noise_2d(float(ix), float(iz)) * 0.5 + 0.5
			_heights[iz * resolution + ix] = lerpf(-sea_floor_depth, n * height_scale, falloff)


func _build_mesh() -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half: float = extent * 0.5
	var step: float = cell_size()
	for iz in resolution:
		for ix in resolution:
			var h: float = _sample(ix, iz)
			surface.set_color(_colour_for_surface(h, _steepness_at(ix, iz)))
			surface.set_uv(Vector2(float(ix) / float(resolution - 1), float(iz) / float(resolution - 1)))
			surface.add_vertex(Vector3(float(ix) * step - half, h, float(iz) * step - half))

	for iz in resolution - 1:
		for ix in resolution - 1:
			var top_left: int = iz * resolution + ix
			var top_right: int = top_left + 1
			var bottom_left: int = top_left + resolution
			var bottom_right: int = bottom_left + 1
			# Winding matters twice over: the wrong order culls the whole island
			# as backfaces, and generate_normals() then points every normal at
			# the sea floor so what does show is lit only by ambient.
			surface.add_index(top_left)
			surface.add_index(top_right)
			surface.add_index(bottom_left)
			surface.add_index(top_right)
			surface.add_index(bottom_right)
			surface.add_index(bottom_left)

	surface.generate_normals()

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "IslandMesh"
		add_child(_mesh_instance)
	_mesh_instance.mesh = surface.commit()
	_mesh_instance.material_override = _ground_material()


func _build_collision() -> void:
	if _body == null:
		_body = StaticBody3D.new()
		_body.name = "IslandBody"
		add_child(_body)
		_collision = CollisionShape3D.new()
		_collision.name = "IslandCollision"
		_body.add_child(_collision)

	var shape := HeightMapShape3D.new()
	shape.map_width = resolution
	shape.map_depth = resolution
	shape.map_data = _heights
	_collision.shape = shape
	# HeightMapShape3D samples one unit apart and centres on the origin, so the
	# node is scaled to stretch those samples across `extent` metres.
	_collision.scale = Vector3(cell_size(), 1.0, cell_size())


## Ground tint by altitude AND steepness.
##
## Altitude alone was not enough: a cliff face and a flat meadow at the same height
## came out the same green, which is why the island read as one smooth painted lump
## whatever its shape. Slope is what separates them, and it costs nothing — the
## heightmap already has the neighbours needed to measure it.
##
## Blended rather than stepped at every boundary. Hard thresholds produce contour
## bands, which look like a topographic map rather than ground.
##
## Converted to linear because the renderer consumes vertex colours as linear
## values: handed sRGB numbers directly, a 0.35 green displays as a washed-out mint
## and the rock band reads as snow.
func _colour_for_surface(h: float, steepness: float) -> Color:
	# Grass first, varying slightly with height so a hillside is not one flat wash.
	var grass: Color = GRASS_LOW.lerp(GRASS_HIGH, clampf(h / height_scale, 0.0, 1.0))

	# Sand along the tideline, fading out rather than stopping at a line.
	var colour: Color = grass.lerp(SAND, 1.0 - smoothstep(0.0, sand_band, h))

	# Rock wherever the ground is steep, at any height, and on the bare peaks. This
	# is the term that was missing: cliffs are rock because they are cliffs, not
	# because of how high they happen to be.
	var rock_from_slope: float = smoothstep(rock_slope_start, rock_slope_full, steepness)
	var rock_from_height: float = smoothstep(
		height_scale * 0.60, height_scale * 0.78, h
	)
	colour = colour.lerp(ROCK, clampf(maxf(rock_from_slope, rock_from_height), 0.0, 1.0))
	return colour.srgb_to_linear()


## How steep the ground is at a sample, as 0 flat to 1 vertical.
##
## Measured by central difference across the heightmap rather than from the mesh
## normals, because the colour is needed while the vertices are being written and
## generate_normals() has not run yet.
func _steepness_at(ix: int, iz: int) -> float:
	var step: float = cell_size()
	var left: float = _sample(maxi(ix - 1, 0), iz)
	var right: float = _sample(mini(ix + 1, resolution - 1), iz)
	var back: float = _sample(ix, maxi(iz - 1, 0))
	var front: float = _sample(ix, mini(iz + 1, resolution - 1))
	var slope_x: float = (right - left) / (step * 2.0)
	var slope_z: float = (front - back) / (step * 2.0)
	var gradient: float = sqrt(slope_x * slope_x + slope_z * slope_z)
	# atan turns a gradient into an angle, so the value saturates sensibly instead
	# of running away on a cliff.
	return clampf(atan(gradient) / (PI * 0.5), 0.0, 1.0)


func _ground_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material
