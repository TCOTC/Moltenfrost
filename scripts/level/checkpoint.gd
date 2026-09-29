class_name Checkpoint
extends Node2D
## 关卡内的检查点：死亡后从这里复活（设计文档 1.2、机制与玩法设计 6.1）。
##
## 节点原点**就是角色脚踩的那个点**，旗子画在原点上方。这样摆关卡时看到的是
## "人会站在这里"，不需要心算偏移量。角色的节点原点是它的中心，因此复活时要往上
## 抬半个身高（见 respawn_point），否则人会出现半截埋在土里、也可能直接卡进地面。
##
## 谁到达过哪个检查点由服务端记录（它能看到所有角色的位置），
## 本节点只提供几何：一个触发范围与一个复活点。

## 触发范围（局部坐标）。以原点的地面点为底边向上覆盖整个角色高度，
## 因此"站着不动"的角色的中心点必然落在里面。
const TRIGGER := Rect2(-72.0, -128.0, 144.0, 128.0)
## 复活时的抬升量 = 角色碰撞箱的半高（scenes/player.tscn 里的 48×96）。
## 两者必须同源：改了碰撞箱尺寸就要改这里，否则复活后会有一次下坠或被卡住。
const SPAWN_LIFT := 48.0
## 序号。0 号是关卡起点，必须存在；其余按位置从左到右排。
@export var index: int = 0

var _active: bool = false


func _ready() -> void:
	add_to_group("checkpoint")
	queue_redraw()


func contains_point(point: Vector2) -> bool:
	return TRIGGER.has_point(to_local(point))


## 复活坐标（世界坐标），可直接写给角色的 position。
func respawn_point() -> Vector2:
	return global_position - Vector2(0.0, SPAWN_LIFT)


func set_active(active: bool) -> void:
	if _active == active:
		return
	_active = active
	queue_redraw()


## 旗子画在**头顶以上**，底座画在脚下。这样一个人站在检查点上时旗子不会压在他身上——
## 出生点就摆在 0 号检查点上，旗子画在头高处的样子是"脸上糊了一块三角形"。
## 旗杆会穿过角色，但检查点画在角色之下（关卡节点的 z_index 低于角色），所以看不见。
func _draw() -> void:
	var pole := Color(0.66, 0.70, 0.78)
	var flag := Color(0.42, 0.92, 0.62) if _active else Color(0.46, 0.50, 0.58)
	# 底座：让人看得出"这里是个点"，而不是浮在空中的一面旗。
	draw_rect(Rect2(Vector2(-26.0, -8.0), Vector2(52.0, 10.0)), Color(0.16, 0.18, 0.22))
	draw_rect(Rect2(Vector2(-18.0, -6.0), Vector2(36.0, 6.0)), pole.darkened(0.3))
	draw_line(Vector2(0.0, -6.0), Vector2(0.0, -146.0), pole, 4.0)
	draw_colored_polygon(PackedVector2Array([
		Vector2(2.0, -144.0), Vector2(56.0, -128.0), Vector2(2.0, -112.0),
	]), flag)
	draw_polyline(PackedVector2Array([
		Vector2(2.0, -144.0), Vector2(56.0, -128.0), Vector2(2.0, -112.0), Vector2(2.0, -144.0),
	]), flag.darkened(0.45), 2.0)
