class_name Hazard
extends Node2D
## 致命介质区域（岩浆池、水池）。
##
## 判定与绘制共用同一个 size，理由与 Solid 相同：本作没有"受伤"这一层，
## 看起来在岸上而实际落在水里，等价于随机暴毙。
##
## 判定用的是**脚点**（角色碰撞箱的底边中点），而不是整个碰撞箱的重叠。
## 这一点很重要，三处都对得上：
##   熔在岩浆里走 → 脚踩在池底，脚点在池底之上，判定为在内；
##   熔站在浮于水面的冰上 → 脚点在冰面（比水面高一个干舷），判定为在外；
##   熔跳过岩浆 → 脚点全程在池子上方，判定为在外。
## 若改用碰撞箱重叠，第一种情况仍然成立，但第二种会变成"脚一沾冰就算落水"，
## 而冰的作用恰恰是让人踩着越过水面，那样冰就完全没用了。

## 判定与绘制共用的矩形尺寸，原点在左上角。
@export var size: Vector2 = Vector2(320.0, 192.0)
## 介质类型，取 Element.Medium。写成 int 而不是类型化枚举是为了让
## 场景文件里能直接写 0/1（@export_enum 的下拉在编辑器里给出中文名）。
@export_enum("岩浆", "水") var medium: int = 0

## 静止站在池底时，脚点正好落在矩形的下边界上，而 Rect2.has_point 把下边界排除在外，
## 因此下边界额外放宽这几个像素。只放宽下边：放宽左右会让站在池边岸上的人被误判为落水，
## 放宽上边会让站在池沿上的人一脚踩进死亡判定。
const BOTTOM_TOLERANCE := 8.0
## 左右两侧各收进来的判定余量。池子与两侧地面是**齐平**的（没有台阶），
## 于是站在池沿上的角色其中心点可能正好压在池壁上：以 48 px 宽的角色为例，
## 它能站在中心点等于池壁 x 的位置上，那一刻按几何算是"在池子里"，
## 但画面上它明明还站在岸上。收进 4 px（一格的十六分之一）就把这条边界消掉，
## 代价是池子两侧各有一条约 4 px 的无判定带——掉下去的人一帧内就深入池中，不会察觉。
const EDGE_INSET := 4.0


func _ready() -> void:
	add_to_group("hazard")
	queue_redraw()


## 点是否落在这个介质区域内。传世界坐标。
func contains_point(point: Vector2) -> bool:
	var local := to_local(point)
	if local.x < EDGE_INSET or local.x > size.x - EDGE_INSET:
		return false
	return local.y >= 0.0 and local.y <= size.y + BOTTOM_TOLERANCE


## 液面的世界 y。浮于水面的冰块要按它定位，见 Game 的造冰规则。
func surface_y() -> float:
	return to_global(Vector2.ZERO).y


func _draw() -> void:
	var col := Element.medium_color(medium)
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, col)
	# 越往下越暗：只有两种颜色的画面里，渐变是唯一能表达"深度"的手段，
	# 而深度在这里是有意义的——池底才是角色的落脚面。
	var bands := 5
	for i in bands:
		var t := float(i) / float(bands)
		var band := Rect2(Vector2(0.0, size.y * t), Vector2(size.x, size.y / float(bands)))
		var shade := col.darkened(0.10 * t)
		draw_rect(band, Color(shade.r, shade.g, shade.b, 0.95))
	# 液面：一条亮线加一层薄高光，它是"这里开始致命"的唯一视觉提示。
	if medium == Element.Medium.LAVA:
		draw_rect(Rect2(Vector2(0.0, 0.0), Vector2(size.x, 6.0)), Color(1.0, 0.72, 0.24, 0.95))
		draw_rect(Rect2(Vector2(0.0, 6.0), Vector2(size.x, 10.0)), Color(1.0, 0.55, 0.12, 0.35))
		_draw_spots(Color(1.0, 0.78, 0.32, 0.5))
	else:
		draw_rect(Rect2(Vector2(0.0, 0.0), Vector2(size.x, 5.0)), Color(0.62, 0.88, 1.0, 0.95))
		draw_rect(Rect2(Vector2(0.0, 5.0), Vector2(size.x, 14.0)), Color(0.45, 0.78, 1.0, 0.28))
		_draw_spots(Color(0.72, 0.92, 1.0, 0.35))


## 介质内部的小斑点。位置由 size 推出来（固定的比例），
## 因此不同大小的池子都会有，不需要在场景里逐个摆装饰。
func _draw_spots(color: Color) -> void:
	var fractions := [Vector2(0.22, 0.38), Vector2(0.68, 0.26), Vector2(0.44, 0.62), Vector2(0.81, 0.72)]
	for f in fractions:
		var at := Vector2(size.x * f.x, size.y * f.y)
		if medium == Element.Medium.LAVA:
			draw_circle(at, 10.0, color)
		else:
			draw_circle(at, 5.0, color)
