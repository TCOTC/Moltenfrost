extends Node2D
## 工程入口：决定本机在本次会话里的角色，并把状态显示在 HUD 上。
##
## 角色判定（参数解析见 scripts/net/net_cmdline.gd）：
##   `--join <地址>`   连接到远端权威节点
##   `--host`          本机开始监听，并且本机也是玩家（listen server）
##   无参数、有画面     显示初始界面（scripts/menu.gd），由玩家选房间或创建房间
##   无参数、无画面     当专用服务端，本机不生成玩家角色
## 也就是说：有画面时启动会停在初始界面上，而无头启动没有人能点界面，只能直接开服务端。
## 界面上的"创建房间"与命令行的 `--host` 是同一段代码，因此自动检查覆盖到的路径
## 与真人玩到的路径一致。
##
## 初始界面里的"创建房间"就是在本机启动服务端，同时把房间广播到局域网，
## 另一台机器停在界面上就能在列表里看到它（机制见 scripts/net/lan_discovery.gd）。
## 对局中按 Esc 回到初始界面：客户端等于离开房间，主机等于关掉房间。
##
## 关于开发期窗口化：project.godot 里写了 window/size/mode=3（全屏）与
## window/size/mode.editor=0（窗口）。后者是特性标签覆盖，只在用编辑器程序运行的时候
## 生效——编辑器的「游戏嵌入」需要窗口模式，而导出产物的二进制不带 editor 特性，
## 取到的仍是全屏。所以下面用 get_setting_with_override 取值，让实际窗口状态跟上它。
## 注意：project.godot 里的注释在编辑器保存工程时会被删掉，说明写在这里。

const MODE_SETTING := "display/window/size/mode"
const PLAYER_SCENE := preload("res://scenes/player.tscn")
const MENU_SCENE := preload("res://scenes/menu.tscn")
const LOBBY_SCENE := preload("res://scenes/lobby.tscn")
## 生成位置沿地面横向等距错开。槽位由服务端分配，因此不会出现两人重叠在同一个点。
## 关卡自己有 spawn_points 时以它为准（正常情况一律如此），这几个常量只是
## 关卡还没载入时的兜底——那种情况只可能出现在单独启动 scenes/main.tscn 调试的时候。
const SPAWN_SLOTS := 6
const SPAWN_SPACING := 96.0
## 出生高度。关卡的出生点是"角色中心应当出现的那个点"（离地 48 px 的半高再留一点余量），
## 兜底值同理：让角色开局位于地面上方，自然落下，而不是与地面重叠后被推出来
##（那会在第一帧产生一次假的位移尖峰，混进平滑诊断里）。
const SPAWN_HEIGHT := -70.0
## --net-stats 的输出间隔。
const STATS_INTERVAL := 2.0
## --element 的临时覆盖，只作用于第一个槽位。单机试关时用它决定自己玩哪个元素；
## 不传时按槽位交替分配（0 号熔、1 号霜），与设计文档「两人一熔一霜」的默认一致。
var _element_override: int = -1

## sentinel 的检查间隔（秒）。
## 不做每帧检查：它是一次文件系统 stat，而这里要的只是"一两百毫秒内响应"——
## 每帧查一次换来的是无谓的系统调用（无头服务端会跑满帧率）。
const STOP_FILE_INTERVAL := 0.2

@onready var _players: Node2D = $Players
@onready var _spawner: MultiplayerSpawner = $Players/Spawner
@onready var _hud: GameHud = $HUD
@onready var _status: Label = $HUD/Root/Status
@onready var _game: Game = $Game
@onready var _menu_camera: Camera2D = $MenuCamera

## 初始界面与房间广播器。两者分开：创建房间之后界面就退场了，
## 而广播要一直持续到对局结束（别人随时可能打开界面找房间）。
var _menu: MainMenu = null
var _discovery: LanDiscovery = null
## 向房间目录登记自己的那个客户端。只在公网房间里用到。
var _directory_client: DirectoryClient = null
## 等待房间。它只在**界面路径**上出现（命令行 --host/--join 仍是「连上即开局」）。
var _lobby: Lobby = null
## 最近一次从服务端收到的大厅信息里，房主是谁。客户端唯一的来源，见 is_local_host()。
var _host_id_from_server := 0
## 本局是否已经开始。开局之前不生成任何角色：大厅只报「谁在房间里」，场上没有人。
##
## 用「不生成」而不是「生成了但冻住」：后者要先处理冻结时的物理、死亡与技能，
## 而大厅里这些东西全都没有意义；一个不存在的角色没有这些问题。
var _game_started := false
## 本次加入是否走大厅。join 的结果要等 _on_join_succeeded，因此先记一笔。
var _via_lobby := false
## 房间的公开类型（Lobby.Kind）。只用于显示，但它决定了以后房间开在哪里。
var _room_kind: int = Lobby.Kind.LAN
## 本次房间的名字。主机侧用于广播，也显示在 HUD 上，便于口头告诉另一台机器上的人。
var _room_name: String = ""
## 本次连接的 "地址:端口"，只用于提示文案。
var _join_target: String = ""
## `--advertise` 给的对外地址，只用于提示文案。空表示没给。
var _advertise: String = ""
## 服务端只在这个地址上监听。空 = 通配（正常情况）。
var _bind_ip: String = ""
## 房间目录的地址（HOST:PORT）。**传了它就表示本房间是公网房间**：
## 会向目录登记自己，且不再往局域网广播。见 docs/公网房间方案.md 的路线 A。
var _directory: String = ""
## 本房间的容量。以前由网关代管（--max-per-room），现在归房间自己，
## 因为它要随登记报给目录——列表里显示的"几个人"必须与房间的判断一致。
var _max_players: int = 2
var _port: int = 0
var _notice: String = ""
## peer id 到槽位的对应，只在服务端维护。
var _slots: Dictionary = {}
## 服务端侧：玩家加入的先后。**房主由它决定**（第一个还在线的人），
## 而不是看谁是 peer 1。理由见 host_id()。
var _join_order: Array[int] = []
var _stats_enabled: bool = false
var _stats_elapsed: float = 0.0
## 哨兵文件的检查节流，见 _check_stop_file。
var _stop_file_elapsed: float = 0.0
## 本区间内的帧时范围。帧时本身跳动大，说明画面在抖，而不是远端角色的位置在停。
var _frame_min_ms: float = 0.0
var _frame_max_ms: float = 0.0


func _ready() -> void:
	_ensure_window_mode()
	_report_display()

	# 生成函数必须在任何生成请求之前设好。接收端要用它重建节点，
	# 而引擎把它标为不序列化，所以不能写在场景文件里，只能在这里赋。
	_spawner.spawn_function = _instantiate_player

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Net.hosting_started.connect(_on_hosting_started)
	Net.join_succeeded.connect(_on_join_succeeded)
	Net.join_failed.connect(_on_join_failed)
	Net.server_left.connect(_on_server_left)

	_build_menu()
	_start_session()


## 建初始界面。它自己的可见性开关在 scenes/menu.tscn 里（初始为隐藏），
## 这里只负责连接信号；房间广播器与界面分开，见 _menu 的说明。
func _build_menu() -> void:
	_menu = MENU_SCENE.instantiate() as MainMenu
	add_child(_menu)
	_menu.host_requested.connect(_on_menu_host_requested)
	_menu.join_requested.connect(_on_menu_join_requested)
	# 大厅也在这里建：它与菜单一样是「会话开始之前的一屏」，
	# 由入口脚本持有才能在两屏之间传递状态（谁是房主、房间叫什么）。
	_lobby = LOBBY_SCENE.instantiate() as Lobby
	add_child(_lobby)
	_lobby.start_requested.connect(_on_lobby_start_requested)
	_lobby.leave_requested.connect(_on_lobby_leave_requested)
	_lobby.rename_requested.connect(_on_lobby_rename_requested)
	_discovery = LanDiscovery.new()
	add_child(_discovery)
	# 目录客户端也建在这里：房间登记与大厅状态（人数、开局）同时变化，
	# 放在同一个节点上就不必让别处知道"该什么时候刷新登记"。
	_directory_client = DirectoryClient.new()
	add_child(_directory_client)


