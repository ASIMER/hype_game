shader_type canvas_item;
// Cold cinematic colour grade (Marathon / Arc Raiders look): teal-steel shadows, warm
// highlights, crushed blacks, slight industrial desaturation. A committed "this world is
// deliberately graded" pass — the thing the subtle WorldEnvironment adjustment couldn't give.
// Reads the rendered 3D frame via the canvas_item screen texture and re-grades it; mounted on
// a ColorRect at a CanvasLayer BELOW the HUD so the world is graded but UI text stays crisp.
// Render-only, per-peer, no netcode. Gated by Settings.ui_fx_enabled + raid state.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
// 0.88 → 0.60 (art-panel "one cold pass, not three"): with split_lo at 0.42 the MIDS
// lived inside the shadow tint — the whole world was blue-multiplied into milk. The
// grade now only claims true shadows; mids keep their color information.
uniform float strength : hint_range(0.0, 1.0) = 0.6;
uniform vec3 shadow_tint : source_color = vec3(0.74, 0.84, 1.02);
uniform vec3 highlight_tint : source_color = vec3(1.1, 1.0, 0.85);
uniform float split_lo : hint_range(0.0, 1.0) = 0.26;
uniform float split_hi : hint_range(0.0, 1.0) = 0.88;
// 0.05 → 0.015 (texture-quality pass): the hard `max(orig - crush)` floor ZEROED every
// screen value below 0.05 — shaded building faces (~0.03-0.05 after AgX) became pure
// #000 and NO ambient/fill light could ever show through. A 0.015 toe keeps blacks rich
// while letting the new shade-fill read as dark steel instead of coal.
uniform float crush : hint_range(0.0, 0.2) = 0.015;
uniform float desat : hint_range(0.0, 1.0) = 0.10; // pull toward luma (industrial drab)
// A global cool bias so EVERY frame (not just stormy ones) reads cold-steel.
uniform vec3 cool_bias : source_color = vec3(0.96, 0.99, 1.06);


void fragment() {
	vec3 orig = texture(screen_tex, SCREEN_UV).rgb;
	// Crush blacks: deeper, richer shadows.
	vec3 c = max(orig - crush, vec3(0.0)) / (1.0 - crush);
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
	// Split-tone: cool/teal in shadow + MIDS, warm only in true highlights (high threshold).
	vec3 split = mix(shadow_tint, highlight_tint, smoothstep(split_lo, split_hi, luma));
	c *= split;
	// Slight desaturation toward luma for the cohesive cold-industrial drab.
	c = mix(c, vec3(luma), desat);
	// Global cool bias so the whole frame leans cold-steel (the unifying identity).
	c *= cool_bias;
	c = clamp(c, vec3(0.0), vec3(1.0));
	COLOR = vec4(mix(orig, c, strength), 1.0);
}
