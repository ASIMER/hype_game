shader_type sky;
// Procedural sky for Hype Raiders. No textures.
// A bright-day horizon->zenith gradient, a soft sun disk aligned to the scene's
// directional light (LIGHT0), and two layers of FBM clouds (low cumulus + high
// cirrus) with fake self-shading toward the sun for a volumetric look. The
// `storm` uniform (0..1) darkens the sky, reddens the horizon and thickens the
// clouds so the day->storm tween can drive it.

uniform float storm : hint_range(0.0, 1.0) = 0.0;

// Day palette (bright, set from default_env.tres).
uniform vec3 day_zenith   : source_color = vec3(0.3, 0.5, 0.78);
uniform vec3 day_horizon  : source_color = vec3(0.76, 0.82, 0.9);
uniform vec3 day_ground   : source_color = vec3(0.22, 0.24, 0.26);
// Storm palette.
uniform vec3 storm_zenith  : source_color = vec3(0.04, 0.05, 0.08);
uniform vec3 storm_horizon : source_color = vec3(0.34, 0.12, 0.10);
uniform vec3 storm_ground  : source_color = vec3(0.04, 0.04, 0.05);

uniform vec3 sun_color : source_color = vec3(1.0, 0.94, 0.78);
uniform float sun_size : hint_range(0.0, 0.2) = 0.018;
uniform float sun_blur : hint_range(0.0, 0.5) = 0.12;

uniform float cloud_scale = 2.2;
uniform float cloud_speed = 0.012;
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.5;
uniform vec3 cloud_color  : source_color = vec3(0.96, 0.96, 0.98);

// ---- new tunables (NOT set by the .tres -> need good defaults) ----
// Cumulus shaping: higher = harder/puffier bodies (flatter bases).
uniform float cloud_sharpness : hint_range(0.5, 4.0) = 1.7;
// How strongly cloud bases self-shade vs sun-lit tops.
uniform float cloud_shade : hint_range(0.0, 1.0) = 0.6;
// Silver-lining / rim brightness on cloud edges facing the sun.
uniform float cloud_rim : hint_range(0.0, 2.0) = 0.9;
// High thin cirrus opacity.
uniform float cirrus_amount : hint_range(0.0, 1.0) = 0.35;

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

// 6-octave FBM with a slight rotation per octave to break up grid artifacts.
float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
	for (int i = 0; i < 6; i++) {
		v += amp * vnoise(p);
		norm += amp;
		p = rot * p * 2.02;
		amp *= 0.5;
	}
	return v / norm;
}

// Domain-warped FBM -> billowy cumulus base density (0..1).
float cloud_density(vec2 uv) {
	// Strong domain warp: sample noise to perturb the lookup coordinate.
	vec2 q = vec2(fbm(uv + vec2(1.7, 9.2)), fbm(uv + vec2(8.3, 2.8)));
	vec2 r = vec2(fbm(uv + 4.0 * q + vec2(1.7, 9.2)),
	              fbm(uv + 4.0 * q + vec2(8.3, 2.8)));
	return fbm(uv + 4.0 * r);
}

