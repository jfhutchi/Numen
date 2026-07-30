shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

// The ring of divine influence, drawn on a terrain-conforming ribbon.
//
// The boundary is computed from world-space XZ distance against a radius uniform,
// never from UV, so the mesh can be any size and the drawn edge sits exactly where
// Influence.contains() flips — one radius number, two consumers.
//
// Depth testing stays ON deliberately, and the mesh drapes over the terrain
// (see influence_ring.gd). A flat disc at water level was occluded by the very
// hills the player acts on; the ribbon lies on the ground, and hills in front of
// it still occlude it, which is what a circle painted on the world should do.
//
// Compatibility-safe by construction: no screen texture, no depth texture, no
// derivatives — this must run under WebGL 2.0.

// The influence radius in metres. Set by InfluenceRing.set_radius with the very
// number Influence.radius holds.
uniform float radius = 10.0;
// How decisively the player may act, 0..1; drives overall brightness.
uniform float strength : hint_range(0.0, 1.0) = 1.0;
// Width of the bright boundary band, in metres.
uniform float edge_width : hint_range(0.5, 12.0) = 2.5;
uniform vec3 ring_colour : source_color = vec3(0.55, 0.75, 1.0);
uniform float edge_alpha : hint_range(0.0, 1.0) = 0.85;
// The faint tint filling the inside of the ring.
uniform float fill_alpha : hint_range(0.0, 0.3) = 0.05;
uniform float pulse_alpha : hint_range(0.0, 1.0) = 0.16;
// Outward speed of the travelling pulse, metres per second, and the distance
// between successive crests. World units, so the breathing reads the same at
// every ring size.
uniform float pulse_speed : hint_range(0.0, 30.0) = 5.0;
uniform float pulse_spacing : hint_range(1.0, 60.0) = 13.0;
// HDR multiplier on the boundary band. Above the environment's glow threshold
// (1.05) at full strength, so the edge blooms gently.
uniform float edge_energy : hint_range(1.0, 4.0) = 1.8;
// Brightness floor at strength 0, so a powerless god still sees a ring.
uniform float dim_floor : hint_range(0.0, 1.0) = 0.35;

varying vec3 world_position;
varying vec2 centre_xz;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// The node's own origin is the ring centre — no separate centre uniform to
	// forget to update when the ring moves.
	centre_xz = MODEL_MATRIX[3].xz;
}

void fragment() {
	float d = distance(world_position.xz, centre_xz);
	float half_edge = edge_width * 0.5;

	// The boundary: a soft band centred exactly on the radius.
	float band = 1.0 - smoothstep(0.0, half_edge, abs(d - radius));
	// Inside the ring only; past the band's outer half there is nothing at all.
	float inside = 1.0 - smoothstep(radius - half_edge, radius, d);
	// Crests travel outward as TIME grows: for a fixed phase, d must increase to
	// keep up. Confined to the inside so the breathing dies at the boundary.
	float crest = fract((d - TIME * pulse_speed) / pulse_spacing);
	float pulse = smoothstep(0.75, 1.0, crest) * inside;

	float bright = mix(dim_floor, 1.0, clamp(strength, 0.0, 1.0));
	ALBEDO = ring_colour * mix(1.0, edge_energy, band) * bright;
	ALPHA = clamp(band * edge_alpha + pulse * pulse_alpha + inside * fill_alpha, 0.0, 1.0) * bright;
}