func _start_session() -> void:
	var opts := NetCmdline.from_process()
	_port = int(opts.get("port", Net.DEFAULT_PORT))
	_advertise = String(opts.get("advertise", ""))
	_bind_ip = String(opts.get("bind", ""))
	_directory = String(opts.get("directory", ""))
	_max_players = int(opts.get("max_players", 2))
	_stats_enabled = opts.has("net_stats")
	# 手感数值可临时覆盖，便于不动代码地扫参。不给参数时取脚本里的默认值，
	# 因此这里只是把命令行值写回同一个静态变量；推算式见 player.gd 里各自的注释。
	Player.move_speed = float(opts.get("move_speed", Player.move_speed))
	Player.jump_velocity = float(opts.get("jump_velocity", Player.jump_velocity))
	Player.gravity = float(opts.get("gravity", Player.gravity))
	# 显示水位可临时覆盖，用于对照（默认由 RemoteInterpolator 按链路自适应）。
	Player.interp_buffer = float(opts.get("interp_buffer", 0.0))
	# 单机试关时的元素指定。解析不出来时保持 -1（按槽位交替分配）。
	_element_override = Element.parse(String(opts.get("element", "")))
	# 物理帧率决定位置更新的粒度，因此也是同步流"信息率"的上限：
	# 显示 120 fps 而物理 60 Hz 时，约一半的快照与上一份位置相同。
	# 只在这里覆盖，不动 project.godot，因为它是对照实验用的开关。
	if opts.has("physics_hz"):
		Engine.physics_ticks_per_second = int(opts["physics_hz"])
	# 自动驾驶只影响本机角色，是命令行开关，默认关闭。
	Player.autopilot = opts.has("autopilot")
	Player.autopilot_stop = opts.has("autopilot_stop")
	# 把生效的启动参数写进日志，便于对照两台机器上分别启动了什么。
	print("[session] 启动参数：%s" % opts)
	# 产品级可变量（官方房间地址等）在启动时读一次，并把生效值打出来。
	# 与 [feel] 行同一个道理：外部配置文件最容易出的问题是"改了但没生效"，
	# 而一行日志就能把它变成一眼可见；不打印的话只能靠打开界面看列表才知道。
	ProductConfig.load_from_disk()
	print("[config] 官方房间目录：%s" % ProductConfig.describe())
	_report_feel()

	if opts.has("join"):
		# `--lobby` 对两个方向都适用：公网房间的客户端也停在大厅等人开局，
		# 而它只能以客户端身份加入。
		# 不带则仍然是"连上即开局"——专用服务端与交付前自检依赖它。
		_begin_join(String(opts["join"]), _port, opts.has("lobby"),
			Lobby.Kind.PUBLIC if opts.has("public_room") else Lobby.Kind.LAN)
		return

	# 无头运行时没有人能点界面，因此直接当专用服务端——AGENTS.md 的交付前自检用的就是这条路径。
	# 带了 `--lobby` 时改为停在大厅等人开始：公网房间谁先到谁当房主，
	# 因此服务端不能自己就开局（见 docs/公网房间方案.md）。
	if DisplayServer.get_name() == "headless":
		_host_game("", _port, true, opts.has("lobby"))
		return
	if opts.has("host"):
		_host_game("", _port, false, opts.has("lobby"))
		return
	# 有画面而不带参数：停在初始界面上，由玩家决定创建房间还是加入别人的房间。
	_show_menu(_port)


## 把生效的手感数值与由它们推出的量打进日志。
## 存在的理由是扫参：`--move-speed` 之类的覆盖若不生效（例如没登记白名单），
## 现象只是"感觉没变"，而这一行会直接显示实际生效的值。
## 数值本身是**解析值**，与实测有约一成的差距，原因见 player.gd 里 gravity 的注释：
## 半隐式欧拉每步先加一次重力再位移，实测会跳得更高、滞空更久、因而跳得更远。
## 因此设计关卡沟宽时要留出那一成余量，不要直接拿这一行的跨度当成能跳过的距离。
func _report_feel() -> void:
	var dt := 1.0 / float(maxi(1, Engine.physics_ticks_per_second))
	var height := Player.jump_velocity * Player.jump_velocity / (2.0 * Player.gravity)
	var height_measured := height + Player.jump_velocity * dt * 0.5
	var airtime := 2.0 * Player.jump_velocity / Player.gravity
	print("[feel] 移动=%.0f px/s（%.2f 格/秒）  起跳=%.0f px/s  重力=%.0f px/s²  跳跃高度 解析 %.0f / 实测约 %.0f px（%.2f 格）  滞空 解析 %.2f s  一个跳跃跨 解析约 %.0f px（实测高约一成）" % [
		Player.move_speed, Player.move_speed / 64.0,
		Player.jump_velocity, Player.gravity,
		height, height_measured, height_measured / 64.0,
		airtime, Player.move_speed * airtime,
	])


# ---------------------------------------------------------------- 会话与界面

## 显示初始界面。房间探测随之开始，HUD 让位（界面的底色是半透明的，留着会透出来）。
##
## 同时把镜头交给一台固定的菜单相机。没有相机时 2D 画面以世界原点为视口左上角，
## 于是界面背后会是一块空处；交给菜单相机之后，背后是本关起点那一带的地形，
## 界面的半透明底色能透出它来——这是"这是一个游戏"最省事的表达方式。
## 对局中这台相机不参与：角色的相机会在它自己的 _ready 里 make_current 抢过去。
func _show_menu(port: int) -> void:
	_hud.visible = false
	# 回到菜单时大厅必须收起来：两屏同层且都不透明，留着会让菜单背后多一层。
	_lobby.close()
	_menu_camera.enabled = true
	_menu_camera.make_current()
	_menu.open(port)


## 离开初始界面进入对局。
func _leave_menu_for_game() -> void:
	_menu.close()
	_hud.visible = true


# ---------------------------------------------------------------- 等待房间

## 显示等待房间。与菜单一样把镜头交给菜单相机：大厅背后是本关起点那一带的地形，
## 半透明底色能透出它来，比一块纯色更像"游戏里的房间"。
func _show_lobby() -> void:
	_menu.close()
	_hud.visible = false
	_menu_camera.enabled = true
	_menu_camera.make_current()
	_lobby.open()
	_refresh_lobby()


func _hide_lobby() -> void:
	if _lobby != null:
		_lobby.close()


## 把本机的那份名单画出来。**只有服务端构造名单**：槽位、元素、房主都只有它知道，
## 客户端自己造会造出一份错内容——它会把自己那个 peer 1（就是服务端）当成房主、
## 房间名与类型都是自己的默认值（实测：客户端显示“房主 peer 1”“房间「」类型局域网”，
## 而服务端报的是完全不同的东西）。客户端只等 _rpc_lobby_info。
func _refresh_lobby() -> void:
	if _lobby == null or not Net.is_server():
		return
	_apply_lobby(_lobby_info())


