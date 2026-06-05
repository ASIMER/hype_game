shader_type sky;
// Procedural dusk sky for Hype Raiders. No textures.
// A cohesive horizon-glow -> deep-zenith gradient, a soft sun disk aligned to
// the scene's directional light (LIGHT0), and a few octaves of scrolled
// value-noise clouds. The `storm` uniform (0..1) darkens the sky, reddens the
// horizon and thickens the clouds so the day->storm tween can drive it.

uniform float storm : hint_range(0.0, 1.0) = 0.0;

// Dusk palette (calm / day end).
uniform vec3 day_zenith   : source_color = vec3(0.14, 0.20, 0.34);
uniform vec3 day_horizon  : source_color = vec3(0.62, 0.46, 0.34);
uniform vec3 day_ground   : source_color = vec3(0.10, 0.10, 0.12);
// Storm palette.
uniform vec3 storm_zenith  : source_color = vec3(0.04, 0.05, 0.08);
uniform vec3 storm_horizon : source_color = vec3(0.34, 0.12, 0.10);
uniform vec3 storm_ground  : source_color = vec3(0.04, 0.04, 0.05);

uniform vec3 sun_color : source_color = vec3(1.0, 0.78, 0.5);
uniform float sun_size : hint_range(0.0, 0.2) = 0.018;
uniform float sun_blur : hint_range(0.0, 0.5) = 0.12;

uniform float cloud_scale = 2.2;
uniform float cloud_speed = 0.012;
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.42;
uniform vec3 cloud_color  : source_color = vec3(0.66, 0.6, 0.58);

// ---- cheap value noise (hash on a 2D point) ----
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
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

void sky() {
	float s = clamp(storm, 0.0, 1.0);

	// Blend the palette toward the storm look.
	vec3 zenith  = mix(day_zenith,  storm_zenith,  s);
	vec3 horizon = mix(day_horizon, storm_horizon, s);
	vec3 ground  = mix(day_ground,  storm_ground,  s);

	float up = EYEDIR.y; // -1 down .. 1 up

	// Sky gradient: warm horizon glow climbing to a deep zenith.
	float grad = pow(clamp(up, 0.0, 1.0), 0.42);
	vec3 sky_col = mix(horizon, zenith, grad);
	// A tighter horizon band of extra glow.
	float band = exp(-pow(max(up, 0.0) * 6.0, 1.6));
	sky_col += horizon * band * (0.35 + 0.25 * s);

	// Below the horizon: dark ground haze.
	float below = smoothstep(0.0, -0.12, up);
	vec3 base = mix(sky_col, ground, below);

	// ---- procedural clouds (only in the upper hemisphere) ----
	// Project EYEDIR onto a plane so clouds stay coherent, scroll with TIME.
	vec2 cuv = EYEDIR.xz / (abs(EYEDIR.y) + 0.18);
	cuv *= cloud_scale;
	cuv += vec2(TIME * cloud_speed, TIME * cloud_speed * 0.6);
	float clouds = fbm(cuv);
	clouds = fbm(cuv + vec2(clouds, -clouds) * 0.5); // domain warp for wisps

	float cover = clamp(cloud_cover + 0.32 * s, 0.0, 1.0);
	float cmask = smoothstep(1.0 - cover - 0.18, 1.0 - cover + 0.18, clouds);
	cmask *= smoothstep(-0.02, 0.22, up); // fade clouds into the horizon
	// Storm clouds are darker and heavier.
	vec3 ccol = mix(cloud_color, cloud_color * vec3(0.42, 0.40, 0.44), s);
	base = mix(base, ccol, cmask * (0.6 + 0.25 * s));

	// ---- sun disk aligned to the directional light ----
	float sd = dot(EYEDIR, -LIGHT0_DIRECTION); // 1 when looking at the sun
	float ang = acos(clamp(sd, -1.0, 1.0));
	float disk = 1.0 - smoothstep(sun_size, sun_size + sun_blur, ang);
	float halo = exp(-ang * (6.0 + 10.0 * s)) * 0.35;
	vec3 scol = mix(sun_color, sun_color * vec3(1.0, 0.55, 0.4), s);
	// Sun is dimmed and reddened by the storm and occluded by clouds.
	float sun_vis = (1.0 - 0.6 * s) * (1.0 - 0.7 * cmask);
	base += scol * (disk * 4.0 + halo) * sun_vis * LIGHT0_ENERGY;

	// Overall darkening in the storm.
	base *= (1.0 - 0.45 * s);

	COLOR = base;
}
