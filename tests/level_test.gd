extends SceneTree
## 关卡几何的检查。用 `--script` 直接跑，不联网也不需要显示服务器：
##
##   godot --headless --path . --script tests/level_test.gd
##
## 它验证的是**关卡与判定几何**这一层：介质区的判定范围与池壁、池底的衔接、
## 检查点复活点、出口的判定范围、出生点、冰墙的可融标记、以及元素与介质的致命关系表。
##
## 为什么这一层值得单独测：本作没有"受伤"这一层，判定与美术不一致直接等价于随机暴毙，
## 而这类错误在编辑器里看不出来——地面画在哪、判定算在哪，是两个数字，
## 只有断言才能把它们钉在一起。手玩也很难覆盖"站在池底那一帧算不算在水里"这种边界。
##
## 本文件刻意**不引用 Player**：`--script` 运行模式不注册自动加载单例，
## 而 Player 依赖 Game、Game 依赖 Net，引用一下这条链就编译不过（见 session_test.gd 的说明）。
## 需要角色的尺寸时从 scenes/player.tscn 里读，反而更对——那本来就是被验证的另一个来源。
##
## 退出码 0 表示全部通过，tools/net-smoke.mjs 会把它当作前置检查之一。

const LEVEL_SCENE := preload("res://scenes/levels/level_01.tscn")
const PLAYER_SCENE_PATH := "res://scenes/player.tscn"

## 角色能爬上的最大高度（px）。跳跃高度解析值 160、实测约 170（见 player.gd 里 gravity 的说明），
## 这里取实测值再留一成余量当上限。池子比它更深就意味着"掉进去的人出不来"——
## 熔本来就该能在岩浆里走，但它得走得出去。
const MAX_CLIMB := 150.0

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _half_height: float = -1.0


func _process(_delta: float) -> bool:
	var level := LEVEL_SCENE.instantiate() as Level
	root.add_child(level)
	_half_height = _read_player_half_height()

	_case_components(level)
	_case_player_size()
	_case_hazards(level)
	_case_hazard_bounds(level)
	_case_checkpoints(level)
	_case_goal(level)
	_case_elements()
	_finish()
	return true


# ---------------------------------------------------------------- 组件收集

func _case_components(level: Level) -> void:
	_ok(level.hazards.size() == 2, "应当有岩浆与水两个介质区，实际 %d" % level.hazards.size())
	_ok(level.goal != null, "应当有一个出口")
	_ok(level.checkpoints.size() == 3, "应当有三个检查点（起点、岩浆之后、水之后），实际 %d" % level.checkpoints.size())
	_ok(level.pickups.size() == 1, "应当有一个积分点，实际 %d" % level.pickups.size())
	_ok(level.spawn_points.size() == 2, "应当有两个出生点，实际 %d" % level.spawn_points.size())
	# 检查点按序号排好，且序号连续从 0 开始——复活位置是按序号索引的，
	# 序号跳号会让"到过 2 号的人复活在 1 号"。
	var indexes := PackedInt32Array()
	for c in level.checkpoints:
		indexes.append(c.index)
	_ok(indexes == PackedInt32Array([0, 1, 2]), "检查点序号应当从 0 连续排到 2，实际 %s" % str(indexes))

	var meltable := 0
	for solid in level.solids:
		if solid.meltable:
			meltable += 1
	_ok(meltable == 1, "应当恰好有一面可融的冰墙，实际 %d" % meltable)


## 角色的碰撞箱半高必须等于检查点的复活抬升。两者对不上时，复活的表现是
## "半截身子埋在地里"或者"从空中掉一下"，而且改一次角色尺寸就会悄悄发生。
func _case_player_size() -> void:
	_ok(_half_height > 0.0, "应当能从 %s 里读出角色的碰撞箱尺寸" % PLAYER_SCENE_PATH)
	if _half_height <= 0.0:
		return
	_ok(is_equal_approx(_half_height, Checkpoint.SPAWN_LIFT),
		"角色半高应当等于检查点的复活抬升：场景里是 %.0f，检查点用 %.0f" % [_half_height, Checkpoint.SPAWN_LIFT])


# ---------------------------------------------------------------- 介质判定

