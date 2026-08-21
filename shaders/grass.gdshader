shader_type spatial;
// Cinematic grass for Hype Raiders' flora MultiMesh.
//
// Adapted from GodotGrass by 2Retr0 — MIT — https://github.com/2Retr0/GodotGrass
// Techniques borrowed & re-fit to our per-instance MultiMesh blades (each tuft is a
// Transform3D-placed fan of fine blades; UV.y = 0 at the ROOT, 1 at the TIP — NOTE this
// is the INVERSE of GodotGrass's convention, so every UV.y term here is flipped vs theirs):
//   * root->tip colour gradient (darker base, brighter tip)
//   * base ambient occlusion (darken near the root)
//   * subsurface-scattering backlight in light() — blades glow warm when viewed against
//     the sun (the cinematic "lit-from-behind" look)
//   * multi-frequency procedural wind with turbulence (tips sway most, roots pinned)
//   * view-space blade widening (fatten blades that face edge-on to the camera, killing
//     the thin-blade shimmer/aliasing at distance)
//
// PERF: render_mode cull_back — back-face culling halves overdraw. Each tuft fans 6
// blades around 360deg, so from any view some blades face the camera and the dense
// overlap hides the culled back-faces; this is part of the spatial-tiling perf fix
// (see procedural_flora.gd _build_grass) that keeps >=200 fps with grass on-screen.
render_mode cull_back;

group_uniforms GrassColor;
uniform vec3 base_color : source_color = vec3(0.12, 0.26, 0.07);   // dark root green
uniform vec3 tip_color : source_color = vec3(0.46, 0.64, 0.26);    // bright tip
uniform vec3 sss_color : source_color = vec3(1.0, 0.78, 0.28);     // warm backlight tint
uniform float sss_strength : hint_range(0.0, 2.0) = 0.7;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.85;           // root darkening amount
// Dry-patch tint: ~45 m world-noise patches pull the palette toward sun-dried straw
// (frequency 0.022 matches the terrain macro tint so dry grass sits on dry ground).
uniform vec3 dry_base_color : source_color = vec3(0.30, 0.26, 0.10);
uniform vec3 dry_tip_color : source_color = vec3(0.62, 0.55, 0.25);
uniform float dry_strength : hint_range(0.0, 1.0) = 0.7;

group_uniforms Wind;
uniform float sway_strength : hint_range(0.0, 1.0) = 0.18;
uniform float sway_speed : hint_range(0.0, 5.0) = 1.6;
uniform float widen_strength : hint_range(0.0, 4.0) = 1.6;         // view-space thickening

group_uniforms NearFade;
// Blades this close to the camera shrink to nothing, so the third-person camera never
// pushes THROUGH an opaque blade in a close-up (crouch/slide/wall-hugging). Done by
// scaling the blade in vertex() rather than fading ALPHA: the grass pass stays fully
// opaque, so no alpha sorting/depth-prepass cost and no shimmer against the ground.
uniform float near_fade_start : hint_range(0.0, 4.0) = 0.6;        // fully collapsed below
uniform float near_fade_end : hint_range(0.0, 6.0) = 1.4;          // full size above

// Cheap 2D value hash for the per-tuft tint variation.
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float ease_in_quad(float x) { return x * x; }
float ease_in_quartic(float x) { float a = x * x; return a * a; }

