shader_type spatial;
// Fine dense grass for Hype Raiders' flora MultiMesh. Opaque. Roots are pinned, tips
// sway in a cheap procedural wind. Colour is a root->tip gradient (UV.y) plus a subtle
// per-tuft tint hashed from world position, so a flat 11k-instance field still reads as
// living, varied grass instead of a uniform carpet.
//
// PERF: render_mode cull_back (NOT cull_disabled) — back-face culling halves the
// fragment/overdraw cost. Each tuft fans 6 blades around 360°, so from any view angle
// some blades face the camera and the dense overlap hides the culled back-faces; this is
// part of the spatial-tiling perf fix (see procedural_flora.gd _build_grass) that restores
// ≥200 fps with grass on-screen.
//
// UV CONVENTION (set by procedural_flora.gd's blade mesh): UV.y = 0 at the blade
// root, 1 at the tip. The sway weight and the colour gradient both key off it.
render_mode cull_back;

uniform vec3 base_color : source_color = vec3(0.20, 0.34, 0.13);
uniform vec3 tip_color : source_color = vec3(0.42, 0.58, 0.24);
uniform float sway_strength = 0.08;
uniform float sway_speed = 1.8;

// Cheap 2D hash for the per-tuft tint.
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

// World position of this tuft's root, stashed in vertex() for the fragment tint.
varying vec3 v_wpos;

void vertex() {
	// World-space position of the vertex (MODEL_MATRIX places each MultiMesh instance).
	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wpos = wpos;

	// Procedural wind: two sines at different frequencies for a non-repeating drift.
	float sway = sin(TIME * sway_speed + wpos.x * 0.9 + wpos.z * 1.3)
		+ 0.4 * sin(TIME * sway_speed * 2.3 + wpos.z);

	// Roots pinned (UV.y=0), tips swing the most (UV.y=1) — quadratic weight.
	float w = pow(UV.y, 2.0) * sway_strength * sway;
	VERTEX.x += w;
	VERTEX.z += w * 0.6;
}

void fragment() {
	// Root->tip vertical gradient.
	vec3 col = mix(base_color, tip_color, UV.y * UV.y);

	// Subtle per-tuft tint so neighbouring clumps differ (hash a coarse world grid).
	float t = hash21(floor(v_wpos.xz * 0.5));
	col *= 0.85 + 0.30 * t;

	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.1;
}
