class_name Player
extends CharacterBody3D
## 玩家角色。
##
## 移动由本机权威判定：谁的角色谁模拟，因此操作手感与网络延迟无关。
## 这里是有意如此选择的——第 2 阶段的目标是验证双元素协同的手感，
## 若现在就让服务端模拟玩家移动，本地必须同时实现客户端预测与位置回滚，
## 那是 netfox 一类方案覆盖的范围（设计文档 4.3）。附带说明：一旦引入
## 需要服务端判定的内容（推箱、可旋转平台、机关），那些物体改成服务端权威，
## 届时玩家移动是否一并改为"上报输入 + 服务端模拟"要等网络损伤测试的结果再定。
##
## 视角是第一人称：相机挂在 Head 节点上，本机玩家看不到自己的身体，只看到置于胸前的手与武器。
## 因此本机角色的 Body 不渲染，而 ViewModel 反过来只在本机渲染——远端玩家的相机不在这个角色身上，
## 所以不需要额外的渲染层来分离视图模型（不像经典 FPS 那样要防穿墙）。
## 朝向拆成两个量分别同步：yaw 在角色节点上（身体朝哪，别人看得出来），
## pitch 在 Head 上（头抬多高），两者分开是因为它们是两条独立信息，
## 合在一起同步成一个 Vector3 会让远端无法区分「转身」与「点头」。
##
## 角色外观、武器模型与全部材质都在运行时构建（见 scripts/art/），而不是画在场景文件里：
## 美术要反复调整，参数化生成比在编辑器里拖着改更快，也不会因场景文件被编辑器重写而丢掉注释。
##
## 元素与死亡：元素由服务端分配，两种元素互为对方的致死地形（见 scripts/level/hazard_zone.gd）。
## 地形致死由**本机**判定并复位，理由与移动的权威归属相同——位置的事实就在本机；
## 机关（按钮与门）反过来由服务端判定，因为"两个人是否同时到位"这个事实只有服务端有。
##
## 远端角色的显示由 RemoteInterpolator 平滑：收到的位置快照先入缓冲，
## 再按显示帧在缓冲中取样。取样结果写到子节点 Visual 的局部偏移上，而不是写回 position——
## 节点的 position 始终保持收到的原值，因为 listen server 模式下它同时是权威判定所用的位置
##（机关同时触发这类判定会用到它），若把显示用的延迟位置写回去，判定就会跟着延后。
## 详见 scripts/net/remote_interpolator.gd 的说明。
##
## 两个平滑参数是本次会话的配置，由入口脚本在启动时从命令行写入（见 main.gd）。
## 它们必须对所有实例生效，而实例是运行时生成的，所以放在静态变量上；
## 每台机器各自从自己的命令行取值，因此两台机器可以分别调试而不必重启对方。

## 玩家节点所在的分组。出口核对「全部玩家是否都在范围内」时按分组取节点，
## 因此每个角色（含各端生成的远端副本）都必须加入：服务端要知道总共有几个人。
const GROUP_NAME := "player"

## 前进速度。第一人称下这个值比俯视视角小：视线离地一米六，同样的速度看起来快得多，
## 6 m/s 在俯视时像慢走，在这个视角里已经接近小跑。
const MOVE_SPEED := 4.4
const JUMP_VELOCITY := 5.0
const GRAVITY := 18.0
## 自动驾驶的路线：沿各自的出生 Z 坐标在 X 方向往返。
## 为什么不用固定的一条线：两个实例若走同一条线会直接撞在一起（实测过），
## 而各自的出生点分布在半径 4 的圆上、Z 坐标互不相同，因此各走一条、互不相碰。
## 同时避开场景里的台阶：台阶占 z ∈ [-5, -1]，而出生点的 Z 坐标在 ±4 以内不会落入该区间。## 自动驾驶的行程长度（米）：沿车道向 -Z 前进这么多再返回。
## 取值必须覆盖「同元素池 → 按钮 → 异元素池」整段路，否则自动检查验证不到两种判定。
const AUTOPILOT_RUN := 16.0
## 到达路点的判定距离。只会在两个端点短暂停下，不会周期性地出现。
const AUTOPILOT_ARRIVE := 0.5
## 第一人称视角的参数。
##
## 灵敏度单位是「弧度每像素」，0.0022 对应鼠标移动约 2850 像素转一整圈。
## 取值偏慢，是为了让解谜时的对准（对准池子边缘、对准机关的接收口）不至于手抖。
const MOUSE_SENSITIVITY := 0.0022
## 俯仰角上限。留出余量而不是正好 90 度：正好 90 度时视线方向与世界上方向平行，
## 相机的基础向量退化，画面在极限角度附近会抖动。
const PITCH_LIMIT := deg_to_rad(88.0)
## 远端角色朝向的平滑速率。朝向必须平滑：快照按网络帧到达，
## 直接把收到的角度赋给节点会让远处的角色一顿一顿地转头。
const TURN_SMOOTH := 14.0

