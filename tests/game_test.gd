extends Node
## 关卡玩法规则测试：以场景为入口（tests/game_test.tscn），加载真正的入口场景，
## 在服务端这一侧把一关的规则跑一遍。
##
##   godot --headless --path . res://tests/game_test.tscn
##
## 为什么要以场景为入口、而不是 `--script`：`--script` 运行时不注册自动加载单例，
## `Net` 这类标识符在那里解析不了，于是连 scripts/main.gd 都编译不过（见 session_test.gd 的说明）。
##
## 覆盖的是**规则之间的连接**，也就是手点很难逐个走一遍、但一旦断了就整关卡住的东西：
##   元素分配与交换（两人对调 / 单人取反）、
##   致命介质 → 死亡 → 按检查点复活、
##   霜造冰的位置（浮在水面而不是沉到池底）、熔融冰墙、
##   积分只在服务端结算一次、
##   两人同时站进出口才算通关、
##   关卡重开把冰墙恢复、把角色放回出生点，而**已拾取的积分不返还**。
##
## 这些断言都跑在同一台机器上的一局里（本机是服务端也是玩家，另有一个人造的远端角色），
## 因此它验证不了"两台机器看见的是不是同一张图"——那件事只能靠 tools/net-smoke.mjs
## 的双实例检查加上真人试玩。它验证的是"服务端那份规则本身自洽"。
##
## 退出码 0 表示全部通过。

const MAIN_SCENE := preload("res://scenes/main.tscn")
const Discovery := preload("res://scripts/net/lan_discovery.gd")

## 自检取值，避开开发时常用的 27015。
const GAME_PORT := 27131
## 自检用的探测端口。开发时编辑器里运行的实例也停在初始界面、也绑定默认的那一个，
## 不换端口就会因「无法监听」失败。
const TEST_DISCOVERY_PORT := 27119
const ROOM_NAME := "玩法自检房间"
## 造出来的远端角色的 peer id。取一个不可能与真实连接撞上的小数字即可。
const REMOTE_PEER := 762

## 与 Game 里的常量对应。这里刻意重复一份：测试要等的是"足够长"，
## 而不是某个精确值——写成引用会在有人调短延时之后变成"等得比实际短"，
## 于是测试开始偶发失败，而且看不出是为什么。
const SKILL_WAIT := 0.9
const RESPAWN_WAIT := 1.6

var _main: Node = null
var _game: Game = null
var _level: Level = null
var _players: Node2D = null
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0


func _ready() -> void:
	Discovery.discovery_port = TEST_DISCOVERY_PORT
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_game = _main.get_node("Game") as Game
	_level = _game.level
	_players = _main.get_node("Players")
	await _run()
	_finish()


func _run() -> void:
	# 无头启动会直接以专用服务端开局，先把那一局结束掉，再按"主机也是玩家"重开一局。
	_main.call("_return_to_menu", "自检")
	_main.call("_host_game", ROOM_NAME, GAME_PORT, false)
	await _steps(3)
	await _case_basics()
	await _case_ice()
	await _case_wall()
	await _case_death()
	await _case_pickup()
	await _case_goal()
	await _case_restart()


# ---------------------------------------------------------------- 元素与交换

func _case_basics() -> void:
	_ok(_level != null, "入口场景应当载入一关")
	if _level == null:
		return
	_ok(_player_count() == 1, "主机会生成自己的角色，实际 %d 个" % _player_count())
	var me := _player(1)
	_ok(me != null, "本机角色应当是 peer 1")
	if me == null:
		return
	_ok(me.element == Element.Kind.MOLTEN, "0 号槽位应当是熔")
	_ok(me.is_local(), "本机角色应当被认成自己的")
	_ok(me.spawn_slot == 0, "本机角色应当在 0 号槽位，实际 %d" % me.spawn_slot)
	var spawn := _level.spawn_point(0)
	_ok(me.global_position.distance_to(spawn) < 8.0,
		"本机角色应当出生在关卡的出生点上，实际 %s / 期望 %s" % [me.global_position, spawn])

	# 造一个远端角色，凑出两人一局。走的是与真实连接相同的生成路径。
	_main.call("_on_peer_connected", REMOTE_PEER)
	await _steps(3)
	_ok(_player_count() == 2, "应当有两个人，实际 %d" % _player_count())
	var mate := _player(REMOTE_PEER)
	_ok(mate != null, "远端角色应当被生成")
	if mate == null:
		return
	_ok(mate.element == Element.Kind.FROST, "1 号槽位应当是霜")
	_ok(not mate.is_local(), "远端角色不应当被认成自己的")
	_ok(absf(mate.global_position.x - me.global_position.x) >= 48.0, "两个角色的出生点不能重叠")

	# 交换角色：两人时是对调。两人同时按下即回到原状这条性质，靠的就是服务端串行处理，
	# 因此"连续两次交换等于没换"要有断言钉住。
	_game.request_swap(1)
	await _steps(2)
	_ok(me.element == Element.Kind.FROST, "交换之后本机角色应当变成霜，实际 %s" % Element.kind_name(me.element))
	_ok(mate.element == Element.Kind.MOLTEN, "交换之后远端角色应当变成熔，实际 %s" % Element.kind_name(mate.element))
	_game.request_swap(1)
	await _steps(2)
	_ok(me.element == Element.Kind.MOLTEN, "再交换一次应当回到原状")
	_ok(mate.element == Element.Kind.FROST, "再交换一次远端也应当回到原状")


