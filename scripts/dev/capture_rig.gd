class_name CaptureRig
extends Node
## 开发期截图工具：把本机相机移到若干预设位置，逐个保存 PNG。
##
## 为什么需要它：无头自检只能验证「有没有报错」，而这次改动的重点是美术与第一人称构图，
## 那类问题（曝光过头、灯带把墙洗白、武器挡住视野、走廊看起来比实际窄）
## 只有看到画面才能判断。让编辑器开着看也可以，但换一个参数就要重新走一遍，
## 而这个工具把「改参数 → 看画面」压成一条命令。
##
## 只在命令行传 --capture 时创建，正式运行不会执行。
## 用法：& <godot> --path <项目> -- --port 0 --capture

## 每个预设位置等多少帧再截。取值偏大是有原因的：
## 环境光遮蔽与时间抗锯齿都要累积若干帧才收敛，截得太早画面会比实际暗且糊。
const SETTLE_FRAMES := 24
## 整体超时（秒）。没有它，任何一步失败都会让游戏窗口一直开着、终端也被占住，
## 而日志里只看得到正常启动的几行（实测就是这个坑：参数没被解析到）。
const GUARD_SECONDS := 60.0
## 相机相对角色脚底的高度，与 player.tscn 的 Head 节点一致。
const HEAD_HEIGHT := 1.62

## 预设机位。height 是相机相对地面的高度，默认取站立时眼睛的高度。
## yaw 为 0 表示面朝 -Z（通道的北向），pitch 为负表示低头；overview 一张另给高度。
const SHOTS := [
	{
		"name": "01_spawn",
		"note": "出生点朝通道内看",
		"position": Vector3(-5.0, 0.0, 13.0),
		"yaw": 0.0, "pitch": 0.0,
	},
	{
		"name": "02_weapon",
		"note": "同位置低头看武器与双手（此图需要玩家的视图模型，见 _run_world）",
		"position": Vector3(-5.0, 0.0, 13.0),
		"yaw": 0.0, "pitch": deg_to_rad(-24.0),
		"play": true,
	},
	{
		"name": "03_safe_pool",
		"note": "同元素池前：可通行地形",
		"position": Vector3(-5.0, 0.0, 13.4),
		"yaw": 0.0, "pitch": deg_to_rad(-16.0),
	},
	{
		"name": "04_deadly_pool",
		"note": "异元素池前：致命地形",
		"position": Vector3(-5.0, 0.0, 4.4),
		"yaw": 0.0, "pitch": deg_to_rad(-12.0),
	},
	{
		"name": "05_button",
		"note": "按钮前的低角度：看踏板与灯带",
		"position": Vector3(-5.0, 0.0, 8.6),
		"yaw": 0.0, "pitch": deg_to_rad(-8.0),
	},
	{
		"name": "06_gate",
		"note": "左侧通道内正对机关门",
		"position": Vector3(-1.6, 0.0, -1.0),
		"yaw": 0.0, "pitch": 0.0,
	},
	{
		"name": "07_exit",
		"note": "门后的出口",
		"position": Vector3(0.0, 0.9, -8.0),
		"yaw": 0.0, "pitch": 0.0,
	},
	{
		"name": "08_overview",
		"note": "高处的整体俯视：检查房间比例与灯的分布",
		"position": Vector3(0.0, 6.0, 13.0),
		"yaw": 0.0, "pitch": deg_to_rad(-35.0),
		"height": 0.0,
	},
]