## 武器摆动的参数。
## 走动摆动（bob）：按步伐节律上下左右轻微位移，幅度与速度成正比。
const BOB_RATE := 8.5
const BOB_SIDE := 0.020
const BOB_VERTICAL := 0.014
## 转身滞后（sway）：武器朝转身的反方向偏一点，幅度与角速度成正比。
## 这两样合起来是「手里有东西」的主要来源；完全静止的武器看起来像贴在屏幕上的贴图。
const SWAY_SCALE := 0.030
const SWAY_LIMIT := 0.055
## 摆动的回正速率。取值大则跟手，小则显得迟滞。
const SWAY_SMOOTH := 8.0
## 自动驾驶：让本机角色在两点之间往返移动。用于在不按键的情况下测量显示平滑，
## 也供自动检查核对位置同步确实在流动。由入口脚本按命令行开关写入。
static var autopilot: bool = false
## 自动驾驶的走走停停模式：交替运动与静止各一秒。
## 专门用于复现"对方开始移动时卡一下"这个场景——那个现象的触发条件正是静止→移动的转换。
static var autopilot_stop: bool = false
## 远端显示的水位。0 表示用 RemoteInterpolator 的默认值；
## 可用 --interp-buffer 临时覆盖，仅用于对照。
static var interp_buffer: float = 0.0

## 自动驾驶当前的朝向与所在车道，只在本机角色上有意义。
var _autopilot_forward: bool = true
## 车道取首次物理帧时的 X 坐标与起点 Z 坐标。取 X 是因为通道沿 Z 延伸，
## 自动驾驶要沿通道走——若沿 X 往返，角色会横穿两条通道之间的隔墙。
var _autopilot_lane_x: float = 0.0
var _autopilot_origin_z: float = 0.0
var _autopilot_lane_ready: bool = false

## 由 MultiplayerSpawner 的生成函数写入，各方取到的是同一个值。
var peer_id: int = 1

## 元素属性。由服务端在生成时按槽位分配（见 main.gd），随生成包送达。
## 不能由本机从 peer id 推导：客户端的 peer id 由引擎随机分配（见 memory/networking.md），
## 按它取奇偶会让两台机器随机得到同一个元素。
var element: int = Element.Kind.MOLTEN

## 视角朝向。yaw 是绕世界 Y 轴的转身角，pitch 是抬头角（正为向上）。
## 两者都参与同步（见 player.tscn 的复制配置）：第一人称下「对方转了多少度」
## 决定你看到他的身体与头朝向哪边，属于可见信息。
## 单位是弧度；yaw 不限范围（可无限旋转），pitch 夹在 ±PITCH_LIMIT。
var yaw: float = 0.0
var pitch: float = 0.0

## 出生点（相对 Players 节点），生成时记下。进入错误元素的地形之后回到这里。
var spawn_position: Vector3 = Vector3.ZERO

## 本机角色被复位的次数，供诊断确认判定确实生效。
var deaths: int = 0

## 第一人称武器节点，只在有显示的本机角色上存在。
var _weapon: Node3D = null
## 摆动用的累计时间，以及上一帧的视角（用于算角速度）。
var _bob_time: float = 0.0
var _last_yaw: float = 0.0
var _last_pitch: float = 0.0
## 当前的摆动偏移。逐帧平滑到目标值，而不是直接赋值：
## 鼠标的 relative 是离散采样，直接拿它算偏移会让武器跟着鼠标的采样噪声抖。
var _sway: Vector3 = Vector3.ZERO

## 判定"这份位置是一次瞬移而不是一段移动"的距离（米）。
## 复位会从池子直接回到出生点，跨度是米级；而正常同步的相邻两份位置，
## 即使链路最坏空档 350 ms、速度 6 m/s，也到不了 2.1 m。
const TELEPORT_DISTANCE := 3.0

