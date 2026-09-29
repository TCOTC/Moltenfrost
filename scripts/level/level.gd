class_name Level
extends Node2D
## 一个关卡的场景根。它只描述"这一关有什么"，不持有任何会话状态。
##
## 谁在这张图上、谁死了、积分多少、通关没有，全部属于 Game（scripts/game/game.gd）。
## 这样分开有两个实际好处：关卡可以在编辑器里单独打开看、单独试走，不需要联网；
## 而换关卡只是换一个场景文件，Game 的规则一行都不用改。
##
## 几何约定（Solid / Hazard / Goal 三者一致，Checkpoint 与积分点是点）：
##   **节点位置就是矩形的左上角，size 向右下延伸。**
## 统一成"左上角 + 尺寸"而不是"中心 + 尺寸"，是因为摆关卡时想的是
## "这段地面从 x1 到 x2、顶面在 y"——也就是两个角。用中心的话每次都要心算一次
## (x1+x2)/2，而算错一次的表现是地面错位半格，看起来像美术问题。
##
## 收集子节点用一次手写递归而不是 find_children()：后者的 type 过滤在
## 脚本 class_name 上的行为要查文档才知道，而这里只需要"是不是 Hazard"，
## 手写递归的语义没有任何解释空间，也不会随引擎版本变化。

## 关卡名，显示在 HUD 上。
@export var display_name: String = "未命名关卡"
## 开局出生点，按槽位取。槽位由服务端分配（见 main.gd 的 _allocate_slot）。
@export var spawn_points: PackedVector2Array = PackedVector2Array([Vector2(-768, -70), Vector2(-624, -70)])

## 下面几个数组都在 _ready 里填好，之后只读。顺序由节点树决定，因此
## 各端算出来必然一致——服务端只会广播**下标**（例如"第 2 块冰墙被打掉了"），
## 下标一致是这件事成立的前提。
var hazards: Array[Hazard] = []
var solids: Array[Solid] = []
var checkpoints: Array[Checkpoint] = []
var pickups: Array[ScorePickup] = []
var goal: Goal = null


func _ready() -> void:
	_collect(self)
	# 检查点按序号排序而不是按节点顺序：复活点与序号的关系必须是显式的，
	# "把 3 号检查点插在 1 号前面"不该改变谁离起点更近。
	checkpoints.sort_custom(func(a: Checkpoint, b: Checkpoint) -> bool: return a.index < b.index)
	if checkpoints.is_empty():
		push_error("%s 没有检查点，死亡之后无处复活" % display_name)


func _collect(node: Node) -> void:
	for child in node.get_children():
		if child is Hazard:
			hazards.append(child)
		elif child is Solid:
			solids.append(child)
		elif child is Checkpoint:
			checkpoints.append(child)
		elif child is ScorePickup:
			pickups.append(child)
		elif child is Goal:
			goal = child
		_collect(child)


# ---------------------------------------------------------------- 查询

## 出生点。槽位超出表长时按取模回落，这样加一个人不会因为没配第三个点就生成在原点。
func spawn_point(slot: int) -> Vector2:
	if spawn_points.is_empty():
		return Vector2.ZERO
	return spawn_points[posmod(slot, spawn_points.size())]


## 第 index 号检查点的复活点。越界时夹到两端，不返回原点——
## 返回原点会让"复活在一张空白地图的左上角"，比复活在起点更难查。
func checkpoint_respawn(index: int) -> Vector2:
	if checkpoints.is_empty():
		return spawn_point(0) - Vector2(0.0, Checkpoint.SPAWN_LIFT)
	return checkpoints[clampi(index, 0, checkpoints.size() - 1)].respawn_point()


## 点落在哪个介质区域里。没有则返回 null。
## 一个点同时落在两个区域里是关卡摆错了（池子叠在一起），这里返回先收集到的那个，
## 不报错：报错会让人以为是代码问题，而那其实是场景问题。
func hazard_at(point: Vector2) -> Hazard:
	for hazard in hazards:
		if is_instance_valid(hazard) and hazard.contains_point(point):
			return hazard
	return null


## 点落在哪个检查点的范围内，没有则返回 -1。
## 服务端每个物理帧用它更新"每个 peer 到过的最新检查点"。
func checkpoint_at(point: Vector2) -> int:
	for checkpoint in checkpoints:
		if is_instance_valid(checkpoint) and checkpoint.contains_point(point):
			return checkpoint.index
	return -1


## 取得可用的实心块。打掉的冰墙仍然在数组里（关卡重开要恢复），因此要过滤。
func solid_at_index(index: int) -> Solid:
	if index < 0 or index >= solids.size():
		return null
	var solid := solids[index]
	if not is_instance_valid(solid):
		return null
	return solid


func pickup_at_index(index: int) -> ScorePickup:
	if index < 0 or index >= pickups.size():
		return null
	var pickup := pickups[index]
	if not is_instance_valid(pickup):
		return null
	return pickup