## 把名单落到界面上，并留一行日志。两端的名单（服务端自己构造的、客户端收到的）
## 都汇聚到这里，因此“谁在什么时候看到几号人”只有一个来源。
##
## 那行日志不是装饰：公网房间里“客户端卡在大厅的等待文案上”与“服务端没下发名单”
## 在日志上完全一样（都是什么也没发生），而只有这一行能区分它们——
## 收到了没有、收到几个人、房主是谁。因此它留在正式代码里，不进测试脚本。
func _apply_lobby(info: Dictionary) -> void:
	_host_id_from_server = int(info.get("host_id", 0))
	var marked := _with_local_flags(info)
	if _lobby != null:
		_lobby.apply(marked)
	var who := int(info.get("host_id", 0))
	var players: Array = marked.get("players", [])
	print("[lobby] 名单：%d 人  房主 peer %d  房间「%s」 类型 %s  %s" % [
		players.size(), who, String(info.get("name", "")),
		Lobby.kind_name(int(info.get("kind", 0))),
		"我是房主" if is_local_host() else "等待房主",
	])


## 服务端把名单下发给各端。客户端不能自己推：槽位与元素只有服务端分配得出来。
##
## 下发的条件**不看本机的大厅界面是否可见**：公网房间是无头的，它没有可见的大厅，
## 但必须把名单下发出去，否则客户端根本进不了大厅（它们的界面上会一直是空的）。
func _broadcast_lobby() -> void:
	if _lobby != null and _lobby.visible:
		_refresh_lobby()
	# 登记与大厅名单是同一批信息的两个去处（一个给房间里的人看，一个给外面的人看），
	# 所以刷新点合并在这里——少了任何一处都会出现"大厅里显示 2 人、而列表里还是 1 人"。
	_refresh_registration()
	if not in_lobby():
		return
	if Net.is_server() and not multiplayer.get_peers().is_empty():
		_rpc_lobby_info.rpc(_lobby_info())


## 本局是不是还停在大厅。服务端与客户端共用同一个判据，
## 因此"什么时候该显示名单、什么时候该收下"两端不会分叉。
func in_lobby() -> bool:
	return _via_lobby and not _game_started


## 房间的房主。**由"谁先进来"决定**，不是看谁是 peer 1。
##
## 为什么不能看 peer 1：公网房间跑在专用服务端上，peer 1 是那个无头进程、
## 根本不是玩家，于是 `Net.is_server()` 在所有客户端上都是 false——
## 按它判断的话这个房间**没有人能开局**（按钮永远是灰的）。
## 局域网房间不受影响：它的 peer 1 就是房主自己，两者结果一致。
##
## **这个函数只在服务端有意义**（加入顺序只有服务端有）。
## 客户端请用 is_local_host()——它读的是服务端下发的那一份。
## 实测踩到的坑：早先客户端也调这里，`Net.is_dedicated()` 在客户端是 false，
## 于是它返回 1，而客户端自己的 id 是随机数，两者永不相等——
## 结果是房主点了「开始游戏」**什么也没发生**（守门那句直接 return，不报错）。
func host_id() -> int:
	if not Net.is_server():
		return 0
	if not Net.is_dedicated():
		return 1
	if _join_order.is_empty():
		return 0
	return _join_order[0]


## 本机是不是房主。两端各用自己的那份信息：
##   服务端 —— 自己算的 host_id()
##   客户端 —— **服务端下发的那一份**（自己算不出来）
func is_local_host() -> bool:
	var who := host_id() if Net.is_server() else _host_id_from_server
	return who != 0 and who == Net.local_id()


## 大厅要显示的内容。形状见 Lobby.apply 的说明。
func _lobby_info() -> Dictionary:
	var entries: Array = []
	# 房主本人（peer 1）也是一个玩家。专用服务端不是玩家，所以不进名单。
	if not Net.is_dedicated():
		entries.append(_lobby_entry(1))
	for id in multiplayer.get_peers():
		entries.append(_lobby_entry(id))
	return {
		"name": _room_name,
		"kind": _room_kind,
		"address": _join_hint(),
		"host_id": host_id(),
		"players": entries,
	}


func _lobby_entry(id: int) -> Dictionary:
	var slot := int(_slots.get(id, 0))
	return {
		"id": id,
		"slot": slot,
		"element": _element_for(slot),
		"host": id == host_id(),
		# 这里**不写 "you"**：它在各端是不同的，而这份字典是服务端构造后原样下发的，
		# 写进去等于把房主的答案发给所有人（所有人都会看到自己那一行变成房主）。
	}


## 给名单补上"是不是本机"。这一步必须在**收到下发之后**做，不能放进 _lobby_entry。
func _with_local_flags(info: Dictionary) -> Dictionary:
	var local := Net.local_id()
	var players: Array = []
	for entry in info.get("players", []):
		if not (entry is Dictionary):
			continue
		var item: Dictionary = (entry as Dictionary).duplicate()
		item["you"] = int(item.get("id", 0)) == local
		players.append(item)
	var out := info.duplicate()
	out["players"] = players
	return out


# ---------------------------------------------------------------- 开局

## 房主点了「开始游戏」。
##
## 两种房间走两条路，因为"服务端"在两边不是同一个东西：
##   局域网（listen server）—— 房主就是服务端，直接开局
##   公网（专用服务端）—— 房主是个普通客户端，只能**请**服务端开局
## 服务端收到请求后会再校一次发送者是不是房主（见 _rpc_request_start）。
func _on_lobby_start_requested() -> void:
	if not is_local_host():
		return
	if Net.is_server():
		_start_game()
		return
	_rpc_request_start.rpc_id(1)


func _on_lobby_leave_requested() -> void:
	_return_to_menu("已离开房间，可以重新选择或自己创建。")


## 房主改了房间名。
##
## **在公网房间里房主是一个普通客户端**，而名单与目录登记都由房间那边发出，
## 所以本地改名只改得动自己这一份，别人与目录都看不到（实测踩到：客户端日志里
## 改名成功、目录里还是旧名字）。因此非服务端要发 RPC 请房间去改，
## 再由房间广播给各端、并登记给目录——名字因此始终只有一份来源。
func _on_lobby_rename_requested(new_name: String) -> void:
	if not is_local_host():
		return
	var cleaned := new_name.strip_edges()
	if cleaned.is_empty():
		return
	if Net.is_server():
		_apply_room_name(cleaned)
		return
	print("[lobby] 请房间改名：「%s」" % cleaned)
	_rpc_request_rename.rpc_id(1, cleaned)


## 落地改名。服务端独有（本地设名 + 广播给各端 + 刷新目录登记）。
func _apply_room_name(new_name: String) -> void:
	# 长度按大厅与服务端共用的那个上限定。两处各写一份是刻意的：
	# 这里挡的是"绕过界面直接调 RPC"，而大厅那一位挡的是手滑输入——
	# 而"服务端假定输入已被清洗过"是这类接口最常见的漏洞。
	var cleaned := new_name.strip_edges().substr(0, Lobby.NAME_MAX_CHARS)
	if cleaned.is_empty() or cleaned == _room_name:
		return
	_room_name = cleaned
	print("[lobby] 房间改名：%s" % cleaned)
	_broadcast_lobby()


## 从大厅进入对局。**服务端独有**，由房主那一次点击触发。
##
## 三步的顺序不能换：先生成角色、再通知客户端、最后切本机。
## 否则两端会各自看到一瞬间的"已经进关了但场上没人"。
func _start_game() -> void:
	if _game_started or not Net.is_server():
		return
	_game_started = true
	var ids := multiplayer.get_peers()
	if not Net.is_dedicated():
		_spawn_player(Net.local_id())
	for id in ids:
		_spawn_player(id)
	if not ids.is_empty():
		_rpc_game_started.rpc()
	_hide_lobby()
	_leave_menu_for_game()
	_set_notice("对局开始。按 Esc 返回初始界面。")
	# 开局要立刻报给目录：它据此把这间房标为不可进（"还在等"是唯一能挡住
	# 陌生人半路插进来的东西，所以这一格的时效性不能等下一个周期）。
	_refresh_registration()