var _output_dir: String = ""
## 是否已完成。超时保护靠它判断，避免与正常退出竞争。
var _finished: bool = false
## 取景目标：world（预设机位）或 remote（对准另一个玩家）。
var _focus: String = "world"
## 本机角色。截图期间要把它自己的相机停用、并把它的武器模型藏起来。
var _player: Player = null
## 截图专用的自由相机。
##
## 为什么不用角色自带的相机：角色是 CharacterBody3D，相机挂在它身上，
## 因此机位会被重力与碰撞带动——实测把角色放在某个坐标后，物理帧会把它挤开或让它下落，
## 截出来的机位与预设对不上（拍对端角色时整张图都是背面一面墙）。
## 自由相机不属于任何物理体，位置完全可控。
var _camera: Camera3D = null
## remote 模式下要等多久才放弃等待对端角色（秒）。
const REMOTE_WAIT := 20.0
## remote 模式的机位：相对目标脚底的水平偏移，以及矄准的高度（米）。
## 偏移用 (x, z) 两个分量；相机高度统一取站立时的眼睛高度。
const REMOTE_SHOTS := [
	{ "name": "r1_front", "note": "正前方全身", "offset": Vector2(0.0, 3.6), "aim_y": 0.95 },
	{ "name": "r2_three_quarter", "note": "斜前方三刻面", "offset": Vector2(2.6, 2.6), "aim_y": 1.05 },
	{ "name": "r3_upper", "note": "上半身近景", "offset": Vector2(1.0, 2.0), "aim_y": 1.40 },
	{ "name": "r4_back", "note": "背后看能量核心", "offset": Vector2(-1.8, -2.8), "aim_y": 1.15 },
]


## 入口。player 是本机角色，focus 决定取景目标。
func start(output_dir: String, player: Player, focus: String = "world") -> void:
	_output_dir = output_dir
	_focus = focus
	_player = player
	# 接管画面：自由相机要成为当前相机，否则截到的是角色相机看到的画面。
	_camera = Camera3D.new()
	_camera.name = "CaptureCamera"
	_camera.fov = 62.0
	_camera.near = 0.05
	_camera.far = 400.0
	add_child(_camera)
	_camera.current = true
	# 超时保护：定好时间后就让主流程自己跑，超时未完成则直接退出并报错。
	var guard := get_tree().create_timer(GUARD_SECONDS + (REMOTE_WAIT if focus == "remote" else 0.0))
	guard.timeout.connect(_on_guard_timeout)
	_run(player)


func _on_guard_timeout() -> void:
	if _finished:
		return
	push_error("截图在限定时间内没有完成，已中止。检查是否传了 --capture，且是否带了显示（headless 没有画面）。")
	get_tree().quit(1)


func _run(player: Player) -> void:
	await get_tree().physics_frame
	if _focus == "remote":
		await _run_remote(player)
	else:
		await _run_world()
	_finished = true
	get_tree().quit()


func _run_world() -> void:
	DirAccess.make_dir_recursive_absolute(_output_dir)
	for shot in SHOTS:
		# play 为真时用角色自己的相机与武器模型（只有「低头看武器」那张需要）；
		# 其余张用自由相机，以获得固定无误的机位。
		var use_player: bool = shot.get("play", false)
		if use_player:
			_player.velocity = Vector3.ZERO
			_player.position = shot["position"] + Vector3.UP * shot["position"].y
			_player.yaw = shot["yaw"]
			_player.pitch = shot["pitch"]
			_player.get_node("Visual/Head/Camera").current = true
		else:
			# height 缺省是站立时的眼睛高度。
			var height := float(shot.get("height", HEAD_HEIGHT))
			_camera.position = Vector3(shot["position"].x, shot["position"].y + height, shot["position"].z)
			_camera.rotation = Vector3(shot["pitch"], shot["yaw"], 0.0)
			_camera.current = true
		for i in SETTLE_FRAMES:
			await get_tree().process_frame
		# 必须等这一帧画完再取纹理，否则拿到的是上一帧的画面
		#（那时相机还停在旧位置，截出来的图会与预设差一个机位）。
		await RenderingServer.frame_post_draw
		_save(shot["name"], shot["note"])
	print("[capture] 共 %d 张，取景=world，输出目录：%s" % [SHOTS.size(), _output_dir])


