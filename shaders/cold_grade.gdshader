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
// D1 RELIGHT — THE TWO NUMBERS THAT DEFINE THIS GRADE (derive them again if you retune):
//   T1 = screen luma where the split-tone itself stops tinting cool (shadow_tint gain ==
//        highlight_tint gain, per channel R vs B).
//   T2 = screen luma where the FULL chain (split × cool_bias) stops tinting cool.
// Everything below T2 reads cold — so T2 is the floor a surface must clear to keep its own
// colour. Measured baseline was T1 0.588 / T2 0.662, and 88% of machine-hull and building
// pixels sat under it: the world was not "dark", it was being pulled cold-blue wholesale.
// Retuned here to T1 ≈ 0.516 / T2 ≈ 0.547 — the cold identity is kept (deep shadows still
// run B/R ≈ 1.33) but the dead band is a third as wide and 0.09 lower, so mid-tone plates,
// facades and gravel keep their own hue instead of going to steel-blue milk.
// Derivation: T1 solves shadow_tint.r + t·Δr == shadow_tint.b + t·Δb; T2 solves the same
// with cool_bias.r / cool_bias.b folded in; then invert smoothstep(split_lo, split_hi, ·)
// and undo the crush re-normalisation (× (1-crush) + crush).
uniform vec3 shadow_tint : source_color = vec3(0.80, 0.87, 1.02);
uniform vec3 highlight_tint : source_color = vec3(1.1, 1.0, 0.85);
uniform float split_lo : hint_range(0.0, 1.0) = 0.26;
// 0.88 → 0.78: the warm end was so high that nothing in a fogged daylight frame ever
// reached it — every surface lived on the cool side of the split. Lowering it pulls BOTH
// thresholds down together (the single most effective knob here).
uniform float split_hi : hint_range(0.0, 1.0) = 0.78;
// 0.05 → 0.015 (texture-quality pass): the hard `max(orig - crush)` floor ZEROED every
// screen value below 0.05 — shaded building faces (~0.03-0.05 after AgX) became pure
// #000 and NO ambient/fill light could ever show through. A 0.015 toe keeps blacks rich
// while letting the new shade-fill read as dark steel instead of coal.
uniform float crush : hint_range(0.0, 0.2) = 0.015;
// 0.10 → 0.06: this stacks with the Environment's own `adjustment_saturation` (0.92 in
// default_env.tres), so the frame was carrying ~0.17 of desaturation — enough that painted
// identity colours (rust, lacquer, container livery) read as the same grey. The two
// together now come to ~0.09.
uniform float desat : hint_range(0.0, 1.0) = 0.06; // pull toward luma (industrial drab)
// A global cool bias so EVERY frame (not just stormy ones) reads cold-steel.
// Softened from (0.96, 0.99, 1.06): that spread alone held T2 a full 0.074 above T1, i.e. a
// wide band where the split-tone had already gone warm but the bias still forced it cold.
uniform vec3 cool_bias : source_color = vec3(0.985, 0.995, 1.03);


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
