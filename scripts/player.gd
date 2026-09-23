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
## 角色本身是胶囊体，绕 Y 轴旋转不可见，所以当前只同步位置。
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

const MOVE_SPEED := 6.0
const JUMP_VELOCITY := 5.0
const GRAVITY := 18.0
## 自动驾驶的路线：沿各自的出生 Z 坐标在 X 方向往返。
## 为什么不用固定的一条线：两个实例若走同一条线会直接撞在一起（实测过），
## 而各自的出生点分布在半径 4 的圆上、Z 坐标互不相同，因此各走一条、互不相碰。
## 同时避开场景里的台阶：台阶占 z ∈ [-5, -1]，而出生点的 Z 坐标在 ±4 以内不会落入该区间。
const AUTOPILOT_END := 7.5
## 判定到达路点的距离。只会在两个端点短暂停下，不会周期性地出现。
const AUTOPILOT_ARRIVE := 0.5
## 相机相对角色的固定偏移。相机设了 top_level，因而它不随角色旋转，
## 角色加上转动之后也不需要在这里做补偿。
const CAMERA_OFFSET := Vector3(0.0, 9.0, 9.0)
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
## 车道取首次物理帧时的 Z 坐标，也就是出生点所在的圈。
var _autopilot_lane_z: float = 0.0
var _autopilot_lane_ready: bool = false

## 仅用于双人测试时分清谁是谁，正式的角色美术与元素表现另做。
const MOLTEN_COLOR := Color(1.0, 0.42, 0.12)
const FROST_COLOR := Color(0.36, 0.82, 0.98)

## 由 MultiplayerSpawner 的生成函数写入，各方取到的是同一个值。
var peer_id: int = 1

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

@onready var _mesh: MeshInstance3D = $Visual/Mesh
@onready var _visual: Node3D = $Visual
@onready var _camera: Camera3D = $Camera
@onready var _sync: MultiplayerSynchronizer = $Sync


func _enter_tree() -> void:
	# 权限必须在这里设置，不能等到 _ready()。原因在引擎一侧：
	# 接收方会在远端生成包到达的同一帧里应用初始同步状态，而那一刻它要求节点的
	# 多人权限已经等于发起方（SceneReplicationInterface::on_replication_start 里有这个判断）。
	# 权限本身不随生成包传输，因此各端必须各自得到同一个值——
	# 这里用的是生成函数收到的 peer_id，各端由同一份数据推导，结论必然一致。
	set_multiplayer_authority(peer_id)


func _ready() -> void:
	_local = peer_id == multiplayer.get_unique_id()
	_apply_element_color()
	# 只有本机的角色参与模拟；显示帧则两边都要处理，本机用于相机跟随，远端用于插值。
	set_physics_process(_local)
	set_process(true)
	_camera.current = _local
	_sync.synchronized.connect(_on_synchronized)
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
		print("[player] 本机角色 peer=%d 已就位" % peer_id)
	else:
		# 把生效方式写进日志，目的是让"本机跑的是不是这套平滑代码"一眼可查。
		print("[player] 远端角色 peer=%d 已就位（时钟调速平滑，水位 %.0f ms）" % [
			peer_id,
			(interp_buffer if interp_buffer > 0.0 else RemoteInterpolator.DEFAULT_BUFFER) * 1000.0,
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

	var direction := Vector3(
		Input.get_axis("move_left", "move_right"),
		0.0,
		Input.get_axis("move_forward", "move_back"),
	)
	if autopilot or autopilot_stop:
		# 沿各自的出生 Z 坐标在 X 方向往返。始终在动、方向固定，因此显示一旦冻结就能直接看出来。
		# 到达端点时必须"翻转后立即改向新路点"，不能把方向置零：置零会让角色留在到达半径内，
		# 下一帧又判定到达并再次翻转，于是永远卡在端点不动。
		if not _autopilot_lane_ready:
			# 首次物理帧记录车道，此后不再改变，避免角色在半途换线。
			_autopilot_lane_z = global_position.z
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
	velocity.x = direction.x * MOVE_SPEED
	velocity.z = direction.z * MOVE_SPEED
	move_and_slide()


func _autopilot_target() -> Vector3:
	return Vector3(AUTOPILOT_END if _autopilot_forward else -AUTOPILOT_END, 0.0, _autopilot_lane_z)


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
			displayed = position
	else:
		# 相机用全局坐标定位，所以它只跟随角色的位置，不跟随角色的转动。
		_camera.global_position = global_position + CAMERA_OFFSET
		_camera.look_at(global_position + Vector3.UP * 1.2, Vector3.UP)
	_record_step(displayed)


## 统计显示帧之间位置有没有变化与有没有倒退。对两边的角色都做，因为成因不同：
## 本机角色若停在大量帧上不动，说明物理帧率低于显示帧率（与网络无关）；
## 远端角色若如此，则说明平滑未能拿到可用的区间。
func _record_step(displayed: Vector3) -> void:
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
		# 用发送方的时刻，而不是本地接收时刻——原因见 sync_time 的说明。
		# 额外的 now（本地墙钟）只用于让插值器估出链路把若干份攒到一次投递的空档，
		# 因为那种空档在发送方时间戳里看不出来。
		_interp.push(position, float(sync_time) / 1000.0, now)
	if _last_arrival > 0.0:
		_max_gap = maxf(_max_gap, now - _last_arrival)
	_last_arrival = now
	_arrivals += 1
	_recv_dips.add(position)


func is_local() -> bool:
	return _local


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


func _apply_element_color() -> void:
	var material := StandardMaterial3D.new()
	# 一号位是「熔」，其余是「霜」。每个实例各建一份材质，避免相互影响。
	material.albedo_color = MOLTEN_COLOR if peer_id == 1 else FROST_COLOR
	_mesh.material_override = material
