extends Node
## 会话生命周期测试：加载真正的入口场景，验证"创建房间 → 回到初始界面 → 再创建房间"这条路径。
##
## 运行方式与其它测试不同——**以场景为入口**（tests/session_test.tscn），而不是 `--script`：
##
##   godot --headless --path . res://tests/session_test.tscn -- --port 0
##
## 原因是 `--script` 运行时不注册自动加载单例：`Net` 这类标识符在那里解析不了，
## 于是连 `scripts/main.gd` 都编译不过（实测报 `Compile Error: Identifier not found: Net`）。
## 以场景为入口时才与真正的启动方式走同一条路径，因此这里用一个空场景当入口，
## 由它在 _ready 里手动实例化 scenes/main.tscn。
##
## **必须带 `-- --port 0`**：入口脚本会按项目设置监听默认端口，而开发实例平时占着它，
## 不带就会以"端口被占用"的形式失败。
##
## 这一层单独验证的原因是：回到初始界面之后若不把角色节点清掉，再次创建房间就会出现重复角色，
## 也可能因为旧节点还占着名字而生成失败；而这类问题不报错，只在人眼里表现为"多了一个人"。
## 顺带用真实 UDP 确认主机开始广播。
## 退出码 0 表示全部通过。

const MAIN_SCENE := preload("res://scenes/main.tscn")
const Discovery := preload("res://scripts/net/lan_discovery.gd")

## 自检取值，避开开发时常用的 27015。
const GAME_PORT := 27123
const ROOM_NAME := "会话自检房间"
## 自检用的探测端口。开发时编辑器里运行的实例也停在初始界面、也绑定默认的那个端口，
## 不换端口就会因「无法监听」失败。
## 必须在本测试与入口脚本实例化之前写定：两者都用这个静态变量。
const TEST_DISCOVERY_PORT := 27119
const WAIT_LIMIT := 4.0

const STAGE_LOAD := 0
const STAGE_HOST := 1
const STAGE_ANNOUNCING := 2
const STAGE_REHOST := 3
const STAGE_DONE := 4

var _main: Node = null
var _listener: LanDiscovery = null
var _rooms: Array = []
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _stage: int = STAGE_LOAD
var _stage_elapsed: float = 0.0


func _ready() -> void:
	Discovery.discovery_port = TEST_DISCOVERY_PORT
	_case_cmdline()
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_listener = Discovery.new()
	_listener.rooms_changed.connect(func(listed: Array) -> void: _rooms = listed)
	add_child(_listener)
	# 无头运行时没有人能点界面，入口脚本应当直接以专用服务端开局，并且不打开初始界面。
	_ok(Net.role == Net.Role.SERVER, "无头启动应当直接开局，实际 role=%d" % Net.role)
	_ok(Net.is_dedicated(), "无头启动应当是专用服务端（本机没有玩家角色）")
	_ok(_player_count() == 0, "专用服务端不应当生成角色，实际 %d 个" % _player_count())
	var menu: Node = _main.get("_menu")
	_ok(menu != null and not menu.visible, "无头启动不应当打开初始界面")
	# 入口脚本在启动时读一次 config/product.cfg，因此到这里它应当已经读过。
	# 这条断言把它钉住：以后若有人把那次调用挪走或删掉，界面会静默用兜底值，
	# 而兜底值恰好等于文件里的值，于是不会表现出任何异常。
	#（用 `_exit_tree` 而不是 `_init`，因为 main.gd 的 _start_session 在 _ready 里跑。）
	_ok(ProductConfig.loaded_from_file(),
		"入口脚本启动时应当加载过 config/product.cfg（否则界面会用兜底值）")


func _process(delta: float) -> void:
	_stage_elapsed += delta
	match _stage:
		STAGE_LOAD:
			# 上面那几条断言在 _ready 里已经做完，这里把状态清干净再走界面那条路径。
			_main.call("_return_to_menu", "自检")
			_next_stage(STAGE_HOST)
		STAGE_HOST:
			_case_host()
		STAGE_ANNOUNCING:
			_case_announcing()
		STAGE_REHOST:
			_case_rehost()
		STAGE_DONE:
			_finish()


# ---------------------------------------------------------------- 步骤

