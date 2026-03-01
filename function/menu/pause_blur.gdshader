shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform float blur_amount : hint_range(0.5, 4.0) = 1.5;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 pixel_size = SCREEN_PIXEL_SIZE * blur_amount;
	
	vec4 color = vec4(0.0);
	float total = 0.0;
	int radius = 3;
	for (int x = -radius; x <= radius; x++) {
		for (int y = -radius; y <= radius; y++) {
			color += texture(screen_texture, uv + vec2(float(x), float(y)) * pixel_size);
			total += 1.0;
		}
	}
	COLOR = color / total;
}
