shader_type spatial;
// DEEP river water for ProceduralTerrain (Lane A overhaul). Reads as REAL water filling a
// ~1.5 m carved channel: depth-fade via DEPTH_TEXTURE (shallow edges transparent → riverbed
// shows through; deep centre murkier/opaque), refraction via SCREEN_TEXTURE (the bed wobbles
// under the ripple normal), a natural teal-green→murky-brown river palette (no neon cyan),
// downstream flow scroll along the ribbon's V=arclength axis, bank + crest foam strongest at
// the waterline, fresnel rim, sun sparkle, and a vertex bob. TIME is fine (render-only — the
// shader never touches gameplay determinism). Transparent pass so SCREEN/DEPTH read the scene
// BEHIND the surface; depth_draw_always keeps the depth write without forcing the opaque pass.
render_mode blend_mix, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

// --- natural river palette (sRGB). Deep teal-green → murky brown-green; NO neon cyan. ---
uniform vec3 shallow_tint : source_color = vec3(0.16, 0.40, 0.34);  // shallow teal-green
uniform vec3 deep_tint : source_color = vec3(0.03, 0.11, 0.11);     // murky deep green
uniform vec3 absorb : source_color = vec3(0.46, 0.18, 0.24);        // per-metre absorption (more red/green kill w/ depth)
uniform vec3 foam_color : source_color = vec3(0.82, 0.90, 0.90);

// --- tuning (clearly readable as deep flowing water from 5 m) ---
uniform float depth_scale = 1.6;     // metres of water that fully saturates the deep look (raised for the ~2.7 m channel so the murk grades across the depth instead of slamming opaque at the edge)
uniform float refract_amt = 0.12;    // screen-UV refraction offset (scaled by depth)
uniform float min_tint = 0.30;       // floor on the watercolour body even in shallows (kills the washed-out film)
uniform float flow_speed_a = 0.80;   // downstream scroll of ripple layer A
uniform float flow_speed_b = 1.35;   // downstream scroll of ripple layer B
uniform float bob_amp = 0.040;       // primary vertex bob amplitude
uniform float ripple_strength = 0.85;// how hard ripple noise perturbs the normal
uniform float foam_amount = 0.85;    // bank/crest foam intensity
uniform float sparkle = 1.2;         // sun-glint intensity
uniform float edge_softness = 0.6;   // metres over which the shallow edge fades to clear
uniform float fade_start = 70.0;     // metres — the surface starts thinning with camera distance
uniform float fade_end = 130.0;      // metres — fully faded (kills the dark horizon band)

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;

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
		+ 0.022 * sin(UV.y * 9.0 - TIME * 2.9 + UV.x * 3.0);
	VERTEX.y += w;
}

