class_name Goal
extends Node2D
## 关卡出口。判定条件是"**所有**活着的角色都在这里"（Game 负责判定）：
## 设计文档 6.1 定的合作模式是两人一起过关，因此出口不是一个人先跑到就结束，
## 而是两人同时站在门里——这一条本身就是一个需要沟通的动作，
## 与机制与玩法设计 7.1 的"需要两人同时到位"是同一类约束。
##
## 所以它画成一扇**双开的门**：门的宽窄直接表示"两个人要一起进来"，
## 而单人游玩时（场上只有一个角色）同一个判定自然退化为"一个人进来即可"。

@export var size: Vector2 = Vector2(256.0, 96.0)

var _open: bool = false


func _ready() -> void:
	add_to_group("goal")
	queue_redraw()


## 判定点用局部坐标的矩形。原点在矩形左上角，与 Hazard 一致，
## 这样在编辑器里摆的时候，位置就是"门框的左上角"。
func contains_point(point: Vector2) -> bool:
	return Rect2(Vector2.ZERO, size).has_point(to_local(point))


func set_open(open: bool) -> void:
	if _open == open:
		return
	_open = open
	queue_redraw()


func _draw() -> void:
	var warm := Element.MOLTEN_COLOR
	var cool := Element.FROST_COLOR
	var glow := Color(0.55, 0.95, 0.75) if _open else Color(0.36, 0.40, 0.48)
	var rect := Rect2(Vector2.ZERO, size)
	# 门内的地面：亮起来表示"这里可以进"。
	draw_rect(rect, Color(glow.r, glow.g, glow.b, 0.18 if not _open else 0.30))
	# 两根门柱，一暖一冷——出口同时是"两个人的门"这件事的视觉表达。
	var post := size.y * 0.95
	draw_rect(Rect2(Vector2(0.0, -post + size.y), Vector2(16.0, post)), warm.darkened(0.25))
	draw_rect(Rect2(Vector2(size.x - 16.0, -post + size.y), Vector2(16.0, post)), cool.darkened(0.25))
	draw_rect(Rect2(Vector2(0.0, -post + size.y), Vector2(size.x, 8.0)), glow)
	# 门里的一道竖光，提示"往里走"。
	var mid := size.x * 0.5
	draw_rect(Rect2(Vector2(mid - 6.0, -post + size.y + 8.0), Vector2(12.0, post - 8.0)),
		Color(glow.r, glow.g, glow.b, 0.35))
	draw_rect(Rect2(Vector2.ZERO, size), Color(glow.r, glow.g, glow.b, 0.85), false, 2.0)