## 对准另一个玩家的角色。
##
## 为什么需要这个模式：第一人称看不到自己的身体，所以「角色造型好不好」这件事
## 无法从本机截图里判断。它只能在**看得到对端角色的那一端**拍——也就是主机，
## 客户端用无头实例（它的角色会同步过来，但它自己不渲染）。
## 配套的驱动脚本是 tools/capture-remote.mjs。
##
## 还耍隐藏本机的武器与双手：它们挂在相机的子节点上，会随相机一起出现在每一张图里，
## 而这几张图要看的是对端角色。
func _run_remote(player: Player) -> void:
	var target := await _await_remote_player()
	if target == null:
		push_error("remote 取景失败：%.0f 秒内没有出现对端角色。需要用两个实例（见 tools/capture-remote.mjs）。" % REMOTE_WAIT)
		get_tree().quit(1)
		return
	var view_model := player.get_node_or_null("Visual/Head/Camera/ViewModel")
	if view_model != null:
		view_model.visible = false
	# 取景对象取 Visual 子节点而不是角色根节点：
	# 远端角色的根节点位置是**收到的原始位置**，而实际渲染的身体在 Visual 上，
	# 两者相差一个插值偏移（最多一个水位，实测可达一米量级）。
	# 对准根节点时，快速移动的对端会拍到空场景（实测踩过）。
	var visual := target.get_node_or_null("Visual") as Node3D
	var frame_node: Node3D = visual if visual != null else target
	DirAccess.make_dir_recursive_absolute(_output_dir)
	for shot in REMOTE_SHOTS:
		var target_point := Vector3.ZERO
		for i in SETTLE_FRAMES:
			# 目标在移动，每帧都重新取它的位置并重新构机位，直到截图那一帧为止。
			var base: Vector3 = frame_node.global_position
			target_point = base + Vector3.UP * float(shot["aim_y"])
			_camera.position = Vector3(base.x + shot["offset"].x,
				base.y + HEAD_HEIGHT, base.z + shot["offset"].y)
			_aim_camera(target_point)
			if i == SETTLE_FRAMES - 1:
				print("[capture] %s 对端根=%v 渲染=%v 机位=%v 看=%v" % [
					shot["name"], target.global_position, base,
					_camera.global_position, target_point,
				])
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		_save(shot["name"], shot["note"])
	print("[capture] 共 %d 张，取景=remote（对端 peer=%d，元素=%s），输出目录：%s" % [
		REMOTE_SHOTS.size(), target.peer_id, Element.label(target.element), _output_dir,
	])


## 等对端角色出现。它就是分组里第一个非本机角色。
func _await_remote_player() -> Player:
	var deadline := Time.get_ticks_msec() + int(REMOTE_WAIT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		for node in get_tree().get_nodes_in_group(Player.GROUP_NAME):
			var candidate := node as Player
			if candidate != null and not candidate.is_local():
				return candidate
		await get_tree().process_frame
	return null


## 把自由相机转向某点。
##
## 推导：设 yaw = y、pitch = p，则视线方向
##   forward = (-sin y · cos p,  sin p,  -cos y · cos p)
## 令它等于目标方向 d（单位向量），则 p = asin(d.y)、y = atan2(-d.x, -d.z)。
## 这里不用更短的 look_at：look_at 会在方向与世界上方向平行时退化，
## 而这张表里有俯视的机位，正需要可靠的极限角度行为。
func _aim_camera(point: Vector3) -> void:
	var dir := point - _camera.global_position
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	_camera.rotation = Vector3(asin(clampf(dir.y, -1.0, 1.0)), atan2(-dir.x, -dir.z), 0.0)


func _save(shot_name: String, note: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_output_dir, shot_name]
	var err := image.save_png(path)
	if err != OK:
		push_error("截图保存失败：%s（错误码 %d）" % [path, err])
	else:
		print("[capture] %s —— %s" % [shot_name, note])