## 没有给房间名时的兜底。**公网房间的兜底带上端口**，因为这个默认值会被展示出去：
## 官方那边同时开着好几间房，它们在同一个域名上、只有端口不同（见 docs/公网房间方案.md 的
## 路线 A）。若都用同一个中性名字，列表里就是几条一字不差的行，看着像列表重复了同一个
## 条目——真机上被问到过。房主在大厅里改过名字之后这个值就被覆盖，因此它只在
## "还没人来过"时可见。局域网那一档不必区分（同一个网段里通常只有一间），保持中性名字。
func _default_room_name(port: int) -> String:
	if not _directory.is_empty():
		return "房间 %d" % port
	return LanDiscovery.default_room_name()


## 创建房间：本机开始监听，并且（非专用服务端时）本机也是一个玩家。
## 界面上的"创建房间"、命令行的 `--host` 与无头启动都汇聚到这里，三条路径的行为不会有差别。
##
## `via_lobby` 决定开局时机，两条路径都是刻意保留的：
##   界面创建（true）  —— 先停在大厅，人齐之后由房主点「开始游戏」。这是需求要的体验。
##   命令行/无头（false）—— 连上即开局。专用服务端与 tools/net-smoke.mjs 都依赖它，
##                          没人能点界面的场合下大厅没有意义（见 docs/公网房间方案.md 的 Q7）。
func _host_game(room_name: String, port: int, dedicated: bool, via_lobby: bool = false) -> void:
	_room_name = room_name if not room_name.is_empty() else _default_room_name(port)
	_port = port
	# 这两个标记必须成对设置。少设 `_via_lobby` 的后果不是界面难看，而是**名单根本不下发**——
	# `_broadcast_lobby()` 与 `in_lobby()` 都看它，于是客户端等在大厅里什么也收不到，
	# 而日志里只有一句“已连接到主机”。这个坑实测踩过一轮（服务器端永远不广播）。
	_via_lobby = via_lobby
	_game_started = not via_lobby
	# **配了目录就是公网房间。** 用这一点判定，而不是看绑在哪块网卡上：
	# 路线 A 之后房间对外监听（客户端直连它），只看绑定地址已经分不出公网与局域网。
	# 这两件事（对外监听 + 进目录）本来就是同一件事的两面。
	if not _directory.is_empty():
		_room_kind = Lobby.Kind.PUBLIC
	# 目录是公网房间与外界之间的唯一"身份来源"，写坏了就整间房都联系不上目录，
	# 所以先把它自己报一次。
	if _room_kind == Lobby.Kind.PUBLIC and _directory.is_empty():
		push_warning("房间类型是公网，但没有配 --directory，它不会出现在任何列表里")
	if Net.host(_port, dedicated, _bind_ip, _max_players) != OK:
		# 唯一可预期的失败是端口被占用（例如开发实例还开着同一个端口）。
		# 有画面时回到界面让人换端口重试，无头时只能把原因写进日志。
		var message := "端口 %d 被占用，无法创建房间。换一个端口再试。" % _port
		push_error(message)
		_set_notice(message)
		if DisplayServer.get_name() != "headless":
			_show_menu(_port)
			_menu.set_message(message)
		return
	if _room_kind == Lobby.Kind.PUBLIC:
		_start_registering()
	if via_lobby:
		_show_lobby()
		return
	_leave_menu_for_game()
	# 主机自己也是一个玩家，除非本次是无头的专用服务端。
	# 本机是否为玩家只取决于运行模式，与它是权威节点这一点无关。
	if not dedicated:
		_spawn_player(Net.local_id())


## 连接远端主机。界面列表里选中的房间与手动填写的地址都由这里发起。
## 连接结果要等 Net.join_succeeded / join_failed，因此这里不切画面：
## 失败时界面还留在屏幕上，可以直接换一个房间重试。
func _begin_join(address: String, port: int, via_lobby: bool = false, kind: int = Lobby.Kind.LAN) -> void:
	_join_target = "%s:%d" % [address, port]
	_port = port
	_room_kind = kind
	_via_lobby = via_lobby
	_game_started = not via_lobby
	_set_notice("正在连接 %s …" % _join_target)
	if Net.join(address, port) != OK:
		_on_join_failed(Net.FAIL_REJECTED)


## 结束当前会话并回到初始界面。
## 断开之后必须自己清掉角色节点：客户端收不到服务端发来的销毁包（连接已经断了），
## 留着就会看到停在原地的角色。
func _return_to_menu(message: String) -> void:
	# 先注销再断会话：注销是一次 HTTP 请求，它需要进程还活着、且目录还在。
	# 不注销也不会出事（目录靠 TTL 清理），但那样列表里会多留几秒一个已经没了的房间。
	_stop_registering()
	Net.close()
	_discovery.stop()
	_clear_players()
	_room_name = ""
	_join_target = ""
	_notice = ""
	# 三个会话级标记都要回初始值。留着任何一个（例如 _game_started）会让下一局
	# 在还没开局时就先生成角色，而那种状态看着像「大厅里有人站着」。
	_game_started = false
	_via_lobby = false
	_room_kind = Lobby.Kind.LAN
	_join_order.clear()
	_host_id_from_server = 0
	if DisplayServer.get_name() == "headless":
		# 无头运行时没有界面可回，停在"尚未开始会话"状态即可。
		_refresh_status()
		return
	_show_menu(_port)
	_menu.set_message(message)


func _clear_players() -> void:
	for child in _players.get_children():
		if child is Player:
			child.queue_free()
	_slots.clear()
	# 这一局造出来的冰、被打掉的冰墙、被拾取的积分点也一起清掉：
	# 它们是**这一局**的状态，不该跟着人走进下一个房间。
	# 角色节点之所以要在这里手动清，也是同一个原因（客户端收不到服务端发来的销毁包，
	# 因为连接已经断了），冰块同理——服务端已经不在了，没人会来告诉客户端删掉它们。
	if _game != null:
		_game.reset_for_new_session()


## 把本机房间广播到局域网，供其他人停在初始界面时看到。
## 端口由系统分配时（自检用的 `--port 0`）无法把地址告诉别人，因此不广播。
func _start_announcing() -> void:
	if Net.port <= 0:
		print("[lan] 本机端口由系统分配，不广播房间（别人拿不到可以连接的端口）")
		return
	# 公网房间不广播：局域网里的人即使看到也连不上（房间地址是公网域名），
	# 而且它会往别人的列表里塞一个重复条目（同一个人在目录里也看得到它）。
	# 它的发现渠道是目录，不是广播。
	if _room_kind == Lobby.Kind.PUBLIC:
		print("[lan] 公网房间不往局域网广播（它在目录里，地址 %s）" % _join_hint())
		return
	_discovery.announce(func() -> Dictionary:
		return {
			"name": _room_name,
			"port": Net.port,
			# 人数含主机自己，与界面上显示的"人"数是同一个口径。
			"players": multiplayer.get_peers().size() + 1,
		})
	print("[lan] 已在 UDP %d 广播房间「%s」（游戏端口 %d）" % [
		LanDiscovery.discovery_port, _room_name, Net.port,
	])
	# 把对方该填的地址明确写出来。服务器上大家都是看日志，而不是看 HUD，
	# 因此这一行比界面上的提示更有用。自动探测到的地址不一定对（见 _advertise 的说明）。
	var hint := _join_hint()
	if not hint.is_empty():
		print("[lan] 对方加入时填：%s" % hint)
	else:
		print("[lan] 未能自动判断对外地址，跨网联机时请用 --advertise <地址或域名> 指定")