# ---------------------------------------------------------------- 造冰

## 霜站在水里造冰，冰应当浮在水面上（底面接近液面），而不是沉到池底。
## 这条是关卡能否通过的关键：熔要踩着它过水池，而熔一旦碰到水就死。
func _case_ice() -> void:
	var me := _player(1)
	var water := _level.hazards[1]
	_ok(water.medium == Element.Medium.WATER, "第二个介质区应当是水")

	# 先把自己变成霜。
	_game.request_swap(1)
	await _steps(2)
	_ok(me.element == Element.Kind.FROST, "本机角色应当是霜才能造冰")

	# 把人放进水中央：液面在 water.global_position.y，池底在液面下一个介质区高度。
	var mid_x := water.global_position.x + water.size.x * 0.5
	_put(me, Vector2(mid_x, water.global_position.y + water.size.y - Player.HALF_HEIGHT))
	await _steps(6)
	_ok(_water_hazard_at(me.feet()) != null, "人被放到水里之后，脚点应当落在水的判定范围内")

	_game.use_skill(me)
	await _wait(SKILL_WAIT)

	var ice := _ice_blocks()
	_ok(ice.size() == 1, "霜在水里施放技能应当造出一块冰，实际 %d 块" % ice.size())
	if ice.is_empty():
		return
	var block := ice[0]
	var expected_top := water.global_position.y - Game.ICE_FLOAT_FREEBOARD
	var actual_top := block.global_position.y - IceBlock.SIZE.y * 0.5
	_ok(absf(actual_top - expected_top) <= 2.0,
		"冰应当浮在水面上（顶面 y≈%.0f），实际顶面 y=%.0f" % [expected_top, actual_top])
	_ok(absf(block.global_position.x - mid_x) <= 2.0, "冰应当造在施放者的正下方")

	# 重复施放要能造出第二块（无冷却），但同一个位置不能叠出两块。
	_game.use_skill(me)
	await _wait(SKILL_WAIT)
	_ok(_ice_blocks().size() == 1, "同一个位置重复施放不应当叠出第二块冰")


# ---------------------------------------------------------------- 融冰墙

## 熔站在冰墙边上施放技能，冰墙应当被打掉。这是熔在关卡里唯一的解法性用途。
func _case_wall() -> void:
	var me := _player(1)
	var wall := _meltable_wall()
	_ok(wall != null, "关卡里应当有一面可融的冰墙")
	if wall == null:
		return
	_ok(not wall.is_broken(), "开局冰墙应当是完好的")

	# 先离开水面再换元素。上一段把角色留在了水池里，而换到熔的那一刻水就变致命了——
	# 这不是 bug，正是机制与玩法设计 2.6 第 35 条（切换身份没有任何保护），
	# 但在这里它会把角色直接弄死，于是后面的施放全都不会发生。
	_put(me, Vector2(wall.global_position.x - 48.0, -Player.HALF_HEIGHT))
	await _steps(4)
	_game.request_swap(1)
	await _steps(2)
	_ok(me.element == Element.Kind.MOLTEN, "本机角色应当是熔才能融冰")
	_ok(not me.is_dead(), "站在地面上换元素不应当把人弄死")
	await _steps(4)

	_game.use_skill(me)
	# 技能是**延迟生效**的（机制与玩法设计 2.2），因此刚按下时墙还在。
	_ok(not wall.is_broken(), "技能按下之后不应当立刻生效，延迟是核心机制")
	await _wait(SKILL_WAIT)
	_ok(wall.is_broken(), "熔在冰墙旁边施放之后，冰墙应当被打掉")


# ---------------------------------------------------------------- 死亡与复活

func _case_death() -> void:
	var me := _player(1)
	# 变成霜，丢进岩浆。
	_game.request_swap(1)
	await _steps(2)
	_ok(me.element == Element.Kind.FROST, "本机角色应当是霜")
	var lava := _level.hazards[0]
	_put(me, Vector2(lava.global_position.x + lava.size.x * 0.5, lava.global_position.y + lava.size.y - Player.HALF_HEIGHT))
	await _steps(6)
	_ok(me.is_dead(), "霜落进岩浆应当死亡")

	# 复活点取最近到过的检查点。本机角色全程没有离开过 0 号检查点的范围之外，
	# 因此应当在起点复活。
	await _wait(RESPAWN_WAIT)
	_ok(not me.is_dead(), "等够时间之后应当复活")
	var expected := _level.checkpoint_respawn(0)
	_ok(me.global_position.distance_to(expected) < 8.0,
		"复活点应当是 0 号检查点，实际 %s / 期望 %s" % [me.global_position, expected])
	_ok(not me.is_dead() and me.global_position.y < 0.0, "复活之后应当站在地面之上")


