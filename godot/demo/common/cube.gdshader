shader_type spatial;

// One material shared by every cube; the per-cube color is an instance
// parameter so thousands of cubes don't mean thousands of materials.
instance uniform vec4 tint : source_color = vec4(0.9, 0.9, 0.9, 1.0);

void fragment() {
	ALBEDO = tint.rgb;
	ROUGHNESS = 0.8;
}
