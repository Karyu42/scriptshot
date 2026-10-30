shader_type canvas_item;
render_mode unshaded;

// Flat-coloured disc / ellipse on a unit quad. Colour comes from the MultiMesh
// per-instance colour; edges are anti-aliased with a 1-pixel-ish smoothstep.
void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float w = fwidth(d);
	float a = 1.0 - smoothstep(1.0 - w * 1.5, 1.0, d);
	COLOR = vec4(COLOR.rgb, COLOR.a * a);
}