func _case_hazards(level: Level) -> void:
	var lava := level.hazards[0]
	var water := level.hazards[1]
	_ok(lava.medium == Element.Medium.LAVA, "第一个介质区应当是岩浆")
	_ok(water.medium == Element.Medium.WATER, "第二个介质区应当是水")

	# 池底：脚踩在池底上时必须算在介质里。取池底正上方一点。
	var lava_floor := Vector2(lava.global_position.x + lava.size.x * 0.5, lava.global_position.y + lava.size.y - 2.0)
	_ok(lava.contains_point(lava_floor), "站在岩浆池底的脚点必须算在岩浆里（否则霜掉进去不会死）")
	# 液面之上一点：不算在内。站在浮冰上的角色就靠这一条活下来。
	_ok(not lava.contains_point(Vector2(lava_floor.x, lava.global_position.y - 16.0)),
		"液面之上的点不能算在介质里（否则站在浮冰上会立刻暴毙）")
	# 池子左右两侧岸上的地面点：不算在内。放宽左右边界会把站在岸边的人判成落水。
	_ok(not lava.contains_point(Vector2(lava.global_position.x - 24.0, lava.global_position.y)),
		"岩浆池左侧岸上的脚点不能算在岩浆里")
	_ok(not water.contains_point(Vector2(water.global_position.x + water.size.x + 24.0, water.global_position.y)),
		"水池右侧岸上的脚点不能算在水里")
	# 站在池沿（中心点正好压在池壁上）也不能算在内：那是画面上"明明还站在岸上"的位置。
	_ok(not lava.contains_point(lava.global_position),
		"中心点压在池壁上的角色不能算落水")

	# 两个池子互不重叠：重叠时一个点会命中两个介质，规则说不清。
	_ok(not lava.contains_point(water.global_position), "两个介质区不应重叠")
	# 池子上方较高处（远超跳跃高度）不算在内。
	_ok(not lava.contains_point(lava_floor + Vector2(0.0, -256.0)), "高空中的点不能算在介质里")


## 介质区与它两侧的地面、以及池底的关系。四条都要满足，缺一条就是一个能掉出去或爬不上来的洞：
##   左右两沿必须**紧接**一块同高的地面（有缝会掉下去，有台阶会说不清为什么跳不上去）；
##   池底必须恰好铺在介质区的下沿（介质悬空或穿过地面都是画错）；
##   深度不能超过角色能爬上的高度（熔要在岩浆里走，它得走得出去）。
func _case_hazard_bounds(level: Level) -> void:
	for hazard in level.hazards:
		var label := Element.medium_name(hazard.medium)
		var top := hazard.global_position.y
		var left := hazard.global_position.x
		var right := left + hazard.size.x
		var floor_y := top + hazard.size.y
		_ok(_has_ground_edge(level, left, true, top),
			"介质区「%s」左沿应当紧接一块同高的地面" % label)
		_ok(_has_ground_edge(level, right, false, top),
			"介质区「%s」右沿应当紧接一块同高的地面" % label)
		_ok(_has_floor(level, left, right, floor_y),
			"介质区「%s」下方应当铺满池底（下沿 y=%.0f）" % [label, floor_y])
		_ok(hazard.size.y <= MAX_CLIMB,
			"介质区「%s」深 %.0f px，超过角色能爬上的 %.0f px，掉进去就出不来" % [label, hazard.size.y, MAX_CLIMB])


## 有没有一块实心几何以 x 为边缘（want_right 表示要它的右边缘），并且顶面就在 ground_y 上。
func _has_ground_edge(level: Level, x: float, want_right: bool, ground_y: float) -> bool:
	for solid in level.solids:
		if solid.meltable:
			continue
		var rect := Rect2(solid.global_position, solid.size)
		var edge := rect.position.x + rect.size.x if want_right else rect.position.x
		if absf(edge - x) <= 1.0 and absf(rect.position.y - ground_y) <= 1.0:
			return true
	return false


## 有没有一块实心几何的顶面恰好铺在 floor_y 上，并且横向盖住 [left, right]。
func _has_floor(level: Level, left: float, right: float, floor_y: float) -> bool:
	for solid in level.solids:
		if solid.meltable:
			continue
		var rect := Rect2(solid.global_position, solid.size)
		if absf(rect.position.y - floor_y) > 1.0:
			continue
		if rect.position.x <= left + 1.0 and rect.position.x + rect.size.x >= right - 1.0:
			return true
	return false


# ---------------------------------------------------------------- 检查点与出口

