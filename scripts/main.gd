extends Node2D
## 工程入口：决定本机在本次会话里的角色，并把状态显示在 HUD 上。
##
## 角色判定（参数解析见 scripts/net/net_cmdline.gd）：
##   `--join <地址>`  连接到远端权威节点
##   其余情况         开始监听，并且本机也是玩家（listen server）
##   其中 headless    标记为专用服务端，本机不生成玩家角色
## 也就是说"不带参数运行"等于本机开局，在编辑器里直接按运行就能调关卡与手感。
## 目前还没有主菜单，所以默认值取最省事的那个；有菜单之后这里交给菜单决定。
##
## 关于开发期窗口化：project.godot 里写了 window/size/mode=3（全屏）与
## window/size/mode.editor=0（窗口）。后者是特性标签覆盖，只在用编辑器程序运行的时候
## 生效——编辑器的「游戏嵌入」需要窗口模式，而导出产物的二进制不带 editor 特性，
## 取到的仍是全屏。所以下面用 get_setting_with_override 取值，让实际窗口状态跟上它。
## 注意：project.godot 里的注释在编辑器保存工程时会被删掉，说明写在这里。

const MODE_SETTING := "display/window/size/mode"
const PLAYER_SCENE := preload("res://scenes/player.tscn")
## 生成位置沿地面横向等距错开。槽位由服务端分配，因此不会出现两人重叠在同一个点。
## 2D 只有一条地面线，所以是一维排布；间距取 96 px（角色宽 48 px，相当于留出一个身位）。
const SPAWN_SLOTS := 6
const SPAWN_SPACING := 96.0
## 出生高度。地面顶面在 y=0、角色半高 48，因此 -70 让角色开局位于离地 22 px 处然后自然落到地面，
## 而不是与地面重叠后再被推出来（那会在第一帧产生一次假的位移尖峰，混进平滑诊断里）。
const SPAWN_HEIGHT := -70.0
## --net-stats 的输出间隔。
const STATS_INTERVAL := 2.0

@onready var _players: Node2D = $Players
@onready var _spawner: MultiplayerSpawner = $Players/Spawner
@onready var _status: Label = $HUD/Status

var _port: int = 0
var _notice: String = ""
## peer id 到槽位的对应，只在服务端维护。
var _slots: Dictionary = {}
var _stats_enabled: bool = false
var _stats_elapsed: float = 0.0
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

	_start_session()


func _start_session() -> void:
	var opts := NetCmdline.from_process()
	_port = int(opts.get("port", Net.DEFAULT_PORT))
	_stats_enabled = opts.has("net_stats")
	# 手感数值可临时覆盖，便于不动代码地扫参。不给参数时取脚本里的默认值，
	# 因此这里只是把命令行值写回同一个静态变量；推算式见 player.gd 里各自的注释。
	Player.move_speed = float(opts.get("move_speed", Player.move_speed))
	Player.jump_velocity = float(opts.get("jump_velocity", Player.jump_velocity))
	Player.gravity = float(opts.get("gravity", Player.gravity))
	# 显示水位可临时覆盖，用于对照（默认由 RemoteInterpolator 按链路自适应）。
	Player.interp_buffer = float(opts.get("interp_buffer", 0.0))
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
	_report_feel()

	if opts.has("join"):
		var address := String(opts["join"])
		_set_notice("正在连接 %s:%d …" % [address, _port])
		Net.join(address, _port)
		return

	# 没有 --join 就都当主机。headless 下没有窗口，也就没有本机玩家。
	var dedicated := DisplayServer.get_name() == "headless"
	if Net.host(_port, dedicated) != OK:
		_set_notice("端口 %d 被占用，无法开始监听。用 --port 换一个端口。" % _port)
		return
	# 主机自己也是一个玩家，除非本次是无头的专用服务端。
	# 本机是否为玩家只取决于运行模式，与它是权威节点这一点无关。
	if not dedicated:
		_spawn_player(Net.local_id())


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


# ---------------------------------------------------------------- 玩家名单

func _on_peer_connected(id: int) -> void:
	print("[session] peer %d 已连接" % id)
	# 只有服务端负责生成角色，其余 peer 等生成包到达即可。
	if Net.is_server():
		_spawn_player(id)
	_refresh_status()