void fragment() {
	// --- DISTANCE FADE ---------------------------------------------------------------------
	// Seen from far away the ribbon is viewed edge-on, the reconstructed water depth saturates
	// and the whole river renders as a near-opaque dark strip lying across the horizon. Fade
	// the surface out with camera distance instead; once it is invisible DISCARD, so it also
	// stops writing depth under depth_draw_always. VERTEX is view space here, so its length is
	// the distance to the camera.
	float far_fade = 1.0 - smoothstep(fade_start, fade_end, length(VERTEX));
	if (far_fade < 0.004) {
		discard;
	}
	vec2 uv = v_uv;
	// Two ripple layers scrolling DOWNSTREAM (subtract TIME from the V/flow axis). UV.x*2
	// packs ripples across the channel; the V scale gives metre-scale streaks travelling
	// with the current.
	vec2 ra = vec2(uv.x * 2.0, uv.y - TIME * flow_speed_a);
	vec2 rb = vec2(uv.x * 2.3, uv.y * 1.0 - TIME * flow_speed_b);
	float n1 = fbm(ra * 3.0);
	float n2 = fbm(rb * 3.7);
	float ripple = (n1 + n2) * 0.5;

	// Ripple gradient → perturbed normal for moving glints + refraction direction.
	float e = 0.04;
	float gx = (fbm((ra + vec2(e, 0.0)) * 3.0) - n1) + (fbm((rb + vec2(e, 0.0)) * 3.7) - n2);
	float gy = (fbm((ra + vec2(0.0, e)) * 3.0) - n1) + (fbm((rb + vec2(0.0, e)) * 3.7) - n2);
	vec3 nrm = normalize(vec3(-gx * ripple_strength, 1.0, -gy * ripple_strength));
	NORMAL = normalize(mix(NORMAL, nrm, 0.7));

	// --- DEPTH-FADE: reconstruct how much water the view ray passes through ---------------
	// Scene depth behind the water (the riverbed) vs this fragment's own depth → water_depth
	// in view-space metres. Shallow edges = small depth = transparent; deep centre = opaque.
	vec2 screen_uv = SCREEN_UV;
	float scene_d = texture(depth_tex, screen_uv).r;
	vec3 scene_ndc = vec3(screen_uv * 2.0 - 1.0, scene_d);
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(scene_ndc, 1.0);
	scene_view.xyz /= scene_view.w;
	float bed_z = -scene_view.z;            // linear view-space distance to the bed
	float surf_z = -VERTEX.z;               // this fragment (water surface) view distance
	float water_depth = max(bed_z - surf_z, 0.0);
	// Normalised depth factors: edge fade (transparency near the waterline) + saturation.
	float edge_fade = clamp(water_depth / edge_softness, 0.0, 1.0);
	float deep = clamp(water_depth / depth_scale, 0.0, 1.0);

	// --- REFRACTION: sample the screen behind the water, offset by the ripple normal -------
	// Offset grows with depth so deep water wobbles the bed more than the thin edge. Clamp
	// the offset UV so we never sample off-surface garbage at the silhouette.
	vec2 roff = nrm.xz * refract_amt * (0.35 + deep);
	vec2 ref_uv = clamp(screen_uv + roff, vec2(0.001), vec2(0.999));
	vec3 bg = texture(screen_tex, ref_uv).rgb;

	// --- COLOR: tint the refracted bed by depth-based absorption (Beer-Lambert-ish) --------
	vec3 absorption = exp(-absorb * water_depth * 1.9);   // 1 at surface → kills red/warmth with depth
	vec3 watercol = mix(shallow_tint, deep_tint, deep);
	// Blend: shallow → the refracted (absorbed) bed shows through but is ALWAYS tinted by at
	// least min_tint of the watercolour so it never reads as a washed-out glass film; deep →
	// the murky water colour dominates. This is the fix that kills the flat-sticker look.
	vec3 refracted = bg * absorption;
	float body_mix = clamp(min_tint + deep * 0.70, 0.0, 0.95);
	vec3 body = mix(refracted, watercol, body_mix);

	// --- FOAM: a tight band right at the WATERLINE (very shallow edge) + sparse crest churn.
	// Keep it NARROW so foam frames the river edge instead of whitewashing the whole surface.
	float waterline = smoothstep(0.35, 0.0, water_depth); // 1 only within the first ~0.35 m of depth
	float bank_edge = abs(uv.x * 2.0 - 1.0);              // 0 centre, 1 at both ribbon banks
	float bank_foam = max(smoothstep(0.84, 0.98, bank_edge), waterline) * (0.5 + 0.5 * ripple);
	float crest_foam = smoothstep(0.72, 0.90, ripple) * (0.2 + 0.5 * deep);
	float foam = clamp((bank_foam + crest_foam) * foam_amount, 0.0, 1.0);

	// --- sparkle + fresnel -----------------------------------------------------------------
	float ndotv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float glint = pow(1.0 - abs(ripple - 0.62), 6.0) * sparkle;
	float fres = pow(1.0 - ndotv, 4.0);

	vec3 col = mix(body, foam_color, foam * 0.85);
	col = mix(col, shallow_tint * 1.1, fres * 0.10);      // watery sheen at grazing angles

	ALBEDO = col;
	ROUGHNESS = mix(0.10, 0.34, ripple) - foam * 0.05;
	METALLIC = 0.0;
	SPECULAR = 0.6;
	// Opacity ramps with depth: near-clear at the waterline (bed visible), nearly opaque in
	// the deep centre. Foam + fresnel add their own coverage on top.
	float opacity = mix(0.32, 0.94, deep);
	ALPHA = clamp(opacity + foam * 0.30 + fres * 0.10, 0.0, 0.97) * far_fade;
	EMISSION = (foam_color * (foam * 0.08 + glint * 0.16) + shallow_tint * fres * 0.10) * far_fade;
}
