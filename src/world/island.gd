extends Node3D
## Procedural island: a noise heightmap turned into a rendered ArrayMesh plus a
## collision shape, with a bilinear ground-height query for placing things on it.
##
## Generated rather than authored, so it costs no assets and no licence surface.
## The shape is deterministic for a given seed — see src/core/rng.gd.

const RNG_STREAM := &"world"

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
			surface.set_color(_colour_for_height(h))
			surface.set_uv(Vector2(float(ix) / float(resolution - 1), float(iz) / float(resolution - 1)))
			surface.add_vertex(Vector3(float(ix) * step - half, h, float(iz) * step - half))

	for iz in resolution - 1:
		for ix in resolution - 1:
			var top_left: int = iz * resolution + ix
			var top_right: int = top_left + 1
			var bottom_left: int = top_left + resolution
			var bottom_right: int = bottom_left + 1
			surface.add_index(top_left)
			surface.add_index(bottom_left)
			surface.add_index(top_right)
			surface.add_index(top_right)
			surface.add_index(bottom_left)
			surface.add_index(bottom_right)

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


func _colour_for_height(h: float) -> Color:
	if h < 0.4:
		return Color(0.76, 0.70, 0.50)  # sand
	if h > height_scale * 0.62:
		return Color(0.55, 0.54, 0.52)  # exposed rock
	return Color(0.35, 0.49, 0.24).lerp(Color(0.42, 0.55, 0.28), fmod(h, 1.0))


func _ground_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.95
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material