## 远端角色被判定为瞬移的次数。它与 deaths 是同一件事的两个视角：
## 一端看到的是"我的角色被复位了"，另一端看到的是"他的位置突然跳了"。
var _teleports: int = 0
## 上一份位置，用于识别瞬移。
var _last_state: Vector3 = Vector3.ZERO
var _last_state_valid: bool = false
## 下一次记录位移时重建基准。复位是瞬移，把它记进"最大单帧位移"会把这个数字变成
## 两类完全不同的现象之和。
var _reset_step_baseline: bool = false

## 本机权威时刻（毫秒），随每次同步一起发出。
## 它的作用是让接收方能把位置快照排到发送方的时间轴上：
## 无线链路会把若干包成簇投递（实测成簇间隔约 100 ms），一簇里往往含好几份不同位置；
## 若接收方按"到达时刻"给它们打时间戳，它们会挤在同一时刻上，
## 于是在一帧内从簇内第一份跳到簇内最后一份，表现为"平稳一下、突然跳一下"。
## 用发送方的时刻打时间戳，一簇里 100 ms 的运动量就会被摊到 100 ms 的显示时间里。
## 只在物理帧更新：位置也只在物理帧变化，两者因此天然对齐。
var sync_time: int = 0

var _local: bool = false
## 仅在有显示且是非本机角色时创建。
var _interp: RemoteInterpolator = null
var _arrivals: int = 0
var _max_gap: float = 0.0
var _last_arrival: float = 0.0
## 显示的位移统计。
## 单帧最大位移是"看到的跳"的直接计量：
## 角色以 6 m/s 移动、120 帧显示时，平滑运动每帧只应前进 0.05 m；
## 若出现 0.5 m 量级，就是那一帧把积攒的运动量一次走完了。
## 本区间的第一个采样只用来建立基准，不参与比较（_has_prev）。
var _has_prev: bool = false
var _prev_sample: Vector3 = Vector3.ZERO
## 本区间内显示位置相对起点移动了多远，用来区分"角色本来就没动"与"显示被冻住"。
## 用显示位置而不是收到的位置，这样本机角色也能得到同一口径的数字。
var _step_origin: Vector3 = Vector3.ZERO
var _display_moved: float = 0.0
## 单帧最大位移。"平稳一下、突然跳一下"里的那个跳就是这个值的尖峰：
## 角色以 6 m/s 移动、120 帧显示时，平滑运动应只有 0.05 m；若出现 0.5 m 量级，就是跳。
var _step_max: float = 0.0
## 最大单帧位移发生时的上下文，用于判定它的成因：
## 看当时是否在保持、滞后多少、距上次收到新位置多久。
var _jump_context: String = "—"
## 本机角色的位置更新间隔。这是**发送方的基准**：
## 对方应该以同样的节奏收到我的位置变化；若对方报的"最大到达间隔"远大于这里的值，
## 就说明空档产生在链路上，而不是我这边的帧或物理卡顿。
var _wall: float = 0.0
var _last_change_wall: float = -1.0
var _change_count: int = 0
var _change_gap_max: float = 0.0
## 回拉检测。分别看"收到的位置序列"与"显示出来的位置序列"：
## 收到的那一路有回拉，说明发送方或传输层给了旧值；
## 只有显示那一路有回拉，则是本地平滑把它推过头又拉回。
## 判定细节见 scripts/net/step_analyzer.gd（它把"掉头"排除在外，只计真正的回拉）。
## 回拉检测，现在预期恒为 0——回拉的两个成因都已修掉（外推已移除，锚定改成只向前）。
## 保留它的理由是**回归守卫**：它是唯一能区分"网络给了旧值"与"本地平滑造成回拉"的手段，
## 一旦以后改动平滑逻辑又引入回拉，这两个数会立刻非零。判定细节见 scripts/net/step_analyzer.gd。
var _recv_dips: StepAnalyzer = StepAnalyzer.new()
var _disp_dips: StepAnalyzer = StepAnalyzer.new()

@onready var _visual: Node3D = $Visual
@onready var _body: Node3D = $Visual/Body
@onready var _head: Node3D = $Visual/Head
@onready var _camera: Camera3D = $Visual/Head/Camera
@onready var _view_model: Node3D = $Visual/Head/Camera/ViewModel
@onready var _sync: MultiplayerSynchronizer = $Sync


