extends Node3D
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
## 生成位置沿一个圆均匀分布。槽位由服务端分配，因此不会出现两人重叠在同一个点。
const SPAWN_SLOTS := 6
const SPAWN_RADIUS := 4.0

@onready var _players: Node3D = $Players
@onready var _spawner: MultiplayerSpawner = $Players/Spawner
@onready var _status: Label = $HUD/Status

var _port: int = 0
var _notice: String = ""
## peer id 到槽位的对应，只在服务端维护。
var _slots: Dictionary = {}


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


func _slot_position(slot: int) -> Vector3:
	var angle := TAU * float(slot) / float(SPAWN_SLOTS)
	return Vector3(sin(angle) * SPAWN_RADIUS, 1.0, cos(angle) * SPAWN_RADIUS)


func _peer_node_name(id: int) -> String:
	return "p%d" % id


# ---------------------------------------------------------------- 状态显示

func _on_hosting_started(p_port: int) -> void:
	print("[session] %s，监听 UDP %d" % ["专用服务端" if Net.is_dedicated() else "主机", p_port])
	_refresh_status()


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
			lines.append("角色：%s，监听 UDP %d" % [kind, _port])
		Net.Role.CLIENT:
			lines.append("角色：客户端，已连接 UDP %d" % _port)
		_:
			lines.append("角色：尚未开始会话")
	lines.append("本机 peer id：%d    其他 peer：%s" % [Net.local_id(), _describe_peers()])
	lines.append("操作：WASD 移动，空格跳跃")
	if not _notice.is_empty():
		lines.append(_notice)
	_status.text = "\n".join(lines)


func _describe_peers() -> String:
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
