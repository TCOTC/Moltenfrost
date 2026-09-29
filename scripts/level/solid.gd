class_name Solid
extends StaticBody2D
## 关卡里的实心方块：地面、台阶、墙、冰墙。
##
## **原点在左上角，size 向右下延伸**——与 Hazard、Goal 同一套约定（见 level.gd）。
## 碰撞与绘制共用同一个 size，因此不存在"看起来站在岸上、实际落在水里"：
## 这条在设计文档 2.1 与 3.2 里是硬要求，本作没有"受伤"这一层，
## 判定与美术不一致直接等价于随机暴毙。
##
## 它自己建碰撞形状，而不是让每个实例在场景里各配一个 CollisionShape2D：
## 一个关卡有几十块地面，逐个配形状意味着每块都要写两份坐标（多边形与形状），
## 两者对不上时画面完全正常、人却会从地面上掉下去。
##
## meltable 给冰墙用：熔的技能可以把整块打掉（Game 负责判定与广播）。
## 打掉是"停用"而不是"删除"，因为关卡重开要把它恢复回来，
## 而删掉的节点没有地方恢复。

## 尺寸（像素）。关卡以 64 px 为一方格（AGENTS.md），因此绝大多数取值应是 64 的倍数。
@export var size: Vector2 = Vector2(256.0, 192.0)
## 主体色。地面偏灰蓝，冰墙偏青。
@export var tint: Color = Color(0.20, 0.22, 0.28)
## 顶面是否画一条亮边。它把"能站的地方"与"只是背景"区分开，
## 在只有色块的画面上这一条尤其重要。
@export var top_highlight: bool = true
## 冰墙：熔的技能可以把它整块化掉。
@export var meltable: bool = false

## 被打掉之后仍然保留在节点树里（关卡重开要恢复），只是看不见也碰不到。
var _broken: bool = false

var _collision: CollisionShape2D = null


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	var shape := RectangleShape2D.new()
	shape.size = size
	_collision = CollisionShape2D.new()
	# 形状相对节点居中，而节点原点在左上角，因此要往右下挪半个尺寸。
	_collision.position = size * 0.5
	_collision.shape = shape
	add_child(_collision)
	add_to_group("solid")
	queue_redraw()


func is_broken() -> bool:
	return _broken


func set_broken(broken: bool) -> void:
	if _broken == broken:
		return
	_broken = broken
	# 碰撞开关不能在物理回调里立刻改，必须延迟到本帧物理结束之后。
	_collision.set_deferred("disabled", broken)
	visible = not broken
	queue_redraw()


## 顶面的世界 y。角色要站上去，Game 造冰时也要拿它当落脚面。
func top_y() -> float:
	return to_global(Vector2.ZERO).y


func _draw() -> void:
	if _broken:
		return
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, tint)
	# 底部压暗一点，让方块看起来有厚度，而不是一张扁纸。
	draw_rect(Rect2(Vector2(0.0, size.y - 12.0), Vector2(size.x, 12.0)), tint.darkened(0.38))
	if top_highlight:
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x, 5.0)), tint.lightened(0.35))
	draw_rect(rect, tint.darkened(0.5), false, 2.0)
	if meltable:
		_draw_ice()


## 冰墙的纹理：几道从上到下的裂纹。画的目的是让人一眼分清
## "墙"（绕不过去、只能找别的路）与"冰墙"（熔可以化掉），两者的解法完全不同。
func _draw_ice() -> void:
	var pale := Color(0.78, 0.94, 1.0, 0.5)
	var x := 24.0
	while x < size.x:
		draw_line(Vector2(x, 6.0), Vector2(x + 14.0, size.y - 6.0), pale, 1.6)
		x += 48.0
	draw_rect(Rect2(Vector2.ZERO, Vector2(size.x, 8.0)), Color(0.86, 0.97, 1.0, 0.55))