# ---------------------------------------------------------------- 积分

func _case_pickup() -> void:
	var me := _player(1)
	var pickup := _level.pickups[0]
	var before := _game.score()
	_put(me, pickup.global_position)
	await _steps(6)
	_ok(_game.score() == before + pickup.value,
		"站到积分点上应当得分 %d，实际变化 %d" % [pickup.value, _game.score() - before])
	_ok(pickup.visible == false, "拿到之后的积分点应当从画面上消失")

	# 服务端每个物理帧都会重新检查一遍未拾取的点，因此"只结算一次"要靠拾取记录保证。
	await _steps(10)
	_ok(_game.score() == before + pickup.value, "同一个积分点不应当被结算两次")


# ---------------------------------------------------------------- 通关

func _case_goal() -> void:
	var me := _player(1)
	var mate := _player(REMOTE_PEER)
	_ok(not _game.is_completed(), "还没到出口时不算通关")

	# 只有一个人先进去不算通关：出口是两个人一起站进去。
	_put(me, _goal_center())
	await _steps(6)
	_ok(not _game.is_completed(), "只有一个人站在出口里不算通关")

	_put(mate, _goal_center())
	await _steps(6)
	_ok(_game.is_completed(), "两人都站在出口里应当通关")
	var score_after := _game.score()
	await _steps(10)
	_ok(_game.score() == score_after, "通关奖励只应当结算一次")


# ---------------------------------------------------------------- 重开

## 关卡重开要恢复的是**世界**（冰墙、地上的冰、位置），不恢复的是**积分**：
## 积分属于账号（设计文档 6.2），让它随重开复活就等于给了一个刷分按钮。
func _case_restart() -> void:
	var me := _player(1)
	var pickup := _level.pickups[0]
	var wall := _meltable_wall()
	var score_before := _game.score()

	_game.request_restart()
	await _steps(6)

	_ok(not _game.is_completed(), "重开之后不应当还停在通关状态")
	_ok(wall != null and not wall.is_broken(), "重开之后冰墙应当恢复")
	_ok(_ice_blocks().is_empty(), "重开之后场上的冰应当清空")
	_ok(pickup.visible == false, "重开之后已拾取的积分点不应当重新出现")
	_ok(_game.score() == score_before, "重开不应当返还或扣除积分")
	# 位置按"站定的位置"断言，而不是出生点本身：出生点在关卡里是脚踩地面的那个点，
	# 角色的节点原点是中心，两者差半个身高。比较前先让物理把人放稳。
	await _wait(0.5)
	var settled := _level.checkpoint_respawn(me.spawn_slot)
	_ok(me.global_position.distance_to(settled) < 12.0,
		"重开之后应当回到起点，实际 %s / 期望约 %s" % [me.global_position, settled])


# ---------------------------------------------------------------- 工具

func _player(peer_id: int) -> Player:
	for child in _players.get_children():
		var player := child as Player
		if player != null and player.peer_id == peer_id:
			return player
	return null


func _player_count() -> int:
	var count := 0
	for child in _players.get_children():
		if child is Player:
			count += 1
	return count


func _ice_blocks() -> Array[IceBlock]:
	var out: Array[IceBlock] = []
	for child in _main.get_node("World").get_children():
		if child is IceBlock:
			out.append(child)
	return out


func _meltable_wall() -> Solid:
	for solid in _level.solids:
		if solid.meltable:
			return solid
	return null


## 出口范围内、站在地面上时角色中心所在的位置。
## 出口矩形的下沿就是地面顶面，因此中心在它上方一个半高处。
func _goal_center() -> Vector2:
	return Vector2(_level.goal.global_position.x + _level.goal.size.x * 0.5,
		_level.goal.global_position.y + _level.goal.size.y - Player.HALF_HEIGHT)


## 直接摆放角色的位置。对**本机**角色来说这是在写它自己的权威位置；
## 对远端角色来说，服务端本来就不是它的权威，但这一局里没有真的客户端在跑，
## 因此不会有人把它改回去。检查点、积分与通关都读服务端的这一份位置。
func _put(player: Player, at: Vector2) -> void:
	player.global_position = at
	player.velocity = Vector2.ZERO


func _water_hazard_at(point: Vector2) -> Hazard:
	for hazard in _level.hazards:
		if hazard.medium == Element.Medium.WATER and hazard.contains_point(point):
			return hazard
	return null


func _steps(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


# ---------------------------------------------------------------- 收尾

func _finish() -> void:
	Net.close()
	if _failures.is_empty():
		print("关卡玩法测试通过（%d 项断言）。" % _checks)
		get_tree().quit(0)
	else:
		print("关卡玩法测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		get_tree().quit(1)


func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