func _enter_tree() -> void:
	# 权限必须在这里设置，不能等到 _ready()。原因在引擎一侧：
	# 接收方会在远端生成包到达的同一帧里应用初始同步状态，而那一刻它要求节点的
	# 多人权限已经等于发起方（SceneReplicationInterface::on_replication_start 里有这个判断）。
	# 权限本身不随生成包传输，因此各端必须各自得到同一个值——
	# 这里用的是生成函数收到的 peer_id，各端由同一份数据推导，结论必然一致。
	set_multiplayer_authority(peer_id)


func _ready() -> void:
	# 生成函数已经在 add_child 之前把位置设成槽位坐标，所以此刻的 position 就是出生点。
	spawn_position = position
	_local = peer_id == multiplayer.get_unique_id()
	add_to_group(GROUP_NAME)
	_build_appearance()
	# 只有本机的角色参与模拟；显示帧则两边都要处理，本机用于视角与武器摆动，远端用于插值。
	set_physics_process(_local)
	set_process(true)
	_camera.current = _local
	_sync.synchronized.connect(_on_synchronized)
	# 鼠标锁定放在这里而不是会话开始时：角色是按 peer 逐个生成的，
	# 生成时刻晚于会话建立，而「本机是不是玩家」要到生成本机角色时才能确定。
	if _local:
		_capture_mouse()
	# 无头运行时没有画面，也就没有要平滑的对象；而且判定应当用收到的原值。
	# 所以插值只做在有显示的非本机角色上。
	if not _local and DisplayServer.get_name() != "headless":
		_interp = RemoteInterpolator.new()
		if interp_buffer > 0.0:
			# 显式指定水位时按固定值用，不再自适应（对照实验用）。
			_interp.buffer = interp_buffer
			_interp.adaptive = false
		# 这里**不**推初始快照。因为快照的时间戳用的是发送方的时刻，
		# 而此刻还没有收到过任何带时刻的同步包（生成包里刻意不带，见 player.tscn），
		# 用本机时刻先推一份就会把两个不同的时间轴混在一起，
		# 表现为缓冲被一次性推远、钟速长时间卡在上限。
		# 第一个同步包到达时自然会建立时间轴；在那之前 _process 直接用收到的位置显示。
	if _local:
		print("[player] 本机角色 peer=%d 已就位，元素=%s" % [peer_id, Element.label(element)])
	else:
		# 把生效方式写进日志，目的是让"本机跑的是不是这套平滑代码"一眼可查。
		print("[player] 远端角色 peer=%d 已就位（时钟调速平滑，水位 %.0f ms，元素=%s）" % [
			peer_id,
			(interp_buffer if interp_buffer > 0.0 else RemoteInterpolator.DEFAULT_BUFFER) * 1000.0,
			Element.label(element),
		])
		if _interp == null:
			print("[player] 本次无显示，不对 peer=%d 做平滑" % peer_id)


func _physics_process(delta: float) -> void:
	if _local:
		# 与位置同步更新，因此两者描述的是同一个时刻。
		sync_time = Time.get_ticks_msec()
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY

	var direction := _input_direction()
	if autopilot or autopilot_stop:
		# 沿车道向 -Z 走到头再返回。始终在动、方向固定，因此显示一旦冻结就能直接看出来。
		# 到达端点时必须“翻转后立即改向新路点”，不能把方向置零：置零会让角色留在到达半径内，
		# 下一帧又判定到达并再次翻转，于是永远卡在端点不动。
		if not _autopilot_lane_ready:
			# 首次物理帧记下车道，此后不再改变，避免角色在半途换线。
			_autopilot_lane_x = global_position.x
			_autopilot_origin_z = global_position.z
			_autopilot_lane_ready = true
		if autopilot_stop and int(Time.get_ticks_msec() / 1000) % 2 == 1:
			# 走走停停模式：奇数秒完全静止（与真人松手时一样）。
			direction = Vector3.ZERO
		else:
			var target := _autopilot_target()
			var to_target := target - global_position
			to_target.y = 0.0
			if to_target.length() < AUTOPILOT_ARRIVE:
				_autopilot_forward = not _autopilot_forward
				target = _autopilot_target()
				to_target = target - global_position
				to_target.y = 0.0
			direction = to_target.normalized()
			# 面向行进方向。推导：rotation.y = θ 时角色前方 = basis * (0,0,-1) = (-sinθ, 0, -cosθ)，
			# 要它等于 (direction.x, direction.z)，则 θ = atan2(-direction.x, -direction.z)。
			# 第一人称下必须转身：不转的话画面会变成横着平移，而横移不是人走路的样子。
			yaw = atan2(-direction.x, -direction.z)
	velocity.x = direction.x * MOVE_SPEED
	velocity.z = direction.z * MOVE_SPEED
	move_and_slide()


