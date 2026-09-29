class_name ScorePickup
extends Node2D
## 关卡内的积分点（设计文档 6.2）。
##
## 判定用**圆形距离**而不是矩形：本节点在自转（旋转是它唯一的表现手段，
## 静止的菱形在深色背景上很容易被当成装饰），而矩形判定会被旋转带着一起转，
## 于是"看起来碰到了、判定没到"会在某些角度出现。圆形判定与角度无关。
##
## 它同时是关卡设计的调节旋钮：设计文档 6.2 要求积分放在"明显但要绕路"的地方，
## 因此摆放时看的是它与主路线的距离，而不是它的分值。

## 拾取半径（像素）。比图形略大一点，给手滑留余量。
const RADIUS := 34.0

@export var value: int = 50

var _taken: bool = false


func _ready() -> void:
	# 画在角色之下（角色的 z_index 是 2）。压在角色身上的金币会挡住他的眼睛，
	# 而眼睛是这个画面里唯一能看出"我是谁、我朝哪边"的东西。
	z_index = 1
	queue_redraw()


func contains_point(point: Vector2) -> bool:
	if _taken:
		return false
	return global_position.distance_to(point) <= RADIUS


func set_taken(taken: bool) -> void:
	if _taken == taken:
		return
	_taken = taken
	visible = not taken
	queue_redraw()


func _process(delta: float) -> void:
	if _taken:
		return
	rotation += delta * 1.6


func _draw() -> void:
	if _taken:
		return
	# 菱形。用两个三角形拼，比 draw_colored_polygon 少一次三角化。
	var gold := Color(1.0, 0.82, 0.32)
	var r := 20.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(0.0, -r), Vector2(r * 0.62, 0.0), Vector2(0.0, r), Vector2(-r * 0.62, 0.0),
	]), Color(gold.r, gold.g, gold.b, 0.22))
	draw_colored_polygon(PackedVector2Array([
		Vector2(0.0, -r * 0.72), Vector2(r * 0.44, 0.0), Vector2(0.0, r * 0.72), Vector2(-r * 0.44, 0.0),
	]), gold)
	draw_polyline(PackedVector2Array([
		Vector2(0.0, -r * 0.72), Vector2(r * 0.44, 0.0), Vector2(0.0, r * 0.72),
		Vector2(-r * 0.44, 0.0), Vector2(0.0, -r * 0.72),
	]), gold.darkened(0.45), 2.0)