func _case_checkpoints(level: Level) -> void:
	for checkpoint in level.checkpoints:
		var ground := checkpoint.global_position
		var respawn := level.checkpoint_respawn(checkpoint.index)
		_ok(respawn.y < ground.y, "检查点 %d 的复活点应当在地面之上" % checkpoint.index)
		_ok(is_equal_approx(respawn.y, ground.y - Checkpoint.SPAWN_LIFT),
			"检查点 %d 的复活抬升应当等于角色半高，实际 %.1f" % [checkpoint.index, ground.y - respawn.y])
		# 站着不动的角色（中心在脚点上方一个半高）必须落在触发范围内。
		_ok(checkpoint.contains_point(ground + Vector2(0.0, -_half_height)),
			"检查点 %d 应当能触发站在它上面的角色" % checkpoint.index)
		# 复活点下方必须有地面，否则复活之后会直接往下掉。
		_ok(_has_floor(level, respawn.x - 1.0, respawn.x + 1.0, ground.y),
			"检查点 %d 下方应当有地面接住复活的人" % checkpoint.index)

	# 越界取值必须夹到两端，而不是返回原点——返回原点会让人复活在空白处。
	_ok(level.checkpoint_respawn(-5).is_equal_approx(level.checkpoint_respawn(0)), "检查点序号过小时应当夹到起点")
	_ok(level.checkpoint_respawn(99).is_equal_approx(level.checkpoint_respawn(2)), "检查点序号过大时应当夹到最后一个")

	# 两个出生点不能重叠（角色宽 48），且要在同一高度。
	var a := level.spawn_point(0)
	var b := level.spawn_point(1)
	_ok(absf(a.x - b.x) >= 48.0, "两个出生点不能重叠，实际间距 %.0f px" % absf(a.x - b.x))
	_ok(absf(a.y - b.y) < 1.0, "两个出生点应当在同一高度")
	# 出生点下方要有一小段之内的地面。出生点是刻意悬在地面上方一点点的
	#（否则第一帧就与地面重叠，会被推出来，那一下会混进网络平滑的位移统计里），
	# 因此判据是"往下不远处有地面"，不是"脚下就是地面"。
	for slot in level.spawn_points.size():
		var at := level.spawn_point(slot)
		_ok(_ground_within(level, at.x, at.y + _half_height, 64.0),
			"出生点 %d 下方 64 px 内应当有地面，否则开局会一直往下掉" % slot)


## 从 from_y 往下 max_drop 之内，x 处有没有一块地面。
func _ground_within(level: Level, x: float, from_y: float, max_drop: float) -> bool:
	for solid in level.solids:
		if solid.meltable:
			continue
		var rect := Rect2(solid.global_position, solid.size)
		if x < rect.position.x - 1.0 or x > rect.position.x + rect.size.x + 1.0:
			continue
		if rect.position.y >= from_y - 1.0 and rect.position.y <= from_y + max_drop:
			return true
	return false


func _case_goal(level: Level) -> void:
	# 站着不动的角色中心必须落在出口范围内。
	var standing := Vector2(level.goal.global_position.x + level.goal.size.x * 0.5,
		level.goal.global_position.y + _half_height)
	_ok(level.goal.contains_point(standing), "站在出口里的角色必须被判定为到达")
	_ok(not level.goal.contains_point(standing + Vector2(0.0, -300.0)), "出口上方的点不能算作到达")
	_ok(not level.goal.contains_point(level.goal.global_position + Vector2(-200.0, 0.0)), "出口左侧远处不能算作到达")
	# 出口下方要有地面。出口是个区域，人走进去应该站在地上，而不是掉进去再落下来。
	_ok(_has_floor(level, level.goal.global_position.x, level.goal.global_position.x + level.goal.size.x,
		level.goal.global_position.y + level.goal.size.y),
		"出口下方应当有地面")


# ---------------------------------------------------------------- 元素表

func _case_elements() -> void:
	_ok(Element.is_lethal(Element.Kind.MOLTEN, Element.Medium.WATER), "熔遇水应当致命")
	_ok(not Element.is_lethal(Element.Kind.MOLTEN, Element.Medium.LAVA), "熔在岩浆里应当能走")
	_ok(Element.is_lethal(Element.Kind.FROST, Element.Medium.LAVA), "霜遇岩浆应当致命")
	_ok(not Element.is_lethal(Element.Kind.FROST, Element.Medium.WATER), "霜在水里应当能走")
	_ok(Element.other(Element.Kind.MOLTEN) == Element.Kind.FROST, "熔的另一面是霜")
	_ok(Element.other(Element.Kind.FROST) == Element.Kind.MOLTEN, "霜的另一面是熔")
	_ok(Element.melts(Element.Kind.MOLTEN), "只有熔能融冰")
	_ok(not Element.melts(Element.Kind.FROST), "霜不能融冰")
	_ok(Element.parse("frost") == Element.Kind.FROST, "--element frost 应当解析为霜")
	_ok(Element.parse("熔") == Element.Kind.MOLTEN, "--element 熔 应当解析为熔")
	_ok(Element.parse("不是元素") == -1, "认不出来的元素名应当返回 -1 由调用方决定回退")


# ---------------------------------------------------------------- 读取玩家尺寸

## 从玩家场景的文本里取碰撞箱半高。见文件头：不能引用 Player，否则整条依赖链编译不过。
func _read_player_half_height() -> float:
	var file := FileAccess.open(PLAYER_SCENE_PATH, FileAccess.READ)
	if file == null:
		return -1.0
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if not line.begins_with("size = Vector2("):
			continue
		var open := line.find("(")
		var close := line.find(")")
		if open < 0 or close < 0:
			continue
		var parts := line.substr(open + 1, close - open - 1).split(",")
		if parts.size() != 2:
			continue
		return float(parts[1].strip_edges()) * 0.5
	return -1.0


# ---------------------------------------------------------------- 收尾

func _finish() -> void:
	if _failures.is_empty():
		print("关卡几何测试通过（%d 项断言）。" % _checks)
		quit(0)
	else:
		print("关卡几何测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		quit(1)


func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
