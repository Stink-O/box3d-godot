// Sample floor: an anti-aliased procedural grid. 1 m minor lines, a major line
// every 5 m, about 1 px wide at any distance (screen-space derivatives), fading
// out 25-110 m from the camera so the horizon does not shimmer. On a 300 m floor
// it reads as endless against the sky environment's ground colour.
shader_type spatial;
render_mode cull_disabled;

uniform vec3 base_color : source_color = vec3(0.30, 0.31, 0.33);
uniform vec3 line_color : source_color = vec3(0.42, 0.44, 0.47);
uniform float fade_start = 25.0;
uniform float fade_end = 110.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid(vec2 p, float spacing) {
	vec2 q = p / spacing;
	vec2 w = fwidth(q);
	vec2 g = abs(fract(q - 0.5) - 0.5) / max(w, vec2(1e-5));
	return 1.0 - clamp(min(g.x, g.y), 0.0, 1.0);
}

void fragment() {
	float minor = grid(world_pos.xz, 1.0);
	float major = grid(world_pos.xz, 5.0);
	float d = distance(world_pos, CAMERA_POSITION_WORLD);
	float fade = 1.0 - smoothstep(fade_start, fade_end, d);
	float line = max(minor * 0.55, major) * fade;
	ALBEDO = mix(base_color, line_color, line);
	ROUGHNESS = 0.95;
	SPECULAR = 0.05;
}