func _autopilot_target() -> Vector3:
	var z := _autopilot_origin_z - (AUTOPILOT_RUN if _autopilot_forward else 0.0)
	return Vector3(_autopilot_lane_x, 0.0, z)


## 键盘输入换算出的世界方向（水平单位向量）。
## 只用 transform.basis：它只含 yaw（pitch 在 Head 上），因此抬头看天时按前进不会往上飞。
func _input_direction() -> Vector3:
	var raw := Vector3(
		Input.get_axis("move_left", "move_right"),
		0.0,
		Input.get_axis("move_forward", "move_back"),
	)
	var world := transform.basis * raw
	world.y = 0.0
	return world.normalized() if world.length_squared() > 0.0 else Vector3.ZERO


func _process(delta: float) -> void:
	_wall += delta
	var displayed := global_position
	if not _local:
		# 显示帧里推进平滑时钟。同步包在 multiplayer.poll() 阶段已经应用并已入缓冲，
		# 而 poll 发生在节点 _process 之前，因此当帧收到的新位置当帧就会被用到。
		if _interp != null and _interp.has_state():
			# 只改视觉子节点的偏移，position 仍是收到的原值。
			displayed = _interp.advance(delta)
			_visual.position = displayed - position
		else:
			# 没有可插值的区间（首个快照之前，或刚被判定为瞬移之后）：直接显示收到的位置。
			# 此时偏移必须归零，否则会留着上一段平滑的偏移量，瞬移之后网格会错开一小段。
			displayed = position
			_visual.position = Vector3.ZERO
		_apply_remote_orientation(delta)
	else:
		# 本机角色自己就是相机所在的节点，不需要任何跟随逻辑：
		# 相机是 Head 的子节点，位置与朝向由节点层级自动得到。
		# 这里只把鼠标输入得到的角度应用到节点上，再更新武器摆动。
		rotation.y = yaw
		_head.rotation.x = pitch
		_update_view_model(delta)
	_record_step(displayed)


## 远端角色的朝向。同步来的角度是按网络帧跳变的，
## 直接赋给节点会让远处的角色一顿一顿地转头，而转身恰恰是最容易被眼睛捕捉到的运动。
func _apply_remote_orientation(delta: float) -> void:
	var t := 1.0 - exp(-TURN_SMOOTH * delta)
	# 角度必须用 lerp_angle 而不是 lerpf：yaw 可以无限累积（转很多圈），
	# 线性插值会沿着累积值走最远的那条路，表现为角色突然反向甩头。
	rotation.y = lerp_angle(rotation.y, yaw, t)
	_head.rotation.x = lerpf(_head.rotation.x, pitch, t)