func _on_peer_disconnected(id: int) -> void:
	print("[session] peer %d 已断开" % id)
	# 同样只有服务端负责销毁；这次销毁由 MultiplayerSpawner 同步给其余 peer。
	if Net.is_server():
		_slots.erase(id)
		var player := _players.get_node_or_null(_peer_node_name(id))
		if player != null:
			player.queue_free()
	_refresh_status()


## MultiplayerSpawner 的生成函数。各端都会用同一份参数调用它，
## 因此 peer id 与槽位随生成包一起送达，不必再从节点名反推。
## 注意这里只能依赖入参：各端要得出同一棵节点树，所以不能引用本机的临时状态。
func _instantiate_player(data: Variant) -> Node:
	var info: Dictionary = {}
	if data is Dictionary:
		info = data
	var id := int(info.get("id", 1))
	var player := PLAYER_SCENE.instantiate() as Player
	# 名字在同一父节点下必须唯一且合法：引擎用它在接收端重建同名节点，
	# 而以 `@` 开头的自动生成名会被拒绝。
	player.name = _peer_node_name(id)
	player.peer_id = id
	player.position = _slot_position(int(info.get("slot", 0)))
	return player


func _spawn_player(id: int) -> void:
	if _players.has_node(_peer_node_name(id)):
		return
	_spawner.spawn({"id": id, "slot": _allocate_slot(id)})
	print("[session] 生成玩家 %d" % id)


## 取当前未被占用的最小槽位。只在服务端调用，然后随生成参数告知各端。
func _allocate_slot(id: int) -> int:
	var taken: Dictionary = {}
	for slot in _slots.values():
		taken[slot] = true
	var slot := 0
	while taken.has(slot):
		slot += 1
	_slots[id] = slot
	return slot


func _slot_position(slot: int) -> Vector2:
	var offset := (float(slot) - (float(SPAWN_SLOTS) - 1.0) * 0.5) * SPAWN_SPACING
	return Vector2(offset, SPAWN_HEIGHT)


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


# ---------------------------------------------------------------- 状态显示

func _on_hosting_started(p_port: int) -> void:
	print("[session] %s，监听 %s" % ["专用服务端" if Net.is_dedicated() else "主机", _listen_label()])
	_refresh_status()


## 端口 0 表示让系统分配空闲端口（自检用），此时不能用数字描述监听地址。
func _listen_label() -> String:
	return "UDP %d" % _port if _port != 0 else "系统分配的 UDP 端口"


func _on_join_succeeded() -> void:
	print("[session] 已连接到主机")
	_set_notice("已连接到主机，等待服务端生成本机角色")


func _on_join_failed() -> void:
	print("[session] 连接失败")
	_set_notice("连接失败。核对地址与端口，并确认主机侧防火墙放行了该 UDP 端口。")


func _on_server_left() -> void:
	print("[session] 与主机断开")
	_set_notice("与主机断开。")


func _set_notice(text: String) -> void:
	_notice = text
	_refresh_status()


func _refresh_status() -> void:
	var lines := PackedStringArray()
	match Net.role:
		Net.Role.SERVER:
			var kind := "专用服务端" if Net.is_dedicated() else "主机（本机也是玩家）"
			lines.append("角色：%s，监听 %s" % [kind, _listen_label()])
		Net.Role.CLIENT:
			lines.append("角色：客户端，已连接 UDP %d" % _port)
		_:
			lines.append("角色：尚未开始会话")
	lines.append("本机 peer id：%d    其他 peer：%s" % [Net.local_id(), _describe_peers()])
	lines.append("操作：A/D 移动，空格跳跃")
	if not _notice.is_empty():
		lines.append(_notice)
	_status.text = "\n".join(lines)


func _describe_peers() -> String:
	# 断开之后 multiplayer_peer 已被清空，此时查询 peer 列表会报错，所以先看会话状态。
	if Net.role == Net.Role.OFFLINE:
		return "无"
	var ids := multiplayer.get_peers()
	if ids.is_empty():
		return "无"
	var parts := PackedStringArray()
	for id in ids:
		parts.append(str(id))
	return ", ".join(parts)


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