# ---------------------------------------------------------------- 房间目录

## 开始向目录登记自己。只有公网房间会走到这里（见 _host_game）。
##
## 传的是**回调**而不是一份正文：房间的状态（名字、人数、有没有开局）随时会变，
## 而回调让每次发送都重新取一遍当前值（见 DirectoryClient._provider 的说明）。
func _start_registering() -> void:
	_directory_client.start_registering("http://%s" % _directory, _registration_body)
	print("[dir] 已开始向目录 %s 登记" % _directory)


## 挑目录客户端的定时器，立刻发一次。
func _refresh_registration() -> void:
	if _room_kind != Lobby.Kind.PUBLIC or _directory.is_empty():
		return
	_directory_client.refresh_now()


func _stop_registering() -> void:
	if _directory_client != null:
		_directory_client.stop_registering()


## 登记给目录的内容。形状与 tools/room-directory.py 的接口一致。
## **每次发送时现取**（它是一个回调），因此这里读到的都是最新状态。
func _registration_body() -> Dictionary:
	var parts := _advertised_parts()
	if String(parts.get("host", "")).is_empty():
		# 没有对外地址就无法登记：目录不知道该把玩家指向哪里。
		# 返回空字典让客户端这一轮不发（下一个周期再试），
		# 因为地址有可能晚一步才拿得到（网卡起来得慢）。
		return {}
	return {
		"name": _room_name,
		"host": parts.get("host", ""),
		"port": int(parts.get("port", 0)),
		"players": _player_total(),
		"max": _max_players,
		# 已经开局就报 playing。目录据此把它标为不可进——
		# 没做密码也没做好友，"还在等"是唯一能挡住陌生人半路插进来的东西。
		"state": "playing" if _game_started else "waiting",
	}


## 房间里一共有几个人（含主机自己）。专用服务端不算玩家。
func _player_total() -> int:
	return multiplayer.get_peers().size() + (0 if Net.is_dedicated() else 1)


## 房间的对外 "host:port"，拆成两半。地址优先用 `--advertise`（云服务器上
## 网卡只有 VPC 私网地址，自动探测出来的对外没有意义），端口默认是本房间自己的端口。
func _advertised_parts() -> Dictionary:
	var host := ""
	var port := _port
	if not _advertise.is_empty():
		if _advertise.contains(":"):
			host = _advertise.get_slice(":", 0)
			port = int(_advertise.get_slice(":", 1))
		else:
			host = _advertise
	else:
		for address in _lan_addresses():
			host = address
			break
	return {"host": host, "port": port}


func _on_menu_host_requested(room_name: String, port: int, kind: int) -> void:
	# 走到这里的只可能是局域网：公网房间是预先存在的（目录里一列），
	# "创建公网房间"实际上是"加入一间空房"，界面那边会直接发 join_requested。
	_room_kind = kind
	_host_game(room_name, port, false, true)


## 「创建房间 → 公网」在界面上就是「加入一间空房」——路线 A 里公网房间是**预先存在的**
##（目录里始终列着那几间），因此没有一个"在本机开服务端"的动作可做。
## 这一段旧实现（连官方网关领房间）已随路线 A 作废，保留这段说明是为了让后来的人
## 明白"创建公网房间"为什么不见了，而不是以为它被漏掉了。
func _on_menu_join_requested(address: String, port: int, kind: int) -> void:
	_begin_join(address, port, true, kind)


## 对局中按 Esc 回到初始界面。主机按下等于关掉房间，另一台机器会收到"与主机断开"。
## 用 ui_cancel 而不是写死键码，这样以后做输入重绑定也不必改这里。
func _unhandled_input(event: InputEvent) -> void:
	if _menu.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		_return_to_menu("已离开房间，可以重新选择或自己创建。")


## 对方应当填的 "地址:端口"。优先用 `--advertise` 给的值，否则用本机的局域网地址。
## 存在的理由：云服务器上 IP.get_local_addresses() 只有 VPC 私网地址（172.16.x.x），
## 对外没有意义；而公网地址是 NAT 映射的，网卡上根本不存在，程序无从得知。
##
## `--advertise` 允许带端口（"host:port"）。
## **这个值同时也是登记到目录的那个地址**，因此它必须是对外真能连上的那个。
func _join_hint() -> String:
	var parts := _advertised_parts()
	if String(parts.get("host", "")).is_empty() or int(parts.get("port", 0)) <= 0:
		return ""
	return "%s:%d" % [parts["host"], int(parts["port"])]


## 本机的 IPv4 地址，"最像局域网地址"的排在前面。跳过环回与链路本地（169.254.*）：
## 前者别人连不上，后者是没有取到 DHCP 地址时的自动地址。
func _lan_addresses() -> PackedStringArray:
	var preferred := PackedStringArray()
	var rest := PackedStringArray()
	for address in IP.get_local_addresses():
		if address.contains(":") or address.begins_with("127.") or address.begins_with("169.254."):
			continue
		if address.begins_with("192.168.") or address.begins_with("10."):
			preferred.append(address)
		elif address.begins_with("172."):
			# 172.16.0.0/12 是私有网段，第二段的取值在 16～31 之间。
			var second := int(address.get_slice(".", 1))
			if second >= 16 and second <= 31:
				preferred.append(address)
			else:
				rest.append(address)
		else:
			rest.append(address)
	preferred.append_array(rest)
	return preferred


# ---------------------------------------------------------------- 玩家名单

func _on_peer_connected(id: int) -> void:
	print("[session] peer %d 已连接" % id)
	# 只有服务端负责生成角色，其余 peer 等生成包到达即可。
	if Net.is_server():
		# 加入顺序要**先记**：host_id() 取的是第一个还在线的人，
		# 而下面那句 _broadcast_lobby() 会把它写进下发的名单里。
		if not _join_order.has(id):
			_join_order.append(id)
		# 槽位在**连接的那一刻**就分配，而不是等到开局。理由是大厅要显示
		# 「谁是熔、谁是霜」（元素由槽位推出来，见 _element_for）；
		# 等到开局才分的话，大厅里只能显示一串没有意义的 peer 号。
		_allocate_slot(id)
		# 开局之后连进来的人才立刻生成，否则他就是大厅里的下一个人。
		if _game_started:
			_spawn_player(id)
			# 排在这一句之后：先把人放到场上，再把他没见过的那部分世界（打掉的墙、
			# 已经拿掉的积分……）补给他。见 Game.catch_up 的说明。
			_game.on_peer_joined(id)
	_broadcast_lobby()
	_refresh_status()


func _on_peer_disconnected(id: int) -> void:
	print("[session] peer %d 已断开" % id)
	# 同样只有服务端负责销毁；这次销毁由 MultiplayerSpawner 同步给其余 peer。
	if Net.is_server():
		_slots.erase(id)
		# 退出的若是房主，host_id() 会自动交给下一个还在线的人（见它的实现）。
		# 这就是为什么房主不能是一个固定下发过一次的 id。
		_join_order.erase(id)
		_game.on_peer_left(id)
		var player := _players.get_node_or_null(_peer_node_name(id))
		if player != null:
			player.queue_free()
	_broadcast_lobby()
	# 房间里一个人都不剩时回到空闲状态，等下一批人。
	#
	# **公网房间必须这样做。** 它们由网关按需使用，而一个"用过一次就永远停在对局中"
	# 的房间会让整个房间池在第一次对局之后就失效：后面连进来的人会被直接塞进一个
	# 已经开始的关卡（大厅不下发、一上来就生成角色，而客户端那边的表现是
	# 一直卡在「正在等待房间信息」）。
	# 实测踩到过：一次成功的对局之后该房间就再也不发大厅名单，看着像网关坏了。
	if Net.is_server() and _via_lobby and multiplayer.get_peers().is_empty():
		_reset_to_lobby()
	_refresh_status()