// Smooth 2-octave value noise (bilinear-lerped hash lattice) for the dry patches.
float vnoise01(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 s = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

// World position of this tuft's root, stashed for the fragment tint.
varying vec3 v_wpos;
// Height fraction (0 root -> 1 tip) forwarded to fragment/light.
varying float v_hf;

void vertex() {
	v_hf = UV.y;

	// World-space position of this vertex (MODEL_MATRIX places each MultiMesh instance).
	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wpos = wpos;
	// Per-tuft phase so neighbouring clumps don't sway in lock-step.
	float phase = hash21(floor(wpos.xz * 0.35)) * 6.2831853;

	// --- MULTI-FREQUENCY WIND (Perlin-ish via summed sines over world pos + time) ---
	// Two big low-frequency gusts roll across the field; a faster term adds turbulence.
	float t = TIME * sway_speed;
	float gust = sin(t + wpos.x * 0.18 + wpos.z * 0.22 + phase)
		+ 0.6 * sin(t * 0.57 - wpos.x * 0.07 + wpos.z * 0.11)
		+ 0.35 * sin(t * 1.9 + wpos.x * 0.9 + wpos.z * 1.3 + phase);
	// Per-blade turbulence: a higher-frequency jitter that lags up the blade (tips shimmer).
	float turb = sin(t * 3.1 + wpos.z * 2.1 + UV.y * 5.0 + phase) * 0.25;

	// Roots pinned (UV.y=0), tips swing most (UV.y=1) — quadratic weight.
	float w = ease_in_quad(UV.y) * sway_strength;
	VERTEX.x += (gust + turb) * w;
	VERTEX.z += (gust * 0.6 - turb * 0.4) * w;

	// --- VIEW-SPACE BLADE WIDENING ---
	// Blades whose face is edge-on to the camera read as a single shimmering pixel.
	// Widen them perpendicular to view, weighted by how edge-on they are, so they stay
	// readable (kills thin-blade aliasing/pop at distance). Tips widen less than mid.
	vec3 nrm_world = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 view_dir = normalize(CAMERA_POSITION_WORLD - wpos);
	float edge_on = 1.0 - abs(dot(nrm_world, view_dir));  // 1 = edge-on, 0 = facing
	// Widen along the blade's local x (the across-blade axis). sign() keeps both edges.
	float wdir = sign(VERTEX.x + 1e-6);
	float widen = ease_in_quartic(edge_on) * (1.0 - UV.y * 0.5) * widen_strength * 0.02;
	VERTEX.x += wdir * widen;

	// --- NEAR-CAMERA COLLAPSE ---
	// The tuft mesh has its root at model y=0 (procedural_flora._grass_card_mesh), so a
	// UNIFORM scale shrinks each blade toward its own root — the tuft sinks into the ground
	// instead of flattening into a fan. Applied last so the wind sway and the widening scale
	// with it. At near_k = 0 every vertex collapses onto the root and the triangles degenerate
	// away, which costs nothing to rasterize.
	float near_k = smoothstep(near_fade_start, near_fade_end,
		distance(CAMERA_POSITION_WORLD, wpos));
	VERTEX *= near_k;
}

void fragment() {
	// Root->tip vertical gradient (quartic so the bright tip is concentrated up top).
	float g = ease_in_quartic(v_hf);
	// Dry patches: blend BOTH gradient ends toward straw inside ~45 m noise blobs.
	float dryness = smoothstep(0.55, 0.80,
		vnoise01(v_wpos.xz * 0.022) * 0.65 + vnoise01(v_wpos.xz * 0.044) * 0.35);
	float dry = dryness * dry_strength;
	vec3 root_c = mix(base_color, dry_base_color, dry);
	vec3 tip_c = mix(tip_color, dry_tip_color, dry);
	vec3 col = mix(root_c, tip_c, g);

	// Per-tuft tint so neighbouring clumps differ (hash a coarse world grid).
	float tint = hash21(floor(v_wpos.xz * 0.5));
	col *= 0.86 + 0.28 * tint;

	// Base ambient occlusion: darken near the root (UV.y low), brighten toward the tip.
	float ao = mix(1.0 - ao_strength, 1.0, ease_in_quad(v_hf));
	col *= ao;

	ALBEDO = col;
	ROUGHNESS = mix(0.96, 0.55, g);   // tips a touch glossier for a sheen
	SPECULAR = 0.12;
}

void light() {
	// Standard wrapped diffuse — never fully zero, to fake ambient bounce between blades.
	float ndl = dot(NORMAL, LIGHT);
	float diffuse = pow(2.0, ndl) / 2.0;

	// Subsurface-scattering backlight: when the camera looks toward the light THROUGH the
	// blade (VIEW and LIGHT roughly opposed) the thin blade glows. Stronger near the tip.
	float back = max(-dot(VIEW, LIGHT), 0.0);
	float sss = back * sss_strength * mix(0.3, 1.0, v_hf);

	DIFFUSE_LIGHT += (diffuse + sss * sss_color) * ATTENUATION * LIGHT_COLOR;
	SPECULAR_LIGHT *= diffuse;
}
