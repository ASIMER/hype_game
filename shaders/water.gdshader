shader_type spatial;
// Render-only river water for ProceduralTerrain. VISIBLE flowing water: the vertex stage
// bobs the surface, the fragment stage scrolls two ripple-noise layers DOWNSTREAM (along
// the ribbon's V = arclength flow coordinate), perturbs the normal for moving glints,
// shades deep→shallow, and paints animated bank foam + crest foam + sun sparkle. The mesh
// carries real UVs (U across [0..1], V = arclength/3) so flow follows the river, not world
// XZ. TIME is fine here (render-only — gameplay determinism doesn't touch the shader).
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// --- legacy uniforms (kept so any default_env-style caller that sets them still works) ---
uniform vec3 shallow_color : source_color = vec3(0.20, 0.52, 0.55);
uniform vec3 deep_color : source_color = vec3(0.04, 0.16, 0.26);
uniform vec3 foam_color : source_color = vec3(0.85, 0.92, 0.94);
uniform float wave_speed = 0.35;     // legacy; flow speeds below are the live knobs
uniform float wave_scale = 0.30;     // legacy
uniform float water_alpha = 0.78;    // base transparency

// --- new tuning (sane defaults; flow clearly readable from 5 m) ---
uniform float flow_speed_a = 0.80;   // downstream scroll of ripple layer A
uniform float flow_speed_b = 1.35;   // downstream scroll of ripple layer B
uniform float bob_amp = 0.045;       // primary vertex bob amplitude
uniform float ripple_strength = 0.85;// how hard ripple noise perturbs the normal
uniform float foam_amount = 1.15;    // bank/crest foam intensity
uniform float sparkle = 1.2;         // sun-glint intensity

// --- cheap value noise ------------------------------------------------------
float hash2(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash2(i);
	float b = hash2(i + vec2(1.0, 0.0));
	float c = hash2(i + vec2(0.0, 1.0));
	float d = hash2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * vnoise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return v;
}

varying vec2 v_uv;

void vertex() {
	v_uv = UV;
	// Visible bobbing — two travelling sine waves along the flow coordinate (UV.y) with a
	// cross-river (UV.x) phase so the surface isn't a flat sheet. Displaces VERTEX.y.
	float w = bob_amp * sin(UV.y * 4.2 - TIME * 1.7)
		+ 0.025 * sin(UV.y * 9.0 - TIME * 2.9 + UV.x * 3.0);
	VERTEX.y += w;
}

void fragment() {
	vec2 uv = v_uv;
	// Two ripple layers scrolling DOWNSTREAM (subtract TIME from the V/flow axis). 0.4–1 m
	// features: UV.x*2 packs ripples across the ~5 m channel; the V scale gives metre-scale
	// streaks travelling with the current.
	vec2 ra = vec2(uv.x * 2.0, uv.y - TIME * flow_speed_a);
	vec2 rb = vec2(uv.x * 2.3, uv.y * 1.0 - TIME * flow_speed_b);
	float n1 = fbm(ra * 3.0);
	float n2 = fbm(rb * 3.7);
	float ripple = (n1 + n2) * 0.5;

	// Perturb NORMAL from the ripple gradient → moving specular highlights/glints.
	float e = 0.04;
	float gx = (fbm((ra + vec2(e, 0.0)) * 3.0) - n1) + (fbm((rb + vec2(e, 0.0)) * 3.7) - n2);
	float gy = (fbm((ra + vec2(0.0, e)) * 3.0) - n1) + (fbm((rb + vec2(0.0, e)) * 3.7) - n2);
	vec3 nrm = normalize(vec3(-gx * ripple_strength, 1.0, -gy * ripple_strength));
	NORMAL = normalize(mix(NORMAL, nrm, 0.7));

	// Deep→shallow albedo driven by ripple (troughs read deeper, crests catch light).
	vec3 base = mix(deep_color, shallow_color, ripple);

	// Bank foam: white streaks hugging BOTH banks (UV.x near 0 and 1), animated by ripple
	// so they shimmer and crawl rather than sit static.
	float edge = abs(uv.x * 2.0 - 1.0);                 // 0 at centre, 1 at both banks
	float bank_foam = smoothstep(0.75, 0.95, edge) * (0.6 + 0.4 * ripple);
	// Crest foam where ripple peaks (mid-channel churn) — wider band → more visible churn.
	float crest_foam = smoothstep(0.58, 0.82, ripple);
	float foam = clamp((bank_foam + crest_foam) * foam_amount, 0.0, 1.0);

	// Sparkle: tight specular glint on ripple crests facing the view.
	float ndotv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float glint = pow(1.0 - abs(ripple - 0.62), 6.0) * sparkle;

	// Fresnel rim — stronger at grazing angles for a watery sheen at the far bank.
	float fres = pow(1.0 - ndotv, 4.0);

	ALBEDO = mix(base, foam_color, foam * 0.8);
	ROUGHNESS = mix(0.06, 0.32, ripple) - foam * 0.04;
	METALLIC = 0.0;
	SPECULAR = 0.7;
	ALPHA = clamp(water_alpha + fres * 0.22 + foam * 0.25, 0.0, 0.97);
	EMISSION = foam_color * (foam * 0.10 + glint * 0.18) + shallow_color * fres * 0.12;
}
