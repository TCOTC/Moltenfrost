extends Node
## 晚加入的状态补齐测试。以场景为入口（tests/late_join_test.tscn），两个进程各跑一个阶段：
##
##   godot --headless --path . res://tests/late_join_test.tscn -- --phase host --port 0 --target-port 27133
##   godot --headless --path . res://tests/late_join_test.tscn -- --phase join --port 0 --target-port 27133
##
## 覆盖的是**晚于世界变化才连上来的那个 peer 能不能拿到一份一致的世界**。
##
## 为什么这一项单独存在：打掉冰墙、拾取积分、通关都只通过一次性 RPC 通知**当时在场**的 peer。
## 一旦有人在那之后才加入，他就拿着一份与房主不一致的世界——而这件事
## **不报任何错**，也不会在任何单进程测试里出现。实际遇到过：房主先熔掉了关卡里的冰墙，
## 同伴后加入，于是同伴那边还立着一面墙、房主却径直走了过去。修法见 Game.catch_up。
##
## 时序上有一点必须保证，否则测试会假通过：**主机必须在客户端连上之前就改掉世界**。
## 因此 net-smoke 会等主机打出那一行之后才启动客户端。
##
## 需要带 `-- --port 0 --target-port <N>`：
##   `--port 0` 让入口脚本先占一个系统分配的空闲端口——`--headless` 启动会先按项目设置
##   开一个专用服务端，这一步得先把它弄开否则它会去绑 27015，而开发实例平时占着那个口。
##   端口本身用 `--target-port` 传：它不在 NetCmdline 的白名单里，因此不会被入口脚本拿去绑定，
##   否则客户端会去抢主机占着的那一个端口（实测就是这个报错）。
const MAIN_SCENE := preload("res://scenes/main.tscn")

## 冰墙的判定位置。墙在 x∈[640,704]、y∈[-192,0]，取它中间。
const WALL_PROBE := Vector2(672.0, -96.0)
## 制造出来的两项状态。数值本身不重要，重要的是它们必须经快照回到客户端。
const PICKUP_VALUE := 50
const COMPLETE_BONUS := 200
## 等对方连上来（host）与等快照（join）的上限。
const WAIT_LIMIT := 12.0

var _phase: String = "host"
var _port: int = 27133
var _main: Node = null
var _game: Game = null
var _level: Level = null
var _elapsed: float = 0.0
var _world_changed: bool = false
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _finished: bool = false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--phase" and i + 1 < args.size():
			_phase = args[i + 1]
		elif args[i] == "--target-port" and i + 1 < args.size():
			_port = int(args[i + 1])
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_game = _main.get_node("Game") as Game
	_level = _game.level
	# 无头启动会先按项目设置开一个专用服务端（本机没有玩家角色），这里把它关掉。
	_main.call("_return_to_menu", "自检")
	if _phase == "host":
		_main.call("_host_game", "晚加入自检", _port, true)
		print("[late] 主机已就绪，端口 %d" % _port)
	else:
		_main.call("_begin_join", "127.0.0.1", _port)


func _process(delta: float) -> void:
	if _finished:
		return
	_elapsed += delta
	if _phase == "host":
		_host_tick()
	else:
		_join_tick()


# ---------------------------------------------------------------- 主机：在没人旁观的时候改掉世界

func _host_tick() -> void:
	if _world_changed or _elapsed < 1.0:
		if _elapsed > WAIT_LIMIT + 20.0:
			# 对方一直没连上时也要能退出，不把 net-smoke 挂死。失败会在 join 阶段报出来。
			_finished = true
			get_tree().quit(0)
		return
	_world_changed = true
	# 三件事都走 Game 里真正的那段逻辑，而不是直接改状态。
	_game.call("_break_walls", WALL_PROBE)
	_game.call("_broadcast_pickup", 0, PICKUP_VALUE)
	_game.call("_apply_completed", COMPLETE_BONUS)
	print("[late] 主机已在无人旁观时改掉世界：冰墙打掉、积分 %d、通关" % _game.score())


# ---------------------------------------------------------------- 客户端：核对拿到的世界

func _join_tick() -> void:
	if not Net.is_connected_to_server():
		if _elapsed > WAIT_LIMIT:
			_fail("连不上主机")
			_finish()
		return
	# 等到状态真的补齐再断言，不靠固定睡眠：机器一忙固定睡眠就会假失败。
	# 判据取"分数变了"——客户端自己不会加分，因此它只可能来自快照。
	# 快照万一没来，这里会一直等到超时、然后照常断言失败，所以不会假通过。
	if _game.score() == 0 and _elapsed < WAIT_LIMIT:
		return
	_check_world()
	_finish()


func _check_world() -> void:
	var wall := _meltable_wall()
	_ok(wall != null, "应当能拿到那面可融的冰墙")
	if wall != null:
		_ok(wall.is_broken(), "晚加入时冰墙应当是已打掉的状态（否则客户端会立着一面服务端不认的墙）")
		_ok(not wall.visible, "已打掉的冰墙不应当还画着")
	var pickup := _level.pickups[0]
	_ok(not pickup.visible, "晚加入时已经被拿掉的积分点不应当还亮着")
	# 分数要按快照整体对齐，而不是靠客户端把每个积分点再累加一遍——
	# 后者在晚加入时根本收不到那几次广播。
	_ok(_game.score() == PICKUP_VALUE + COMPLETE_BONUS,
		"晚加入时分数应当是 %d，实际 %d" % [PICKUP_VALUE + COMPLETE_BONUS, _game.score()])
	_ok(_game.is_completed(), "晚加入时关卡的通关状态应当一并补齐")
	_ok(_local_player() != null, "客户端应当有自己的角色")
	# 冰块由 MultiplayerSpawner 补给新 peer、不走快照，因此单独把数量打出来：
	# 以后出问题时一眼能看出是"没补上"还是"补上了但位置不对"。
	print("[late] 客户端拿到的冰块数=%d" % _ice_count())


# ---------------------------------------------------------------- 工具

func _meltable_wall() -> Solid:
	for solid in _level.solids:
		if solid.meltable:
			return solid
	return null


func _ice_count() -> int:
	var count := 0
	for child in _main.get_node("World").get_children():
		if child is IceBlock:
			count += 1
	return count


func _local_player() -> Player:
	for child in _main.get_node("Players").get_children():
		var player := child as Player
		if player != null and player.is_local():
			return player
	return null


func _finish() -> void:
	_finished = true
	Net.close()
	if _failures.is_empty():
		print("晚加入状态补齐测试通过（%d 项断言）。" % _checks)
		get_tree().quit(0)
	else:
		print("晚加入状态补齐测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		get_tree().quit(1)


func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _fail(message: String) -> void:
	_failures.append(message)