## 把房间收回空闲状态：清掉这一局留下的一切，重新打开大厅等下一批玩家。
## 走的是与首次进大厅完全相同的那条路径（_show_lobby），因此两处的状态不会分叉。
func _reset_to_lobby() -> void:
	_game_started = false
	# 加入顺序必须清掉：房主是"第一个进来的人"，而上一局的顺序留着的话，
	# 下一批人里会有一个早就不在房间里的 peer 被认成房主 —— 于是谁也点不了开始。
	_join_order.clear()
	# 房间名也要回到默认值。理由是"房间名由房主配置"这条规则的直接推论：
	# 人走光了就没有房主了，而留下来的是一个**上一批人的名字**（下一批人进来会看到
	# 一间空房叫"小明和他的朋友"）。用 Net.port 而不是 _port：后者在 `--port 0` 时是 0。
	_room_name = _default_room_name(Net.port)
	_clear_players()
	print("[lobby] 房间已回到空闲状态，等下一批玩家")
	_show_lobby()
	# 立刻把"回到等待中"报给目录。不这么做的话它要等下一个周期（最多 2 秒），
	# 而刚走完一局的房间在这两秒里仍显示"进行中"、不可进——
	# 真机上看起来就像那间房坏了。
	_refresh_registration()


## MultiplayerSpawner 的生成函数。各端都会用同一份参数调用它，
## 因此 peer id、槽位与元素都随生成包一起送达，不必再从节点名反推。
## 注意这里只能依赖入参：各端要得出同一棵节点树，所以不能引用本机的临时状态。
func _instantiate_player(data: Variant) -> Node:
	var info: Dictionary = {}
	if data is Dictionary:
		info = data
	var id := int(info.get("id", 1))
	var slot := int(info.get("slot", 0))
	var player := PLAYER_SCENE.instantiate() as Player
	# 名字在同一父节点下必须唯一且合法：引擎用它在接收端重建同名节点，
	# 而以 `@` 开头的自动生成名会被拒绝。
	player.name = _peer_node_name(id)
	player.peer_id = id
	player.spawn_slot = slot
	player.element = int(info.get("element", Element.Kind.MOLTEN))
	player.position = _slot_position(slot)
	return player


func _spawn_player(id: int) -> void:
	if _players.has_node(_peer_node_name(id)):
		return
	var slot := _slot_for(id)
	_spawner.spawn({"id": id, "slot": slot, "element": _element_for(slot)})
	print("[session] 生成玩家 %d（槽位 %d，%s）" % [id, slot, Element.kind_name(_element_for(slot))])


## 取这个 peer 的槽位。大厅期间已经分配过，因此正常情况下这里只是读一次；
## 命令行 `--host` 直接开局时没有大厅那一步，所以也要能补分配。
func _slot_for(id: int) -> int:
	if _slots.has(id):
		return int(_slots[id])
	return _allocate_slot(id)


## 槽位对应的元素。默认 0 号熔、1 号霜，与设计文档 3.1 的"两人一熔一霜"一致；
## 命令行给了 --element 时只改第一个槽位，方便单机试关。
## 注意这只是**出生时**的分配：开局之后谁是什么由交换角色决定（机制与玩法设计 2.3）。
func _element_for(slot: int) -> int:
	if slot == 0 and _element_override >= 0:
		return _element_override
	return Element.Kind.MOLTEN if slot % 2 == 0 else Element.Kind.FROST


## 取当前未被占用的最小槽位。只在服务端调用，然后随生成参数告知各端。
func _allocate_slot(id: int) -> int:
	# 已经分配过就返回原值。重复分配会让同一个人在大厅里换一个元素，
	# 而「他是熔还是霜」在大厅里已经显示出来了，中途变掉看起来像出了 bug。
	if _slots.has(id):
		return int(_slots[id])
	var taken: Dictionary = {}
	for slot in _slots.values():
		taken[slot] = true
	var slot := 0
	while taken.has(slot):
		slot += 1
	_slots[id] = slot
	return slot


## 出生点。关卡载入之后一律用关卡自己的出生点：出生点属于关卡设计的一部分
##（它决定了开局第一眼看到什么），写在关卡场景里才能随关卡一起调。
## 下面的等距排布只是关卡还没载入时的兜底，避免"没有关卡就生成在原点"。
func _slot_position(slot: int) -> Vector2:
	if _game != null and _game.level != null:
		return _game.level.spawn_point(slot)
	var offset := (float(slot) - (float(SPAWN_SLOTS) - 1.0) * 0.5) * SPAWN_SPACING
	return Vector2(offset, SPAWN_HEIGHT)


## 初始界面或等待房间是不是开着。Game 用它决定收不收对局内的按键——
## 两屏都处于「会话尚未开局」的状态，对局输入在它们上面都没有意义。
## 只有入口脚本知道界面在不在（两屏都是它建的），所以由这里回答，
## 而不是让 Game 去翻菜单与大厅。
func is_menu_open() -> bool:
	return (_menu != null and _menu.visible) or (_lobby != null and _lobby.visible)


func _peer_node_name(id: int) -> String:
	return "p%d" % id


# ---------------------------------------------------------------- 诊断输出

## 按固定间隔输出每个角色的同步与显示状态。
## 每一行都可以单独下结论：
##   本机那一行是"发送方基准"：我实际多久产生一个新位置。
##     与远端那行的 最大到达间隔 对照即可定位空档来源：
##     本机 17 ms 而远端 100 ms → 空档在链路（无线链路的省电投递很可能）；
##     本机自己也是 100 ms → 是我这台的帧或物理在卡，与网络无关
##   停顿 不为 0 → 缓冲被追平、显示在等新数据（对端静止时不计数，那种保持无意义）
##   最大单帧位移 是"跳一下"的直接计量：平滑运动每帧只应前进
##     Player.move_speed ÷ 显示帧率（480 px/s、120 帧时是 4 px）；
##     若到 40 px 量级，就是那一帧把积攒的运动量一次走完了。
##     它自带"当时"的上下文（滞后、钟速、是否在保持、距上次新位置多久），
##     直接指向前四轮各自定位到的那几类成因。
##   缓冲 远大于目标 → 滞后偏大，钟速会把它消耗掉
##   重复 高 → 发送方位置变化比快照发送慢（物理帧率低于网络帧率），已自动处理
func _process(delta: float) -> void:
	_check_stop_file(delta)
	if not _stats_enabled:
		return
	var frame_ms := delta * 1000.0
	if _frame_min_ms <= 0.0 or frame_ms < _frame_min_ms:
		_frame_min_ms = frame_ms
	if frame_ms > _frame_max_ms:
		_frame_max_ms = frame_ms
	_stats_elapsed += delta
	if _stats_elapsed < STATS_INTERVAL:
		return
	_stats_elapsed = 0.0
	print("[net-stats] 帧率=%d  帧时=%.1f～%.1f ms  物理帧率=%d  RTT=%s  估计显示滞后≈%s" % [
		Engine.get_frames_per_second(), _frame_min_ms, _frame_max_ms,
		Engine.physics_ticks_per_second, _rtt_label(), _lag_label(),
	])
	_frame_min_ms = 0.0
	_frame_max_ms = 0.0
	for child in _players.get_children():
		if child is Player:
			_report_player(child as Player)


