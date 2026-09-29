class_name CharacterArt
extends Node2D
## 角色外观。全部用 _draw() 画出来，不依赖美术资源。
##
## 为什么要形状不一样，而不是同一个方块换颜色：
## 颜色是最快认出"我是什么角色"的线索，但本作里角色大半时间泡在自己的介质中
## （熔在岩浆里、霜在水里），而介质与角色的颜色是同一族的，会互相污染。
## 形状差异在那时仍然有效，而且它同时承担了另一件事——设计文档 2.1 要求
## "判定与美术必须一一对应"，看不出自己是谁，就等于看不出这片岩浆会不会烧死自己。
## 因此熔是带棱角的熔岩结晶（下宽上窄、边缘破碎），霜是六角冰晶（对称、边缘笔直）。
##
## 关于形变：起跳拉长、落地压扁（squash & stretch）只写在本节点的 scale 上。
## 远端角色的显示位置是 RemoteInterpolator 写在父节点 Visual 的 position 上的，
## 两者必须分开写，否则会互相覆盖（一个说"往右 3 像素"，另一个说"缩到 0.9"）。
##
## 死亡表现同样只在这里：本体收缩消失并淡出，由 death 进度驱动（0→1）。

## 角色的半身尺寸。与 scenes/player.tscn 里的 RectangleShape2D（48×96）一致；
## 绘制尺寸与碰撞尺寸必须同源，否则会出现"看起来躲过了、实际被判定到"。
const HALF := Vector2(24.0, 48.0)
## 死亡动画时长（秒）。与 Game 里的复活延时（RESPAWN_DELAY）是两件事：
## 这个只管本体消失得多快，复活时机由服务端决定。
const DEATH_TIME := 0.45

var element: int = Element.Kind.MOLTEN
## 朝向。-1 向左、1 向右。只影响眼睛与"脸"的偏移。
var facing: int = 1
## 竖直形变系数。1 为原状，>1 拉长（上升/下落），<1 压扁（刚落地）。
var stretch: float = 1.0

## 死亡进度 0→1。0 表示活着。由 _process 推进，由 set_dead() 归零。
var _death: float = 0.0
var _dying: bool = false


func set_element(kind: int) -> void:
	element = kind
	queue_redraw()


func set_dead(dead: bool) -> void:
	_dying = dead
	if not dead:
		_death = 0.0


func is_dead() -> bool:
	return _dying


func _process(delta: float) -> void:
	if _dying and _death < 1.0:
		_death = minf(_death + delta / DEATH_TIME, 1.0)
	# 形变与死亡进度都只在这里写 scale/alpha，每帧重画一次：
	# 一屏最多两个角色，重画的代价可以忽略，换来的是"所有外观状态都只有一份来源"。
	# 两者相乘而不是相加：形变是挤压（体积大致守恒），死亡是整体缩小，
	# 混在一起算会让"正在死"的角色看起来像被踩扁，而不是消失。
	var alive := 1.0 - _death
	var s := maxf(stretch, 0.05)
	scale = Vector2(1.0 / s, s) * maxf(alive, 0.001)
	modulate.a = alive
	queue_redraw()


func _draw() -> void:
	var body := _body_outline()
	if body.is_empty():
		return
	var col := Element.kind_color(element)
	# 外圈光晕。用同一个多边形放大一圈画一个低透明度的副本，
	# 比做一套贴图的光晕省事，而且不会在放大时露出锯齿状的边缘。
	draw_colored_polygon(_scaled(body, 1.16), Color(col.r, col.g, col.b, 0.14))
	draw_colored_polygon(body, col)
	# 描边用折线闭合：形状不同是这套美术唯一的分辨手段，描边把轮廓钉住。
	var outline := body.duplicate()
	outline.append(body[0])
	draw_polyline(outline, col.darkened(0.55), 3.0)
	_draw_inner(col)
	_draw_face()


## 主体轮廓。两种元素的顶点数刻意不同（十边形 vs 六边形），
## 这样即使色觉有差异、或者画面被介质染色，剪影也还是两个不同的东西。
func _body_outline() -> PackedVector2Array:
	if element == Element.Kind.MOLTEN:
		return PackedVector2Array([
			Vector2(-18, -34), Vector2(-4, -46), Vector2(12, -42), Vector2(22, -26),
			Vector2(17, -4), Vector2(23, 16), Vector2(12, 40), Vector2(-2, 47),
			Vector2(-16, 34), Vector2(-23, 6),
		])
	return PackedVector2Array([
		Vector2(0, -48), Vector2(20, -26), Vector2(21, 14), Vector2(0, 48),
		Vector2(-21, 14), Vector2(-20, -26),
	])


## 元素内部的高光与纹理。熔是几条裂纹，霜是几道笔直的解理面。
func _draw_inner(col: Color) -> void:
	var hot := Color(1.0, 0.86, 0.55)
	var pale := Color(0.88, 0.97, 1.0)
	if element == Element.Kind.MOLTEN:
		draw_colored_polygon(PackedVector2Array([
			Vector2(-6, -22), Vector2(6, -26), Vector2(9, 6), Vector2(0, 22), Vector2(-8, 4),
		]), Color(hot.r, hot.g, hot.b, 0.55))
		for crack in [
			[Vector2(-14, -8), Vector2(-6, 2)],
			[Vector2(12, 14), Vector2(4, 24)],
			[Vector2(6, -34), Vector2(14, -26)],
		]:
			draw_line(crack[0], crack[1], Color(1.0, 0.78, 0.36, 0.85), 2.0)
		# 三粒飘出的火星，让静止时也不完全静止。
		for ember in [Vector2(-22, -44), Vector2(16, -50), Vector2(26, -38)]:
			draw_circle(ember, 2.4, Color(1.0, 0.72, 0.28, 0.9))
		return
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, -34), Vector2(11, -18), Vector2(11, 10), Vector2(0, 34), Vector2(-11, 10), Vector2(-11, -18),
	]), Color(pale.r, pale.g, pale.b, 0.42))
	for facet in [
		[Vector2(0, -34), Vector2(0, 34)],
		[Vector2(-11, -18), Vector2(11, 10)],
		[Vector2(11, -18), Vector2(-11, 10)],
	]:
		draw_line(facet[0], facet[1], Color(0.78, 0.94, 1.0, 0.55), 1.6)
	for shard in [Vector2(-25, -30), Vector2(24, -22), Vector2(-20, 26)]:
		draw_circle(shard, 2.2, Color(0.85, 0.97, 1.0, 0.85))


## 眼睛。它是一次"我还活着、并且朝哪边"的最直接读数，
## 因此位置随 facing 偏移，而不是永远居中——居中会让人分不出自己面朝哪一侧。
func _draw_face() -> void:
	if _death > 0.15:
		return
	var eye := Color(0.08, 0.07, 0.10, 0.9)
	var dx := 3.0 * float(facing)
	draw_circle(Vector2(dx - 8.0, -14.0), 3.4, eye)
	draw_circle(Vector2(dx + 6.0, -14.0), 3.4, eye)
	# 高光点，仅为了让眼睛在深色背景上不像是两个洞。
	draw_circle(Vector2(dx - 9.0, -15.2), 1.2, Color(1, 1, 1, 0.7))
	draw_circle(Vector2(dx + 5.0, -15.2), 1.2, Color(1, 1, 1, 0.7))


## 把多边形以原点为中心放大/缩小。用于画光晕。
func _scaled(points: PackedVector2Array, factor: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(p * factor)
	return out
