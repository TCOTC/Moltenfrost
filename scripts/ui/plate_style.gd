class_name PlateStyle
extends StyleBox
## 一块"切角金属板"：八边形（四角斜切）＋ 外侧暗线 ＋ 内侧亮边。
##
## 为什么自己写 StyleBox 而不用 StyleBoxFlat：后者的圆角只有"半径"这一个维度，画不出切角。
## 而切角正是这套界面的形状语言——熔岩与冰霜都是**晶体**，圆角读起来太软
## （像移动端 App），斜切才有石板的硬边，也才与关卡里棱角分明的方块一致。
##
## 描边分两层，缺一层就少一样东西：
##   外侧暗线 —— 把板子与背景切开，没有它面板会糊在背景上
##   内侧亮边 —— 只在左边与上边亮，光才有方向；四面一样亮就成了等宽描边，没有厚度
##
## 它只用 RenderingServer 的 canvas_item_* 画多边形，不依赖任何贴图，
## 因此与工程里其它界面一样属于"代码绘制"，改一个数就能调（见 scripts/ui/game_theme.gd 的说明）。

## 斜切边长（像素）。它决定这块板"有多硬"：越小越接近直角，越大越像被削掉一角。
## 做成 var 而不是 const，因为按钮（小）与面板（大）需要的切角不一样大——
## 同样的 10 px 在大面板上几乎看不出来，在小按钮上却会把按钮削成菱形。
var chamfer: float = 10.0
## 板面颜色。
var fill: Color = Color(0.075, 0.086, 0.114, 0.92)
## 外侧暗线。默认是"比板面更暗"，因此不需要每个调用点都传。
var edge: Color = Color(0.05, 0.06, 0.085, 0.95)
var edge_width: float = 1.0
## 内侧亮边。调用点按冷暖改它的色相，但 alpha 一般只微调。
var bevel: Color = Color(1.0, 1.0, 1.0, 0.07)
var bevel_width: float = 1.0
## 亮边离外框的距离。与 edge_width 分开是因为"描边有多粗"与"亮线离边缘多远"是两件事。
var bevel_inset: float = 2.0
## 外发光。主按钮用它把"这是主动作"说清楚。alpha 为 0 时不画。
var glow: Color = Color(0, 0, 0, 0)
## 发光的厚度（像素）。越大越糊，是"辉光"不是"描边"。
var glow_width: float = 0.0
## 发光的分层数。层数越多越平滑，代价是每次重绘多几个多边形。
var glow_steps: int = 5


func _draw(canvas_item: RID, rect: Rect2) -> void:
	# 极小尺寸直接不画：切角在几个像素的矩形上算出来的八边形会自交，
	# 那种情况下画出来是一团乱线，不如什么都不画。
	if rect.size.x <= 4.0 or rect.size.y <= 4.0:
		return
	var body := polygon(rect, 0.0)
	if glow.a > 0.0 and glow_width > 0.0:
		_draw_glow(canvas_item, rect)
	RenderingServer.canvas_item_add_polygon(canvas_item, body, [fill])
	RenderingServer.canvas_item_add_polyline(canvas_item, _closed(body), [edge], edge_width, true)
	# 内侧两条棱。顺序固定：暗的那圈先画，亮的盖在上面。
	var inner := polygon(rect, edge_width + bevel_inset)
	var dim := bevel
	dim.a *= 0.30
	RenderingServer.canvas_item_add_polyline(canvas_item, _closed(inner), [dim], bevel_width, true)
	# 受光的一侧：左边缘上行 → 上边缘 → 右上斜切（下标 7,0,1,2）。
	# 这四条线正好构成"光从左上来"的那一面。
	RenderingServer.canvas_item_add_polyline(
		canvas_item, PackedVector2Array([inner[7], inner[0], inner[1], inner[2]]),
		[bevel], bevel_width, true
	)


## 把 rect 向内收 inset 之后得到的切角八边形，顶点从左上斜切的起点开始顺时针排列。
## 公开是为了让调用点（例如需要自绘同形状的东西）能复用同一套顶点定义。
func polygon(rect: Rect2, inset: float) -> PackedVector2Array:
	var r := rect.grow(-inset)
	# 斜切不能超过边长的一半，否则八边形会自交（表现为一个扭结的形状）。
	var cut := minf(chamfer, minf(r.size.x, r.size.y) * 0.45)
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	return PackedVector2Array([
		Vector2(x + cut, y),
		Vector2(x + w - cut, y),
		Vector2(x + w, y + cut),
		Vector2(x + w, y + h - cut),
		Vector2(x + w - cut, y + h),
		Vector2(x + cut, y + h),
		Vector2(x, y + h - cut),
		Vector2(x, y + cut),
	])


## 把发光画成几圈逐渐变大的同形状多边形。这不是真正的高斯模糊，
## 但对"一圈柔和的暖光"来说够了，而且不需要任何后处理。
func _draw_glow(canvas_item: RID, rect: Rect2) -> void:
	var center := rect.get_center()
	for i in range(glow_steps, 0, -1):
		var t := glow_width * float(i) / float(glow_steps)
		var c := glow
		# 越靠外越淡：外圈 alpha 最小，内圈最大，叠起来就是一条从边缘淡出的光。
		c.a = glow.a * (1.0 - float(i) / float(glow_steps + 1)) * 0.55
		var pts := polygon(rect, 0.0)
		for index in pts.size():
			pts[index] += (pts[index] - center).normalized() * t
		RenderingServer.canvas_item_add_polygon(canvas_item, pts, [c])


func _closed(points: PackedVector2Array) -> PackedVector2Array:
	var out := points.duplicate()
	out.append(points[0])
	return out


# ---------------------------------------------------------------- 工厂

## 常规板面。`light` 决定这条棱偏暖还是偏冷——界面上的暖冷是有含义的（见 game_theme.gd 文件头），
## 因此这里不改它的色相，只改亮度，由调用点自己选色。
static func plate(fill: Color, chamfer: float, lit: Color) -> PlateStyle:
	var style := PlateStyle.new()
	style.fill = fill
	style.chamfer = chamfer
	style.bevel = lit
	return style


## 主按钮：实心 + 外发光。发光色一般就是底色，这样它看起来像自己在发热。
static func glowing(fill: Color, chamfer: float, glowing_color: Color) -> PlateStyle:
	var style := plate(fill, chamfer, Color(1.0, 1.0, 1.0, 0.16))
	style.glow = glowing_color
	style.glow.a = 0.30
	style.glow_width = 9.0
	return style


## 只改填充色，其余形状与发光保持不变。hover / pressed / disabled 都靠它派生，
## 这样"按钮的形状语言"永远只有一份，不会出现某个状态悄悄换了形状。
func recolored(color: Color) -> PlateStyle:
	var style := _copy()
	style.fill = color
	return style


func _copy() -> PlateStyle:
	var style := PlateStyle.new()
	style.chamfer = chamfer
	style.fill = fill
	style.edge = edge
	style.edge_width = edge_width
	style.bevel = bevel
	style.bevel_width = bevel_width
	style.bevel_inset = bevel_inset
	style.glow = glow
	style.glow_width = glow_width
	style.glow_steps = glow_steps
	return style


## 内容内边距。PanelContainer / Button 会读它来排版子节点与文字，
## 不设的话所有内容都贴着切角，看起来像溢出。
func with_padding(horizontal: float, vertical: float) -> PlateStyle:
	set_content_margin(SIDE_LEFT, horizontal)
	set_content_margin(SIDE_RIGHT, horizontal)
	set_content_margin(SIDE_TOP, vertical)
	set_content_margin(SIDE_BOTTOM, vertical)
	return self