## 显示滞后的构成估算。它回答的是"我看别人的动作慢多少"，即别人按下按键到我看见位移的总时延。
## 各项含义与来源：
##   水位        —— 平滑缓冲，代码可控，且按实测链路自动缩短（远端行里的 缓冲 就是它）
##   RTT/2       —— 单向链路时延，实测
##   发送步长    —— 发送方位置只在物理帧变化，平均等半个物理帧
##   本机一帧    —— 我自己渲染一帧的时间，平均半个显示帧
## 没有包含：对方向我发包时的网络排队、以及我这边显示的合并延迟（后者已含在"本机一帧"）。
## 只统计**正在接收位置更新**的远端角色：从头就静止的角色不会产生水位样本，
## 它的水位停在初始值上（实测导致总览行报 150 ms，而实际在动的角色只需 108 ms），
## 用它算滞后会把读数抬高、看起来与远端行矛盾。
func _lag_label() -> String:
	if Net.rtt_ms < 0.0:
		return "测量中"
	var buffer_ms := -1.0
	for child in _players.get_children():
		if child is Player and not child.is_local():
			if not (child as Player).is_receiving_motion():
				continue
			buffer_ms = maxf(buffer_ms, float((child as Player).reported_buffer_seconds()) * 1000.0)
	if buffer_ms < 0.0:
		return "无可测对象（对端静止）"
	var fps := maxf(1.0, float(Engine.get_frames_per_second()))
	var one_way := Net.rtt_ms * 0.5
	var physics_half := 1000.0 / maxf(1.0, float(Engine.physics_ticks_per_second)) * 0.5
	var frame_half := 1000.0 / fps * 0.5
	var total := buffer_ms + one_way + physics_half + frame_half
	return "%.0f ms（水位 %.0f + 单程 %.0f + 发送 %.0f + 本机一帧 %.0f）" % [
		total, buffer_ms, one_way, physics_half, frame_half,
	]


func _rtt_label() -> String:
	return "测量中" if Net.rtt_ms < 0.0 else "%.0f ms" % Net.rtt_ms


func _report_player(player: Player) -> void:
	var stats := player.report_stats_and_reset()
	var per_second := float(stats["arrivals"]) / STATS_INTERVAL
	if player.is_local():
		# 本机角色报的是"发送方基准"：我实际多久产生一个新位置。
		# 与远端角色的"最大到达间隔"对照，就能判断空档产生在链路还是在我这边。
		var change_rate := float(stats["change_count"]) / STATS_INTERVAL
		print("[net-stats]   本机 peer=%d 位置更新=%.1f 次/秒  最大间隔=%.0f ms  显示移动=%.0f px（发送方基准）" % [
			player.peer_id, change_rate, stats["change_gap_max_ms"], stats["moved"],
		])
		return
	# 回拉分两路报：收到的那一路有回拉说明发送方或传输层给了旧值；
	# 只有显示那一路有回拉，则是本地平滑推过头又被拉回（详见 step_analyzer.gd）。
	var recv_dips := "0"
	if int(stats["recv_dips"]) > 0:
		recv_dips = "%d 次/最大 %.2f m" % [stats["recv_dips"], stats["recv_dip_max"]]
	var disp_dips := "0"
	if int(stats["disp_dips"]) > 0:
		disp_dips = "%d 次/最大 %.2f m" % [stats["disp_dips"], stats["disp_dip_max"]]
	print("[net-stats]   远端 peer=%d 每秒到达=%.1f 次  最大到达间隔=%.0f ms  重复=%.0f%%  停顿=%.0f%%  缓冲=%.0f/%.0f ms（基准 %.0f + 补偿 %.0f）  最大连续间隔=%.0f ms  钟速=%.2f×  最大单帧位移=%s  显示移动=%.0f px  收到回拉=%s  显示回拉=%s" % [
		player.peer_id, per_second, stats["max_gap_ms"],
		float(stats["duplicated_ratio"]) * 100.0,
		float(stats["hold_ratio"]) * 100.0,
		float(stats["fill"]) * 1000.0, float(stats["buffer"]) * 1000.0,
		float(stats["link_floor"]) * 1000.0, float(stats["stall_penalty"]) * 1000.0,
		float(stats["worst_gap"]) * 1000.0,
		stats["rate"], stats["jump_context"], stats["moved"], recv_dips, disp_dips,
	])


## 开局通知。`call_remote` 是必须的：不带它时 rpc() 会不会在本地也执行一遍
## 取决于同步模式，而「主机自己进了两次对局」这类现象只在有第二台机器时才出现。
## 本机那一次由 _start_game() 显式调用，因此这里只负责远端。
##
## 挂在入口脚本上（路径 /root/Main）是安全的：它在各端都存在且路径固定，
## 与 Game 挂在 /root/Main/Game 同理。对比 Player——它由 MultiplayerSpawner 生成，
## 路径里带 peer id，路径一旦对不上 RPC 会**静默失败**，查起来极贵。
@rpc("authority", "call_remote", "reliable")
func _rpc_game_started() -> void:
	_game_started = true
	_hide_lobby()
	_leave_menu_for_game()
	_set_notice("对局开始。按 Esc 返回初始界面。")


## 名单下发。每次有人进出都重发一份完整的，而不是发增量：
## 大厅最多四个人，一份名单几十字节；增量省下的流量远小于
## 「两端各持一份名单、其中一份落后了」这种 bug 的代价。
@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_info(info: Dictionary) -> void:
	_apply_lobby(info)


## 客户端请服务端改名（公网房间里房主是个普通客户端，见 _on_lobby_rename_requested）。
##
## `any_peer` 是必须的：发起者不是权威节点。因此**服务端必须自己校发送者**，
## 不能假定"能调到我这个方法的都是好人"——否则任何一个客户端都能把房间名改掉。
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_rename(new_name: String) -> void:
	if not Net.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != host_id():
		print("[lobby] 忽略 peer %d 的改名请求：房主是 peer %d" % [sender, host_id()])
		return
	_apply_room_name(new_name)


## 客户端向服务端请求开局（公网房间里房主是个普通客户端，见 _on_lobby_start_requested）。
##
## `any_peer` 是必须的：发起者不是权威节点。因此**服务端必须自己校发送者**，
## 不能假定“能调到我这个方法的都是好人”——否则任何一个客户端都能把全房间拉进对局。
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_start() -> void:
	if not Net.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != host_id():
		print("[session] 忽略 peer %d 的开局请求：房主是 peer %d" % [sender, host_id()])
		return
	_start_game()


# ---------------------------------------------------------------- 状态显示

func _on_hosting_started(p_port: int) -> void:
	print("[session] %s，监听 %s" % ["专用服务端" if Net.is_dedicated() else "主机", _listen_label()])
	_refresh_status()
	_start_announcing()


## 端口 0 表示让系统分配空闲端口（自检用），此时不能用数字描述监听地址。
func _listen_label() -> String:
	return "UDP %d" % _port if _port != 0 else "系统分配的 UDP 端口"


func _on_join_succeeded() -> void:
	print("[session] 已连接到主机")
	if _via_lobby:
		# 只把界面切过去，名单与房间信息等主机下发（槽位与元素只有服务端分配得出来）。
		_show_lobby()
		_lobby.set_message("已进入房间，等待房主开始游戏。")
		return
	_leave_menu_for_game()
	_set_notice("已连接到主机，等待服务端生成本机角色。按 Esc 返回初始界面。")


func _on_join_failed(reason: String) -> void:
	print("[session] 连接失败：%s" % reason)
	var message := _join_failed_message(reason)
	_set_notice(message)
	if DisplayServer.get_name() == "headless":
		return
	# 回到初始界面，保留已填的地址便于改一个数字重试。
	_show_menu(_port)
	_menu.set_message(message)


