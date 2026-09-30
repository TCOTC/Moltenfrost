shader_type canvas_item;
// 菜单与大厅的共用背景：玄武岩底色 + 一层熔/霜色温 + 低频斑块 + 颗粒 + 暗角。
//
// 为什么用着色器而不是叠几个 ColorRect：颗粒与暗角都要"连续变化"，
// 用纯色矩形叠出来会有明显的色带（一层一层的边界比没有还难看）。
// 这几件事在片元着色器里各是一行，而且改一个 uniform 就能调，不需要重新出图。
//
// 色温那一层是**有含义的**，不是装饰：左暖右冷对应标题的「熔」与「霜」，
// 与关卡里"橙=熔、蓝=霜"的元素语言是同一套（见 scripts/ui/game_theme.gd 的文件头）。

uniform vec3 warm : source_color = vec3(0.62, 0.20, 0.05);
uniform vec3 cool : source_color = vec3(0.07, 0.26, 0.45);
// 玄武岩的基色。色温那一层是**叠在它上面**的一层薄色，而不是直接把背景刷成橙蓝。
// 直接刷的话整块背景会变成一锅脏紫，而这是"偏冷的石头被两侧的光照到"。
uniform vec3 stone : source_color = vec3(0.035, 0.042, 0.058);
// 色温占多少。0 = 纯石头，1 = 完全被色温盖住。
// **这个值必须小**：背景是给内容当底的，一亮起来就与前景的面板抢注意力，
// 而面板正是需要被看清的那个。0.13 是"配色感得到、但不会注意到背景"的那一档。
uniform float tint : hint_range(0.0, 1.0) = 0.13;
// 颗粒强度。
uniform float grain : hint_range(0.0, 0.2) = 0.020;
// 暗角强度。
uniform float vignette : hint_range(0.0, 1.0) = 0.60;
// 色温是否缓慢漂移。0 = 完全静止。给 0 的一个用处是截图对照——
// 漂移会让两张截图逐像素不同，比较起来反而看不出改动。
uniform float drift : hint_range(0.0, 1.0) = 1.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	// 色温横向铺开，并叠一层极缓的呼吸（周期约两分钟）。
	// 幅度刻意很小：背景是会动的这件事应该"感觉得到但注意不到"，
	// 幅度一大就会跟界面的内容抢注意力。
	float t = uv.x + sin(TIME * 0.05 + uv.y * 1.7) * 0.03 * drift;
	vec3 tone = mix(warm, cool, smoothstep(0.05, 0.95, t));

	// 玄武岩：低频斑块给出"石头不是平的"，高频颗粒给出"石头不是塑料"。
	float low = hash(floor(uv * vec2(26.0, 15.0)));
	float hi = hash(floor(uv * vec2(420.0, 260.0)));

	vec3 col = mix(stone, stone + tone * 0.7, tint);
	col *= 0.88 + low * 0.16;
	col += (hi - 0.5) * grain;

	// 暗角：把注意力收到中间，同时让四周的面板边缘更清楚。
	vec2 d = uv - vec2(0.5);
	float v = 1.0 - smoothstep(0.26, 0.80, length(d * vec2(1.05, 0.92)));
	col *= mix(1.0 - vignette, 1.0, v);

	COLOR = vec4(col, 1.0);
}
