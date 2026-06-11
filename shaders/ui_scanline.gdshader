shader_type canvas_item;
render_mode blend_mix;
// Subtle "CRT/holo" veil for the menu/hub shell — thin scanlines + animated film grain
// + a soft edge vignette, all DARKENING only (black with low alpha) so it reads as a
// tasteful overlay, never washes the UI out. Drawn by a full-rect ColorRect on the
// FXOverlay CanvasLayer; gated by Settings.ui_fx_enabled. Cheap (no texture reads).

uniform float scanline_strength : hint_range(0.0, 0.2) = 0.05;
uniform float grain_strength : hint_range(0.0, 0.2) = 0.04;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.35;
uniform float scanline_count = 720.0;
uniform float max_alpha : hint_range(0.0, 1.0) = 0.55;

float rand(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	// Scanlines: a soft sine band along Y.
	float sl = sin(uv.y * scanline_count * 3.14159265) * 0.5 + 0.5;
	float scan = sl * scanline_strength;
	// Animated grain (darkening speckle).
	float g = abs(rand(uv + vec2(TIME * 0.53, TIME * 0.37)) - 0.5) * grain_strength;
	// Edge vignette.
	float d = distance(uv, vec2(0.5));
	float vig = smoothstep(0.42, 0.78, d) * vignette_strength;
	float a = clamp(scan + g + vig, 0.0, max_alpha);
	COLOR = vec4(0.0, 0.0, 0.0, a);
}
