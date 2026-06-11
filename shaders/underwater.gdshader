shader_type canvas_item;
// Full-screen underwater post effect for the local player's camera.
// Blue-green tint + gentle sin-wobble UV distortion + soft vignette, all scaled by
// `strength` (0 = invisible, 1 = fully submerged). Driven from UnderwaterOverlay which
// ramps strength on Events.water_state_changed (WADING = slight, SUBMERGED = full).

uniform float strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 tint : source_color = vec4(0.10, 0.42, 0.55, 1.0);
uniform float wobble_amp = 0.012;     // UV displacement amplitude (full strength)
uniform float wobble_speed = 1.6;
uniform float vignette_strength = 0.7;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

void fragment() {
	vec2 uv = SCREEN_UV;

	// Gentle wobble: two sine waves over UV+TIME so the screen ripples like looking
	// through water. Scaled by strength so it eases in/out with submersion.
	float w = wobble_amp * strength;
	vec2 warp;
	warp.x = sin(uv.y * 28.0 + TIME * wobble_speed) * w;
	warp.y = cos(uv.x * 24.0 + TIME * wobble_speed * 1.3) * w;
	vec2 suv = clamp(uv + warp, vec2(0.0), vec2(1.0));

	vec3 col = texture(screen_tex, suv).rgb;

	// Blue-green tint, mixed in proportional to strength.
	col = mix(col, col * tint.rgb + tint.rgb * 0.18, strength * 0.85);

	// Soft vignette darkening toward the edges (murky depth).
	float d = distance(uv, vec2(0.5));
	float vig = 1.0 - smoothstep(0.25, 0.85, d) * vignette_strength * strength;
	col *= vig;

	COLOR = vec4(col, strength);
}