## 鼠标视角。用 _unhandled_input 而不是 _input：
## 菜单、调试面板一类需要鼠标的界面会先把事件消费掉，视角因此自动停止响应，
## 不需要额外的状态判断。
func _unhandled_input(event: InputEvent) -> void:
	if not _local:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * MOUSE_SENSITIVITY
		# 鼠标下移时 relative.y 为正，视角应当向下，所以是减。
		pitch = clampf(pitch - event.relative.y * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		return
	if event.is_action_pressed("ui_cancel"):
		# 松开鼠标但不停止游戏：调试与试玩时要随时能把焦点交给别的窗口。
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	# 点击画面重新锁定。限定左键，避免右键菜单一类操作也被当成锁定请求。
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_capture_mouse()


## 锁定鼠标。桌面端不需要用户手势即可锁定（见设计文档 4.1）。
## 但无头运行时没有窗口，锁定会失败并打印警告，所以先判断。
func _capture_mouse() -> void:
	if DisplayServer.get_name() == "headless":
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## 武器与双手的摆动。
## 走动摆动按速度缩放，因此站着不动时不会晃——静止的晃动会让人误认为自己在移动。
## 转身滞后按角速度缩放，所以缓慢转向时几乎看不出来，快速转身时才有明显的拖拽感。
func _update_view_model(delta: float) -> void:
	if _weapon == null:
		return
	_bob_time += delta
	var speed_ratio := clampf(Vector2(velocity.x, velocity.z).length() / maxf(MOVE_SPEED, 0.1), 0.0, 1.0)
	var bob := Vector3(
		sin(_bob_time * BOB_RATE) * BOB_SIDE * speed_ratio,
		absf(sin(_bob_time * BOB_RATE * 2.0)) * BOB_VERTICAL * speed_ratio,
		0.0,
	)
	# 角速度用角度差除以帧长得到；帧长可能为 0（同一帧多次调用），因此限一个下限。
	var safe_delta := maxf(delta, 0.0001)
	var yaw_rate := wrapf(yaw - _last_yaw, -PI, PI) / safe_delta
	var pitch_rate := (pitch - _last_pitch) / safe_delta
	_last_yaw = yaw
	_last_pitch = pitch
	var target_sway := Vector3(
		clampf(-yaw_rate * SWAY_SCALE, -SWAY_LIMIT, SWAY_LIMIT),
		clampf(pitch_rate * SWAY_SCALE, -SWAY_LIMIT, SWAY_LIMIT),
		0.0,
	)
	_sway = _sway.lerp(target_sway, 1.0 - exp(-SWAY_SMOOTH * delta))
	_view_model.position = bob + _sway


## 统计显示帧之间位置有没有变化与有没有倒退。对两边的角色都做，因为成因不同：
## 本机角色若停在大量帧上不动，说明物理帧率低于显示帧率（与网络无关）；
## 远端角色若如此，则说明平滑未能拿到可用的区间。
func _record_step(displayed: Vector3) -> void:
	if _reset_step_baseline:
		# 上一次采样到的是另一处位置（复位瞬移），两者之间的位移没有意义：
		# 它既不是"跳"也不是运动。下一段重新建立基准。
		_reset_step_baseline = false
		_has_prev = false
	if not _has_prev:
		# 本区间的第一个采样：只建立基准，不参与最大值与变化计数的比较。
		_has_prev = true
		_step_origin = displayed
	else:
		var step := _prev_sample.distance_to(displayed)
		if step > _step_max:
			_step_max = step
			_jump_context = _describe_context(step)
		if step > 0.0:
			# 位置发生了变化。记录与上一次变化的间隔，作为"本机实际发出新值的节奏"。
			if _last_change_wall >= 0.0:
				_change_gap_max = maxf(_change_gap_max, _wall - _last_change_wall)
			_last_change_wall = _wall
			_change_count += 1
	_disp_dips.add(displayed)
	_prev_sample = displayed
	_display_moved = maxf(_display_moved, _step_origin.distance_to(displayed))


## 每收到一个位置快照就会被调用。此时 synchronizer 已经写入了新位置。
func _on_synchronized() -> void:
	var now := _now()
	if _interp != null:
		# 位置跳变超过阈值时判定为瞬移（对端进入错误地形后被复位）。
		# 若照常当成一段位移插值，画面会从池子一路滑回出生点，而途中的位置从未发生过。
		# 这里只看收到的原值，不受显示平滑影响。
		if _last_state_valid and position.distance_to(_last_state) > TELEPORT_DISTANCE:
			_interp.clear()
			_reset_step_baseline = true
			_teleports += 1
		# 用发送方的时刻，而不是本地接收时刻——原因见 sync_time 的说明。
		# 额外的 now（本地墙钟）只用于让插值器估出链路把若干份攒到一次投递的空档，
		# 因为那种空档在发送方时间戳里看不出来。
		_interp.push(position, float(sync_time) / 1000.0, now)
	_last_state = position
	_last_state_valid = true
	if _last_arrival > 0.0:
		_max_gap = maxf(_max_gap, now - _last_arrival)
	_last_arrival = now
	_arrivals += 1
	_recv_dips.add(position)


func is_local() -> bool:
	return _local


## 进入错误元素的地形：回到出生点。
## hazard 是地形名，只用于日志——判定由 HazardZone 做，它自己更清楚自己是什么地形。
func die(hazard: String) -> void:
	deaths += 1
	print("[player] peer=%d %s 角色进入「%s」，回到出生点（第 %d 次）" % [
		peer_id, Element.label(element), hazard, deaths,
	])
	respawn()


## 复位。位置由本机改写，随后经位置同步传播给其余端——复位与移动的权威归属一致，
## 都是角色自己那台机器（见文件头）。其余端在 _on_synchronized 里把这次跳变识别为瞬移。
func respawn() -> void:
	velocity = Vector3.ZERO
	position = spawn_position
	_reset_step_baseline = true
	_last_state = position
	_last_state_valid = true


## 当前使用的显示水位（秒）。供 main.gd 估算显示滞后。
func reported_buffer_seconds() -> float:
	if _interp != null:
		return _interp.buffer_seconds()
	return interp_buffer if interp_buffer > 0.0 else RemoteInterpolator.DEFAULT_BUFFER


## 最近是否仍在收到位置更新。总览的显示滞后只统计这类角色：
## 从未移动的角色不会产生水位样本，它的水位停在初始值上、不代表链路。
func is_receiving_motion() -> bool:
	return _interp != null and _interp.seconds_since_unique() < RemoteInterpolator.FLOWING_WINDOW


## 取统计并清零，供 main.gd 定时输出。
## duplicated_ratio 高说明发送方物理帧率低于显示帧率（已由丢弃逻辑自动处理）；
## hold_ratio 高说明缓冲被追平、显示在等新数据，它直接对应人看到的"卡一下"。
func report_stats_and_reset() -> Dictionary:
	var stats := {
		"arrivals": _arrivals,
		"max_gap_ms": _max_gap * 1000.0,
		"duplicated_ratio": 0.0,
		"step_max": _step_max,
		"jump_context": _jump_context,
		"moved": _display_moved,
		"change_count": _change_count,
		"change_gap_max_ms": _change_gap_max * 1000.0,
		"deaths": deaths,
		"teleports": _teleports,
	}
	var recv := _recv_dips.take()
	var disp := _disp_dips.take()
	stats["recv_dips"] = recv["dips"]
	stats["recv_dip_max"] = recv["max_dip"]
	stats["disp_dips"] = disp["dips"]
	stats["disp_dip_max"] = disp["max_dip"]
	stats["hold_ratio"] = 0.0
	stats["buffer"] = 0.0
	stats["fill"] = 0.0
	stats["rate"] = 1.0
	stats["worst_gap"] = 0.0
	stats["link_floor"] = 0.0
	stats["stall_penalty"] = 0.0
	if _interp != null:
		var sample := _interp.sample_stats()
		stats["duplicated_ratio"] = sample["duplicated_ratio"]
		stats["hold_ratio"] = sample["hold_ratio"]
		stats["buffer"] = sample["buffer"]
		stats["fill"] = sample["fill"]
		stats["rate"] = sample["rate"]
		stats["worst_gap"] = _interp.worst_gap()
		stats["link_floor"] = _interp.link_floor_seconds()
		stats["stall_penalty"] = _interp.stall_penalty_seconds()
	_arrivals = 0
	_max_gap = 0.0
	_has_prev = false
	_step_max = 0.0
	_jump_context = "—"
	_display_moved = 0.0
	_change_count = 0
	_change_gap_max = 0.0
	_last_change_wall = -1.0
	return stats


func _now() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0


## 描述最大单帧位移发生时的状态，用于判定跳跃成因。只在刷新纪录时调用，不会产生日志噪声。
func _describe_context(step: float) -> String:
	if _interp == null:
		return "%.2f m（无平滑）" % step
	return "%.2f m 当时：滞后 %.0f/%.0f ms 钟速 %.2f 保持=%s 距新位置 %.0f ms" % [
		step,
		_interp.fill_seconds() * 1000.0,
		_interp.buffer_seconds() * 1000.0,
		_interp.rate(),
		"是" if _interp.is_holding() else "否",
		_interp.seconds_since_unique() * 1000.0,
	]


## 构建角色的可见部分。两套造型共用同一套几何，只有发光色不同。
func _build_appearance() -> void:
	# 本机角色不渲染身体：相机就在它的头内部，渲染出来的只会是挡住视线的内壁。
	_body.visible = not _local
	if not _local:
		CharacterRig.build(_body, element)
	# 视图模型反过来：只有本机需要，因为它是「贴着相机」的手与武器。
	# 远端玩家的相机不在这个角色身上，所以不必用渲染层分离。
	_view_model.visible = _local
	if not _local:
		return
	# 无头运行时没有画面，构建几何只是浪费内存。
	if DisplayServer.get_name() == "headless":
		return
	CharacterRig.build_hands(_view_model, element)
	_weapon = WeaponModel.build(_view_model, element)
	_last_yaw = yaw
	_last_pitch = pitch