void sky() {
	float s = clamp(storm, 0.0, 1.0);

	// Blend the palette toward the storm look.
	vec3 zenith  = mix(day_zenith,  storm_zenith,  s);
	vec3 horizon = mix(day_horizon, storm_horizon, s);
	vec3 ground  = mix(day_ground,  storm_ground,  s);

	float up = EYEDIR.y; // -1 down .. 1 up

	// Sky gradient: bright horizon haze climbing to a deeper zenith.
	float grad = pow(clamp(up, 0.0, 1.0), 0.42);
	vec3 sky_col = mix(horizon, zenith, grad);
	// A tighter horizon band of extra warm/atmospheric haze.
	float band = exp(-pow(max(up, 0.0) * 6.0, 1.6));
	vec3 haze_col = mix(horizon * 1.05, horizon, s); // gentle warm haze in day
	sky_col += haze_col * band * (0.22 + 0.30 * s);

	// Below the horizon: dark ground haze.
	float below = smoothstep(0.0, -0.12, up);
	vec3 base = mix(sky_col, ground, below);

	// Sun direction (1 when looking straight at the sun).
	float sd = dot(EYEDIR, -LIGHT0_DIRECTION);
	float ang = acos(clamp(sd, -1.0, 1.0));

	// ---- procedural clouds (only in the upper hemisphere) ----
	// Project EYEDIR onto a plane so clouds stay coherent, scroll with TIME.
	float horizon_fade = smoothstep(-0.02, 0.20, up);
	float planar = 1.0 / (abs(EYEDIR.y) + 0.16);
	vec2 base_uv = EYEDIR.xz * planar;

	// LOW cumulus layer.
	vec2 cuv = base_uv * cloud_scale;
	cuv += vec2(TIME * cloud_speed, TIME * cloud_speed * 0.55);
	float dens = cloud_density(cuv);

	// Cumulus shaping: threshold + pow -> defined puffy bodies, flatter bases.
	float cover = clamp(cloud_cover + 0.34 * s, 0.0, 1.0);
	float thresh = 1.0 - cover;
	float body = smoothstep(thresh - 0.06, thresh + 0.22, dens);
	body = pow(body, cloud_sharpness);
	float cmask = body * horizon_fade;

	// Fake self-shading: sample density slightly TOWARD the sun. Where it gets
	// thinner toward the sun the edge is lit (silver lining); where the core
	// stays dense it's in shadow -> darker base. This is the volumetric trick.
	vec2 sun_uv_dir = normalize(-LIGHT0_DIRECTION).xz;
	float dens_sun = cloud_density(cuv + sun_uv_dir * 0.35);
	float toward_sun = dens_sun - dens;          // <0 = thinning toward sun (lit edge)
	float lit = smoothstep(0.0, -0.16, toward_sun); // 1 on sun-facing thin edges
	float shadow = smoothstep(0.0, 0.18, toward_sun); // 1 where it thickens (shaded)

	// Cloud colour: lit tops bright, shaded bases darker.
	vec3 cl_lit  = cloud_color;
	vec3 cl_dark = cloud_color * mix(vec3(0.55, 0.57, 0.62), vec3(0.30, 0.29, 0.33), s);
	vec3 ccol = mix(cl_lit, cl_dark, shadow * cloud_shade);
	// Silver lining toward the sun, stronger near the sun in the sky.
	float sun_prox = exp(-ang * 2.5);
	ccol += sun_color * lit * cloud_rim * (0.5 + 0.5 * sun_prox) * (1.0 - 0.7 * s);

	// HIGH thin cirrus layer at a different scale/speed -> parallax depth.
	vec2 hiuv = base_uv * (cloud_scale * 2.6);
	hiuv += vec2(TIME * cloud_speed * 1.8, TIME * cloud_speed * 0.4);
	float hi = fbm(hiuv);
	hi = fbm(hiuv + vec2(hi, -hi) * 0.6);
	float hicov = clamp(0.55 - 0.15 * (1.0 - cirrus_amount), 0.0, 1.0);
	float himask = smoothstep(hicov, hicov + 0.30, hi) * horizon_fade;
	himask *= cirrus_amount * (1.0 - 0.4 * s);
	vec3 hicol = mix(cloud_color, cl_dark, 0.3 + 0.5 * s);
	// Composite: cirrus behind, cumulus in front.
	base = mix(base, hicol, himask * 0.5);
	base = mix(base, ccol, clamp(cmask, 0.0, 1.0) * (0.85 + 0.12 * s));

	// ---- sun disk aligned to the directional light ----
	float disk = 1.0 - smoothstep(sun_size, sun_size + sun_blur, ang);
	// Slightly stronger, softer halo in day; tighter & redder in storm.
	float halo = exp(-ang * (4.5 + 11.0 * s)) * (0.45 - 0.10 * s);
	vec3 scol = mix(sun_color, sun_color * vec3(1.0, 0.55, 0.4), s);
	// Sun dimmed/reddened by storm and softly occluded by the cumulus mask.
	float sun_vis = (1.0 - 0.6 * s) * (1.0 - 0.8 * cmask);
	base += scol * (disk * 4.0 + halo) * sun_vis * LIGHT0_ENERGY;

	// Overall darkening in the storm.
	base *= (1.0 - 0.45 * s);

	COLOR = base;
}