## 连接失败时该说什么。分成三种，因为玩家该做的事完全不同：
##   被拒绝（有明确的拒绝包）  —— 地址或端口不对
##   没有回应（我们自己判的超时） —— 可能是对方不在，**也可能是官方房间都满了**
##   其他    —— 给一条通用的排查路径
## 之前只有最后那句“核对地址与端口、确认防火墙放过 UDP”，
## 而“官方房间满了”时地址对、端口对、防火墙也没问题，玩家会去查一个不存在的问题。
func _join_failed_message(reason: String) -> String:
	if reason == Net.FAIL_TIMEOUT and _via_lobby and _room_kind == Lobby.Kind.PUBLIC:
		return "连接 %s 没有回应。可能是官方房间都满了（每个房间只坐两个人），过一会儿再试；也可能是服务器暂时不可达。" % _join_target
	if reason == Net.FAIL_TIMEOUT:
		return "连接 %s 超时，对方没有回应。核对地址与端口，并确认主机侧防火墙放行了该 UDP 端口。" % _join_target
	return "连接 %s 失败：%s。核对地址与端口，并确认主机侧防火墙放行了该 UDP 端口。" % [_join_target, reason]


func _on_server_left(reason: String) -> void:
	print("[session] 与主机断开：%s" % reason)
	_return_to_menu("%s。可以重新选择一个房间，或由本机创建房间。" % reason)


func _set_notice(text: String) -> void:
	_notice = text
	_refresh_status()


func _refresh_status() -> void:
	var room := _room_line()
	if _notice.is_empty():
		_status.text = room
		return
	# 提示在上、连接状态在下：提示说的是"刚刚发生了什么"（连接失败、已离开房间），
	# 状态说的是"现在是什么"，前者更紧急，因此放在第一行。
	_status.text = "%s\n%s" % [_notice, room]


## 连接状态压成一行。早先这里是四行（角色、对方该填的地址、peer id、按键说明），
## 占了屏幕左上角一大块，看起来像调试覆盖层而不是游戏界面。
## 按键说明在 HUD 底部另有一份，peer id 只有排查时才要看，两者都不该常驻。
func _room_line() -> String:
	match Net.role:
		Net.Role.SERVER:
			var kind := "专用服务端" if Net.is_dedicated() else "主机"
			var room := " · 房间「%s」" % _room_name if not _room_name.is_empty() else ""
			# 这一段的用途是"探测不到时口头报地址"，因此它该显示的是对方要填什么。
			var hint := _join_hint()
			var join := " · 对方加入填 %s" % hint if not hint.is_empty() else ""
			return "%s%s · 在场 %s · 监听 %s%s" % [kind, room, _describe_peers(), _listen_label(), join]
		Net.Role.CLIENT:
			var target := _join_target if not _join_target.is_empty() else "UDP %d" % _port
			return "客户端 · 已连接 %s" % target
	return "尚未开始会话"


## 在场的人。主机自己算一个，因此这里报的是"除本机以外的 peer"。
func _describe_peers() -> String:
	# 断开之后 multiplayer_peer 已被清空，此时查询 peer 列表会报错，所以先看会话状态。
	if Net.role == Net.Role.OFFLINE:
		return "无"
	var ids := multiplayer.get_peers()
	if ids.is_empty():
		return "1 人（只有本机）"
	var parts := PackedStringArray()
	for id in ids:
		parts.append(str(id))
	return "%d 人（另有 peer %s）" % [ids.size() + 1, ", ".join(parts)]


## 退出时主动结束会话。
## 这个钩子在**正常的进程退出**时都会跑到：systemd 停止服务（发 SIGTERM）、控制台上关机、
## 窗口被关掉。它会 poll 一次再关 peer，使 ENet 的断开通知真正发出，
## 各客户端因此**不等心跳超时**就知道服务端下线。
## 进程被强杀（SIGKILL、断电、内核崩溃）时跑不到这里，那种情况只能由客户端的心跳判定兜住
##（见 scripts/net/net.gd 的 HEARTBEAT_TIMEOUT）。两者都要有，因为前者盖不住后者。
## 实测（2026-09-26）：`systemctl stop` 于 0.4 秒内完成，无 SIGKILL，无超时等待。
func _exit_tree() -> void:
	if Net.role != Net.Role.OFFLINE:
		Net.shutdown_gracefully()


# ---------------------------------------------------------------- 优雅停止

## 看有没有人请我们退出。**这是让 `systemctl stop` 也能立刻通知客户端的办法。**
##
## 背景：Godot 收到 SIGTERM 是立刻退出，**不走 `_exit_tree`**（2026-09-30 实测：
## 进程 8～24 毫秒就没了，而 shutdown_gracefully() 那六轮 poll 本身要 240 毫秒）。
## 于是 `systemctl stop` 时断开通知从未发出，客户端只能等 5 秒心跳，
## 看到的是"与主机失去联系"而不是"与主机断开"。
## 而部署时的重启、控制台关机走的都是 SIGTERM，所以这条路不能不管。
##
## 做法：单元的 `ExecStop` 先建一个哨兵文件，再**在脚本里**等进程自己退出。
## 等到就不发 SIGTERM，于是走到这里 → `get_tree().quit()` → 正常退出 →
## `_exit_tree` 跑到 → 通知送达。等待放在 ExecStop 里（而不是靠 systemd 的
## TimeoutStopSec），因为 systemd 在 ExecStop 返回之后就会发 SIGTERM，
## 而那时游戏还没反应过来。
##
## 只在**固定端口**上启用：`--port 0`（自检用）拿不到可预测的文件名，
## 而服务端进程没有被 stop 的需要。
func _check_stop_file(delta: float) -> void:
	if _port <= 0 or DisplayServer.get_name() != "headless":
		return
	_stop_file_elapsed += delta
	if _stop_file_elapsed < STOP_FILE_INTERVAL:
		return
	_stop_file_elapsed = 0.0
	if FileAccess.file_exists(stop_file_path()):
		print("[session] 收到停止请求（%s），走正常退出以便通知客户端" % stop_file_path())
		get_tree().quit()


## 哨兵文件的路径。**这个拼法必须与 tools/graceful-stop.sh 一致**——
## 两边各写一份是刻意的：它们分别位于 GDScript 与 shell 里，没有办法共用一份常量。
## 改这里就要改那边，否则停止会静默退化回"客户端多等 5 秒"（不报错，只是变慢）。
static func stop_file_path_for(port: int) -> String:
	return "/tmp/moltenfrost-stop-%d" % port


func stop_file_path() -> String:
	return stop_file_path_for(_port)


func _ensure_window_mode() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var wanted := int(ProjectSettings.get_setting_with_override(MODE_SETTING))
	if DisplayServer.window_get_mode() != wanted:
		DisplayServer.window_set_mode(wanted as DisplayServer.WindowMode)


func _report_display() -> void:
	var screen := DisplayServer.screen_get_size()
	var window := DisplayServer.window_get_size()
	var viewport := get_viewport().get_visible_rect().size
	print("[display] 后端=%s 生效模式=%s 导出后=%s 屏幕=%dx%d 窗口=%dx%d 视口=%dx%d" % [
		DisplayServer.get_name(),
		_mode_name(int(ProjectSettings.get_setting_with_override(MODE_SETTING))),
		_mode_name(int(ProjectSettings.get_setting(MODE_SETTING))),
		screen.x, screen.y,
		window.x, window.y,
		int(viewport.x), int(viewport.y),
	])


func _mode_name(mode: int) -> String:
	match mode:
		DisplayServer.WINDOW_MODE_WINDOWED:
			return "窗口"
		DisplayServer.WINDOW_MODE_MINIMIZED:
			return "最小化"
		DisplayServer.WINDOW_MODE_MAXIMIZED:
			return "最大化"
		DisplayServer.WINDOW_MODE_FULLSCREEN:
			return "全屏"
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			return "独占全屏"
	return str(mode)
