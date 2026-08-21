// Pooled tracer segments (TracerPool MultiMesh): every live segment is one instance;
// INSTANCE_CUSTOM.x carries its birth time on the pool clock. Expired instances are
// collapsed to a degenerate point in the VERTEX stage, so the CPU never has to
// reclaim them — the ring buffer simply overwrites slots as new shots land.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, shadows_disabled, cull_disabled;

uniform float u_now = 0.0;
uniform float u_lifetime = 0.09;
uniform vec3 u_color: source_color = vec3(1.0, 0.92, 0.62);
uniform vec3 u_emission: source_color = vec3(1.0, 0.8, 0.4);
uniform float u_emission_energy = 2.0;

varying float v_k;

void vertex() {
	float k = clamp((u_now - INSTANCE_CUSTOM.x) / u_lifetime, 0.0, 1.0);
	v_k = k;
	if (k >= 1.0) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	float fade = 1.0 - v_k;
	ALBEDO = u_color * fade;
	EMISSION = u_emission * u_emission_energy * fade;
	ALPHA = fade;
}
