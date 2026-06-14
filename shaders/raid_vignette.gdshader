shader_type canvas_item;
render_mode blend_mix;
// A subtle cinematic vignette: dark, slightly-cool edges that fade to a clear centre. Draws a
// tinted alpha over the screen edges (no SCREEN_TEXTURE read — cheap). The "intentional colour
// grade" cue the WorldEnvironment can't provide. Tuned light so it never hurts readability.

uniform float strength : hint_range(0.0, 1.0) = 0.4;
uniform float feather : hint_range(0.0, 1.0) = 0.58;
uniform vec3 tint : source_color = vec3(0.03, 0.045, 0.08);

void fragment() {
	vec2 d = SCREEN_UV - vec2(0.5);
	// Aspect-corrected radius so the vignette is round-ish on wide monitors.
	d.x *= 1.2;
	float r = length(d) * 1.42;
	float v = smoothstep(feather, 1.05, r) * strength;
	COLOR = vec4(tint, v);
}
