shader_type canvas_item;
// Frosted-glass backdrop: blurs whatever is behind the panel (the 3D world for the
// in-game Hub/Pause, or the menu's own dark bg) and dims it toward a dark tint. Used by
// GlassBackdrop.tscn placed as the first child of each shell modal. Godot auto-inserts a
// BackBufferCopy because we read the screen texture. Gated by Settings.ui_fx_enabled
// (off → the GlassBackdrop swaps to a plain dim ColorRect, no shader cost).

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur_amount : hint_range(0.0, 6.0) = 2.2;
uniform vec4 tint : source_color = vec4(0.04, 0.05, 0.07, 1.0);
uniform float tint_mix : hint_range(0.0, 1.0) = 0.55;

void fragment() {
	vec2 ps = SCREEN_PIXEL_SIZE * blur_amount;
	vec3 col = vec3(0.0);
	float total = 0.0;
	// 5x5 gaussian-ish kernel (weights fall off from center).
	for (float x = -2.0; x <= 2.0; x += 1.0) {
		for (float y = -2.0; y <= 2.0; y += 1.0) {
			float w = exp(-(x * x + y * y) * 0.35);
			col += texture(screen_tex, SCREEN_UV + vec2(x, y) * ps).rgb * w;
			total += w;
		}
	}
	col /= total;
	col = mix(col, tint.rgb, tint_mix);
	COLOR = vec4(col, 1.0);
}
