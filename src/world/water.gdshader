shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

// The sea around the island. This is the project's first shader; everything until
// now was a flat StandardMaterial3D, which read as a sheet of blue plastic and
// frames every screenshot the game produces.
//
// Waves are faked in the NORMAL rather than displacing vertices. The water plane
// spans ten island widths — 1600 units — so real vertex waves would need a
// subdivision fine enough to be absurd at that size (even 200 subdivisions leaves
// vertices 8 units apart, far coarser than a wave). Perturbing the normal costs
// nothing, needs no geometry, and at the game's camera distance is
// indistinguishable from the real thing. If the camera ever drops to the surface,
// that is the moment to revisit it.

uniform vec3 shallow_colour : source_color = vec3(0.29, 0.61, 0.66);
uniform vec3 deep_colour : source_color = vec3(0.04, 0.15, 0.29);
uniform vec3 foam_colour : source_color = vec3(0.80, 0.87, 0.90);

// How far down the sea has to go before it reads as fully deep.
uniform float depth_fade : hint_range(0.5, 40.0) = 6.0;
// Width of the surf band at the shoreline, in metres of water depth.
uniform float foam_width : hint_range(0.05, 6.0) = 0.95;
// Foam gets a second, tighter band right at the waterline so the edge reads as
// breaking surf rather than a soft gradient.
uniform float foam_edge : hint_range(0.01, 2.0) = 0.35;

uniform float wave_scale : hint_range(0.005, 0.5) = 0.055;
uniform float wave_strength : hint_range(0.0, 1.0) = 0.22;
uniform float wave_speed : hint_range(0.0, 3.0) = 0.55;

uniform float shallow_alpha : hint_range(0.0, 1.0) = 0.30;
// Fully opaque, not 0.94. The island mesh carries its own sea floor as a flat
// square 160 units across, and at 94% opacity the remaining 6% was enough to show
// that square's straight edge through the deep water as a pale trapezoid across
// the open sea. Shallow water stays translucent, which is where seeing the bottom
// actually reads as water.
uniform float deep_alpha : hint_range(0.0, 1.0) = 1.0;
uniform float water_roughness : hint_range(0.0, 1.0) = 0.06;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Two crossing wave trains at different scales and speeds. Summing two is what
// stops the surface reading as a regular corrugation; a single sine is obviously
// a pattern.
vec2 wave_slope(vec2 p, float t) {
	vec2 a = vec2(0.86, 0.51);
	vec2 b = vec2(-0.42, 0.91);
	float pa = dot(p, a) * wave_scale + t * wave_speed;
	float pb = dot(p, b) * wave_scale * 1.7 - t * wave_speed * 0.78;
	// Derivatives of the two sines, which is the slope the normal needs.
	return a * cos(pa) * wave_strength + b * cos(pb) * wave_strength * 0.55;
}

void fragment() {
	// Reconstruct how much water sits between this fragment and whatever is behind
	// it. That single number drives colour, transparency and the surf line, so the
	// shore reads as shallow without anything having to describe where the shore is.
	float raw = texture(depth_texture, SCREEN_UV).x;
	float surface_distance = -VERTEX.z;
	float water_depth;

	// Nothing behind the water at all. Godot uses reversed-Z, so an untouched depth
	// buffer reads 0 — and the island's mesh is only a 160-unit square, while the sea
	// plane spans 1600, so most of the open sea has no sea floor beneath it and lands
	// here. Reconstructing a position from that value gave a distance NEARER than the
	// surface, max(..., 0.0) turned it into zero depth, zero depth means surf, and the
	// result was a pale wedge of foam across the open ocean with dead straight edges:
	// the island mesh's own square boundary, seen in perspective.
	//
	// Open water with no bottom is not shallow. It is as deep as it gets.
	if (raw <= 0.000001) {
		water_depth = depth_fade * 4.0;
	} else {
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw);
		vec4 behind = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		behind.xyz /= behind.w;
		water_depth = max(-behind.z - surface_distance, 0.0);
	}

	float depth_mix = clamp(water_depth / depth_fade, 0.0, 1.0);
	vec3 body = mix(shallow_colour, deep_colour, depth_mix);

	// Surf: a broad band where the water is shallow, plus a tight bright line right
	// at the edge.
	float surf = 1.0 - smoothstep(0.0, foam_width, water_depth);
	float edge = 1.0 - smoothstep(0.0, foam_edge, water_depth);
	// Modulated by the wave so the foam moves with the swell instead of sitting as
	// a static outline round the island.
	float swell = sin(dot(world_position.xz, vec2(0.71, 0.71)) * wave_scale * 3.0
		+ TIME * wave_speed * 1.6) * 0.5 + 0.5;
	float foam = clamp(surf * (0.45 + 0.55 * swell) + edge, 0.0, 1.0);

	ALBEDO = mix(body, foam_colour, foam);
	ALPHA = mix(shallow_alpha, deep_alpha, depth_mix);
	// Foam is opaque: surf is not something you see through.
	ALPHA = mix(ALPHA, 1.0, foam);

	vec2 slope = wave_slope(world_position.xz, TIME);
	NORMAL = normalize(NORMAL + vec3(slope.x, 0.0, slope.y));

	ROUGHNESS = mix(water_roughness, 0.55, foam);
	METALLIC = mix(0.22, 0.0, foam);
	SPECULAR = 0.65;
}