## 命令行参数的解析。这部分是纯函数，因此不依赖网络，放在最前面先跑。
## 重点覆盖 `--advertise`：它的取值是跨网联机时唯一能把地址告诉对方的东西，
## 而云服务器上自动探测到的只有 VPC 私网地址（172.16.x.x），对外没有意义。
## 参数漏登记进白名单的现象是"参数没生效"而不是报错（引擎会静默忽略未知参数），
## 所以这里断言的是它确实被解析出来了。
func _case_cmdline() -> void:
	var opts := NetCmdline.parse(PackedStringArray(["--host", "--advertise", "mf.example.com", "--port", "27015"]))
	_ok(bool(opts.get("host", false)), "--host 应当被解析")
	_ok(String(opts.get("advertise", "")) == "mf.example.com", "--advertise 的取值应当被解析，实际「%s」" % opts.get("advertise", ""))
	_ok(int(opts.get("port", 0)) == 27015, "--port 应当被解析")
	# 取值缺失时不应写进结果，否则 main.gd 会拿到一个空地址并据此打印错误提示。
	var missing := NetCmdline.parse(PackedStringArray(["--advertise"]))
	_ok(not missing.has("advertise"), "--advertise 缺少取值时不应被解析")


func _case_host() -> void:	# 回到初始界面这一步在无头下只是结束会话。角色节点走的是延迟释放，因此要下一帧才看不到。
	_ok(Net.role == Net.Role.OFFLINE, "回到初始界面之后应当是未开始会话状态，实际 role=%d" % Net.role)
	_ok(_player_count() == 0, "回到初始界面之后不应当留下角色，实际 %d 个" % _player_count())
	_ok(_listener.listen_for_rooms(), "监听探测端口应当成功")
	# 界面上的"创建房间"最终调用的就是这个方法。
	_main.call("_host_game", ROOM_NAME, GAME_PORT, false)
	_ok(Net.role == Net.Role.SERVER, "创建房间之后应当是主机")
	_ok(not Net.is_dedicated(), "从界面创建的房间应当让本机也是一个玩家")
	_ok(Net.port == GAME_PORT, "主机应当监听指定的端口，实际 %d" % Net.port)
	_next_stage(STAGE_ANNOUNCING)


func _case_announcing() -> void:
	if _rooms.is_empty():
		if _stage_elapsed > WAIT_LIMIT:
			_fail("创建房间之后 %.1f 秒内没有收到本机广播" % WAIT_LIMIT)
			_next_stage(STAGE_REHOST)
		return
	_ok(_rooms.size() == 1, "应当只列出一个房间，实际 %d 个" % _rooms.size())
	var room: Dictionary = _rooms[0]
	_ok(String(room.get("name", "")) == ROOM_NAME, "广播的房间名应当是创建时给的名字，实际「%s」" % room.get("name", ""))
	_ok(int(room.get("port", 0)) == GAME_PORT, "广播的游戏端口应当与监听的端口一致，实际 %d" % room.get("port", 0))
	_ok(int(room.get("players", 0)) == 1, "房间里应当只有主机一个人，实际 %d" % room.get("players", 0))
	_ok(_player_count() == 1, "主机应当生成本机角色，实际 %d 个" % _player_count())
	_main.call("_return_to_menu", "自检")
	_next_stage(STAGE_REHOST)


func _case_rehost() -> void:
	_ok(Net.role == Net.Role.OFFLINE, "离开房间之后应当是未开始会话状态")
	_ok(_player_count() == 0, "离开房间之后不应当留下角色，实际 %d 个" % _player_count())
	# 再开一次：角色节点与广播都清理干净的话，这一次应当与第一次完全一样。
	_main.call("_host_game", ROOM_NAME, GAME_PORT, false)
	_ok(Net.role == Net.Role.SERVER, "再次创建房间应当成功")
	_ok(_player_count() == 1, "再次创建房间应当只有一个本机角色，实际 %d 个" % _player_count())
	_main.call("_return_to_menu", "自检")
	_next_stage(STAGE_DONE)


# ---------------------------------------------------------------- 收尾

func _player_count() -> int:
	var count := 0
	for child in _main.get_node("Players").get_children():
		if child is Player:
			count += 1
	return count


func _next_stage(stage: int) -> void:
	_stage = stage
	_stage_elapsed = 0.0


func _finish() -> void:
	set_process(false)
	_listener.stop()
	if _failures.is_empty():
		print("会话生命周期测试通过（%d 项断言）。" % _checks)
		get_tree().quit(0)
	else:
		print("会话生命周期测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		get_tree().quit(1)


func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _fail(message: String) -> void:
	_failures.append(message)
