class_name Player
extends CharacterBody2D
## 玩家角色（2D 横版）。
##
## 移动由本机权威判定：谁的角色谁模拟，因此操作手感与网络延迟无关。
## 这里是有意如此选择的——第 2 阶段的目标是验证双元素协同的手感，
## 若现在就让服务端模拟玩家移动，本地必须同时实现客户端预测与位置回滚，
## 那是 netfox 一类方案覆盖的范围（设计文档 4.3）。附带说明：一旦引入
## 需要服务端判定的内容（推箱、可移动平台、机关），那些物体改成服务端权威，
## 届时玩家移动是否一并改为"上报输入 + 服务端模拟"要等网络损伤测试的结果再定。
##
## 单位是像素。3D 版用"米"，而 2D 里位置与速度本身就是像素量，
## 再套一层米与像素的换算会让每个常量都要乘一次系数，多一层就多一次漏乘的机会，
## 因此这里全部直接用像素，并以 64 px 作为关卡的一个方格。
## move_speed / jump_velocity / gravity 是手感数值，不是物理量，因此由人试玩后定
##（AGENTS.md 交付前自检一节）。三个值都可用命令行临时覆盖（见 main.gd 的启动参数），
## 这样能在一个会话里不动代码地扫几组取值；推算式写在三个变量各自的注释里。
## 2026-09-26 按"想要快节奏、移动偏慢"的试玩反馈调过一次，取值变化写在各自的注释里。
##
## 角色不旋转，所以相机就是它的一个固定偏移子节点，不需要逐帧写位置：
## 2D 横版没有"角色转向带动相机"这件事，Camera2D 的局部 position 就等于世界偏移。
## 偏移写在场景里（见 scenes/player.tscn），这里不重复一份。
## 若以后给角色加了旋转（例如受击翻滚），相机就得改为 top_level 并逐帧赋值。
##
## 角色只占第 2 层碰撞层、掩码只含第 1 层（世界），因此两人互不碰撞。
## 一半是玩法选择：本项目是协作解谜而不是对打，互相挡住只会变成事故现场。
## 另一半是技术考虑：双方位置都是本机权威的，若两人还互相碰撞，
## 各自都会被对方那份已经过时的位置往外推，凭空多出一类抖动。
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
##
## 关于元素与死亡（见 docs/机制与玩法设计.md 2.1、2.2、2.5）：
##   element 由服务端在生成时写入，之后只在**交换角色**时由服务端改。
##   它单独用一个 MultiplayerSynchronizer（场景里的 ElementSync，权威固定为服务端），
##   而不是挤进主 Sync：主 Sync 的权威是各自那个 peer（位置必须如此），
##   而元素是服务端说了算的，两者混在一个同步器里会让服务端改不动它。
##
##   "踩到致命介质"这条路走的是**本机判定、上报服务端**：判定用的脚点位置是我自己
##   模拟出来的，走服务端就要每帧一个来回。表现上也是先死了再说，不等回话。
##   判定几何在 Game._check_hazard，因为那里同时拿着关卡与规则表。
##
##   技能与交换角色只发请求（Game.use_skill / request_swap），
##   世界变化一律由服务端执行后广播——造出来的冰两端必须落在同一个位置。

## 元素。取值见 Element.Kind。服务端权威，见上面的说明。
var element: int = Element.Kind.MOLTEN
## 出生槽位。由生成参数带过来，关卡重开时用它决定从哪里开始。
var spawn_slot: int = 0

## 水平移动速度（px/s）。2026-09-26 两次上调：220 → 360 → 480，
## 按 64 px 一方格即 3.4 → 5.6 → 7.5 格/秒。
## 注意它不带动跳跃：滞空由重力与起跳初速决定，与水平速度无关，
## 因此速度一提高，**同一个跳跃的水平跨度会跟着变大**（= move_speed × 滞空），
## 关卡沟宽要按这个值重算，实测值见下面 gravity 的注释。可用 `--move-speed` 覆盖。
static var move_speed := 480.0
## 起跳初速度（px/s），向上为负。跳跃高度 = jump_velocity² / (2 × gravity)，详见下面 gravity 的说明。
## 可用 `--jump-velocity` 覆盖。
static var jump_velocity := 1160.0
## 重力加速度（px/s²）。CharacterBody2D 的竖直速度由本脚本驱动，
## 因此这里用自己的常量，而不是 physics/2d/default_gravity（那个默认 980，是按“米”的直觉定的）。
## 解析式：高度 = jump_velocity² / (2 × gravity)，滞空 = 2 × jump_velocity / gravity，
## 跳跃的水平跨度 = move_speed × 滞空（跟水平速度一起变，是个组合量，
## 所以关卡沟宽不要单独看这个或那个，要两个一起算）。
## 解析值：高 160 px（2.5 格）、滞空 0.552 s、跨度 265 px（4.1 格）。
## **实测值比解析值高约一成：高 170 px、滞空 0.600 s、跨度 288 px（4.5 格）。**
## 差额来自离散积分（见下），因此**关卡沟宽要按实测值算**，
## 按解析值设计会少留约一成余量，手感上表现为“看起来过得去但偶尔撞边”。
## 上一组 720 / 2000 配合 360 px/s 是 130 px（2 格）与 3.1 格。
## 也就是跳得更高而滞空更短——“同样的高度用更少的时间”是快节奏手感的关键，
## 单纯把重力调小只会让人飘起来，反而更慢。
##
## **实测比解析值高，这不是误差而是离散积分的结果**：半隐式欧拉每步先加一次重力再位移，
## 相当于比连续模型多上升约 v·dt/2（60 Hz、1160 px/s 时是 9.7 px）。
## 2026-09-26 用无头脚本实测：高度 170.1 px、滞空 0.600 s，
## 而解析值加这 9.7 px 是 169.9 px——对得上。改数值时按这个差额估算即可，
## 不必担心“算出来的高度和手感不一致”而去反推重力。（滞空的实测值比解析值多约 0.05 s，
## 其中一半是同样的离散补偿，另一半是落地判定的帧粒度：is_on_floor 要到碰撞之后的下一帧才为真。）
## 可用 `--gravity` 覆盖。
static var gravity := 4200.0
## 土狼时间（秒）：离开地面之后仍允许起跳的窗口。0 表示关闭。
## 它只把“想跳”变得更容易被判为有效，不改变可达高度与距离。
## 实测：60 Hz 下窗口正好在第 6 帧归零（0.083→0.067→…→0.000）；
## 离地 50 ms 时按下可起跳，200 ms 时按下不起跳。
const COYOTE_TIME := 0.1
## 跳跃输入缓冲（秒）：落地之前按下的跳跃会在落地那一帧生效。0 表示关闭。
## 实测：下降末期按下后，落地当帧竖直速度即转为约 -1160（正常起跳）。
const JUMP_BUFFER := 0.12
## 碰撞箱半高（脚本里多处要它：脚点、复活抬升、推动判定）。
## 它必须与 scenes/player.tscn 里 RectangleShape2D 的 96 高一致——
## 对不上时表现是"站在地上却显示悬空"，或者站到冰面上立刻判成落水。
const HALF_HEIGHT := 48.0
## 自动驾驶的路线：沿 X 轴在 ±AUTOPILOT_END 之间往返。
## 2D 只有一条地面线，而两人互不碰撞，所以不需要像 3D 版那样给每人分配一条独立车道。
## 端点取值避开场景里的台阶（台阶右表面在 x=-432 处）。
const AUTOPILOT_END := 300.0
## 判定到达路点的距离。只会在两个端点短暂停下，不会周期性地出现。
const AUTOPILOT_ARRIVE := 12.0
## 自动驾驶：让本机角色在两点之间往返移动。用于在不按键的情况下测量显示平滑，
## 也供自动检查核对位置同步确实在流动。由入口脚本按命令行开关写入。
static var autopilot: bool = false
## 自动驾驶的走走停停模式：交替运动与静止各一秒。
## 专门用于复现"对方开始移动时卡一下"这个场景——那个现象的触发条件正是静止→移动的转换。
static var autopilot_stop: bool = false
## 远端显示的水位。0 表示用 RemoteInterpolator 的默认值；
## 可用 --interp-buffer 临时覆盖，仅用于对照。
static var interp_buffer: float = 0.0

## 自动驾驶当前的朝向，只在本机角色上有意义。
var _autopilot_forward: bool = true
## 土狼时间与跳跃输入缓冲的剩余时间（秒）。见 COYOTE_TIME 与 JUMP_BUFFER 的说明。
var _coyote: float = 0.0
var _jump_buffer: float = 0.0

## 是否已阵亡。各端各自维护，由 Game 的广播与本地判定共同写入。
## 阵亡期间不模拟（set_physics_process(false)），因此会有很短一段时间
## 本机角色的位置停止更新——这正是要的：他不动了，队友看到的就是"他没了"。
var _dead: bool = false
## 技能键是否处于"必须先抬起"的状态。交换角色之后置位，见机制与玩法设计 2.3 第 7 条：
## 交换后按住不放不会自动触发新角色的技能，否则按住技能键连按交换键就能扫过两个角色的技能。
var _skill_latched: bool = false
## 落地冲击带来的额外压扁量，逐帧衰减回 0。只影响观感。
var _land_squash: float = 0.0
## 上一帧是否在地面上，用来捕捉"落地那一帧"。
var _was_on_floor: bool = true
## 上一步的显示位置，用于远端角色推断朝向（远端拿不到输入方向）。
var _facing_from: Vector2 = Vector2.ZERO

## 上一组手感数值用的角色颜色常量已由 Element 接管，见 scripts/element.gd。
## 这里保留一句指路：正式的角色美术在 scripts/character_art.gd，
## 那个文件里解释了为什么两个角色的形状必须不一样。

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
## 单帧最大位移是"看到的跳"的直接计量：平滑运动每帧只应前进
## move_speed ÷ 显示帧率（480 px/s、120 帧时是 4 px）；
## 若出现十倍量级，就是那一帧把积攒的运动量一次走完了。
## 本区间的第一个采样只用来建立基准，不参与比较（_has_prev）。
var _has_prev: bool = false
var _prev_sample: Vector2 = Vector2.ZERO
## 本区间内显示位置相对起点移动了多远，用来区分"角色本来就没动"与"显示被冻住"。
## 用显示位置而不是收到的位置，这样本机角色也能得到同一口径的数字。
var _step_origin: Vector2 = Vector2.ZERO
var _display_moved: float = 0.0
## 单帧最大位移。"平稳一下、突然跳一下"里的那个跳就是这个值的尖峰：
## 平滑运动每帧只应前进 move_speed ÷ 显示帧率（480 px/s、120 帧时是 4 px）；
## 若出现十倍量级，就是跳。
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
## 一旦以后改动平滑逻辑又引入回拉，这两个数会立刻非零。
var _recv_dips: StepAnalyzer = StepAnalyzer.new()
var _disp_dips: StepAnalyzer = StepAnalyzer.new()

@onready var _art: CharacterArt = $Visual/Art
@onready var _visual: Node2D = $Visual
@onready var _camera: Camera2D = $Camera
@onready var _sync: MultiplayerSynchronizer = $Sync
@onready var _collision: CollisionShape2D = $Collision

## 关卡规则层（scripts/game/game.gd）。用组查找而不是从父节点上写一条固定路径：
## 角色是运行时生成的，挂到哪个父节点下取决于会话怎么开的，而组查找只依赖
## "场上有一个 Game"这一件事。找不到时（例如单独打开 player.tscn 试手感）
## 角色仍然能走能跳，只是没有介质判定与技能。
var _game: Game = null


func _enter_tree() -> void:
	# 权限必须在这里设置，不能等到 _ready()。原因在引擎一侧：
	# 接收方会在远端生成包到达的同一帧里应用初始同步状态，而那一刻它要求节点的
	# 多人权限已经等于发起方（SceneReplicationInterface::on_replication_start 里有这个判断）。
	# 权限本身不随生成包传输，因此各端必须各自得到同一个值——
	# 这里用的是生成函数收到的 peer_id，各端由同一份数据推导，结论必然一致。
	set_multiplayer_authority(peer_id)


func _ready() -> void:
	_local = peer_id == multiplayer.get_unique_id()
	# 元素同步器的权威必须固定为服务端。_enter_tree 里那次 set_multiplayer_authority
	# 是**递归**的，会把两个同步器一起改成这个 peer；位置同步器本来就该归这个 peer，
	# 但元素是服务端说了算的（交换角色由它串行处理），跟着改成客户端之后，
	# 服务端写什么都不会传出去——症状是"交换角色没有反应"，且不报任何错。
	# 放在 _ready 而不是 _enter_tree，是因为子节点那时还没进树，改不了权限。
	var element_sync := get_node_or_null("ElementSync") as MultiplayerSynchronizer
	if element_sync != null:
		element_sync.set_multiplayer_authority(1)
	# 加进组是给两条路用的：Game 找本机角色，以及冰块找"谁在推我"。
	# 两处都用组而不是节点路径，因为角色的父节点随会话而异。
	add_to_group("player")
	_game = get_tree().get_first_node_in_group("game") as Game
	_apply_element()
	_facing_from = global_position
	# 只有本机的角色参与模拟；显示帧则两边都要处理，本机用于相机跟随，远端用于插值。
	set_physics_process(_local)
	set_process(true)
	# 相机已在场景里作为子节点定好偏移，这里只需要决定由谁来用：
	# 每个实例都带一台相机，但只有本机那一台接管视角，否则视角会在两人之间乱跳。
	# 两步都不能省：enabled 是"参不参与"的开关，而相机入树时**不会**因为 enabled 就自动接管，
	# 所以还要 make_current()。反过来先 make_current() 会失败，因为引擎里有
	# enabled && is_inside_tree() 的断言（实测报错 Condition "!enabled || !is_inside_tree()"）。
	# 另注：Camera2D 没有 current 属性，那是 Camera3D 的。
	if _local:
		_camera.enabled = true
		_camera.make_current()
	else:
		_camera.enabled = false
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
		print("[player] 本机角色 peer=%d 已就位（%s）" % [peer_id, Element.kind_name(element)])
	else:
		# 把生效方式写进日志，目的是让"本机跑的是不是这套平滑代码"一眼可查。
		# 元素也一并打出来：它是随生成包一起到的，因此这一行同时验证了
		# "各端算出的元素一致"——不一致时两个人看到的是两套规则，且不会报任何错。
		print("[player] 远端角色 peer=%d 已就位（%s，时钟调速平滑，水位 %.0f ms）" % [
			peer_id,
			Element.kind_name(element),
			(interp_buffer if interp_buffer > 0.0 else RemoteInterpolator.DEFAULT_BUFFER) * 1000.0,
		])
		if _interp == null:
			print("[player] 本次无显示，不对 peer=%d 做平滑" % peer_id)


func _physics_process(delta: float) -> void:
	if _local:
		# 与位置同步更新，因此两者描述的是同一个时刻。
		sync_time = Time.get_ticks_msec()

	if _local and _game != null:
		_read_action_input()

	# 跳跃的两个宽容窗口。先记下"这一帧按下过"，这样落地前一帧按下的跳跃会在落地那一帧生效。
	if Input.is_action_just_pressed("jump"):
		_jump_buffer = JUMP_BUFFER
	else:
		_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	var on_floor := is_on_floor()
	if on_floor:
		_coyote = COYOTE_TIME
	else:
		_coyote = maxf(_coyote - delta, 0.0)

	if not on_floor:
		velocity.y += gravity * delta
	# 起跳的判据用 on_floor 或土狼时间，而不是只看 _coyote：
	# COYOTE_TIME 设为 0 时前者仍然成立，于是"关掉土狼时间"不会连带把起跳本身关掉。
	# 防连跳靠的是清空 _jump_buffer，与 on_floor 在起跳后当帧仍为真这一点无关。
	if _jump_buffer > 0.0 and (on_floor or _coyote > 0.0):
		velocity.y = -jump_velocity
		_jump_buffer = 0.0
		_coyote = 0.0

	var direction := Input.get_axis("move_left", "move_right")
	if autopilot or autopilot_stop:
		# 沿地面往返。始终在动、方向固定，因此显示一旦冻结就能直接看出来。
		# 到达端点时必须"翻转后立即改向新路点"，不能把方向置零：置零会让角色留在到达半径内，
		# 下一帧又判定到达并再次翻转，于是永远停在端点不动。
		if autopilot_stop and int(Time.get_ticks_msec() / 1000) % 2 == 1:
			# 走走停停模式：奇数秒完全静止（与真人松手时一样）。
			direction = 0.0
		else:
			var to_target := _autopilot_target() - global_position.x
			if absf(to_target) < AUTOPILOT_ARRIVE:
				_autopilot_forward = not _autopilot_forward
				to_target = _autopilot_target() - global_position.x
			direction = signf(to_target)
	velocity.x = direction * move_speed
	move_and_slide()


## 当前朝向对应的自动驾驶目标点（只用到 X 坐标）。
func _autopilot_target() -> float:
	return AUTOPILOT_END if _autopilot_forward else -AUTOPILOT_END


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
	_update_art(delta, displayed)
	_record_step(displayed)


# ---------------------------------------------------------------- 元素、死亡与表现

## 读技能键与交换键。只在物理帧、且只有本机角色会走到这里。
##
## 技能键要求"抬起再按下"：_skill_latched 在交换角色之后置位，
## 而它只在按键完全松开时才解除。这与机制与玩法设计 2.3 第 7 条是同一件事：
## 交换角色后按住不放不会顺带放出新角色的技能。
func _read_action_input() -> void:
	if not Input.is_action_pressed("skill"):
		_skill_latched = false
	elif Input.is_action_just_pressed("skill") and not _skill_latched:
		_game.use_skill(self)
	if Input.is_action_just_pressed("swap"):
		_game.request_swap(peer_id)


## 把元素写进外观。所有改 element 的地方都必须经过这里，
## 否则会出现"颜色变了但形状还是上一个元素"这种半更新状态。
func _apply_element() -> void:
	if _art != null:
		_art.set_element(element)


## 由 Game 调用（服务端广播与本地判定两条路）。元素是服务端权威的，
## 客户端不要自己去改它——两边各改一次的结果是"换回来了又换回去"。
func set_element(kind: int) -> void:
	if element == kind:
		return
	element = kind
	_skill_latched = true
	_apply_element()


## 角色的中心点（世界坐标）。技能判定、检查点与积分的触发都用它。
func center() -> Vector2:
	return global_position


## 脚点（碰撞箱底边中点）。介质判定用它，理由见 scripts/level/hazard.gd：
## 熔站在浮于水面的冰上时，脚点在水面上方，因此不会被判成落水。
func feet() -> Vector2:
	return global_position + Vector2(0.0, HALF_HEIGHT)


func is_dead() -> bool:
	return _dead


## 死亡。可被本地判定与服务端广播先后调用，因此必须幂等。
func kill() -> void:
	if _dead:
		return
	_dead = true
	velocity = Vector2.ZERO
	# 关掉碰撞：不能踩在别人头上、不能被手雷推开（2.5 里这些交互都建立在"他是个实体"上），
	# 而一具还会挡路的尸体比看不见他更让人困惑。
	_collision.set_deferred("disabled", true)
	if _art != null:
		_art.set_dead(true)
	set_physics_process(false)


## 复活到指定位置。位置由服务端决定（它记着每个人到过的最后一个检查点），
## 但写进去的是**角色自己那台机器**——位置是各自权威的，别人写会被覆盖。
func revive(at: Vector2) -> void:
	_dead = false
	_collision.set_deferred("disabled", false)
	if _art != null:
		_art.set_dead(false)
	if _local:
		position = at
		velocity = Vector2.ZERO
		# 落地那一帧的形变状态也清掉：从上一处地方带过来的压扁量会在新位置弹一下。
		_land_squash = 0.0
		_was_on_floor = false
	set_physics_process(_local)
	if _interp != null:
		# 插值器里还留着"死亡之前那一处"的样本，不清掉的话远端角色会从旧位置滑过来。
		_interp.reset()
		if interp_buffer > 0.0:
			_interp.buffer = interp_buffer
			_interp.adaptive = false
		# 直接把显示子节点挪到新位置：远端角色真正的 position 要等下一个同步包才更新，
		# 那之前如果不动，画面里就会看到他从原地滑过去。同步包一到，_process 会用
		# 插值结果覆盖这个偏移（那时它已经等于新位置，偏移自然回到 0）。
		_visual.position = at - position


## 每帧更新外观：朝向、起跳拉伸、落地压扁。
## 这里只写 CharacterArt 自己的属性，不碰 position——远端角色的显示位置由
## RemoteInterpolator 写在父节点 Visual 上，两者写同一处会互相覆盖。
func _update_art(delta: float, displayed: Vector2) -> void:
	if _art == null:
		return
	if _local:
		var direction := Input.get_axis("move_left", "move_right")
		if absf(direction) > 0.01:
			_art.facing = 1 if direction > 0.0 else -1
	else:
		# 远端拿不到输入方向，只能用位移方向反推。阈值取 0.5 px：
		# 显示位置每帧前进 4 px 左右，抖动不会超过这个数。
		var moved := displayed.x - _facing_from.x
		if absf(moved) > 0.5:
			_art.facing = 1 if moved > 0.0 else -1
	_facing_from = displayed

	var on_floor := is_on_floor()
	if _local:
		if on_floor and not _was_on_floor:
			# 落地那一帧按下落速度决定压扁多少。取速度而不是高度：
			# 高度要额外记录一次起跳位置，而速度本来就有，且它直接就是冲击强度。
			_land_squash = clampf(absf(velocity.y) / 2600.0, 0.0, 0.26)
		_was_on_floor = on_floor

	var target := 1.0
	if not on_floor:
		# 空中按竖直速度拉长：越接近最高点越接近原状（速度小），
		# 因此"跳起来"与"落下来"中间会有一个自然的过渡，而不是整段都在拉长。
		target = 1.0 + clampf(absf(velocity.y) / 3200.0, 0.0, 0.14)
	_land_squash = maxf(_land_squash - delta * 2.2, 0.0)
	_art.stretch = target * (1.0 - _land_squash)


## 统计显示帧之间位置有没有变化与有没有倒退。对两边的角色都做，因为成因不同：
## 本机角色若停在大量帧上不动，说明物理帧率低于显示帧率（与网络无关）；
## 远端角色若如此，则说明平滑未能拿到可用的区间。
func _record_step(displayed: Vector2) -> void:
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
		return "%.2f px（无平滑）" % step
	return "%.2f px 当时：滞后 %.0f/%.0f ms 钟速 %.2f 保持=%s 距新位置 %.0f ms" % [
		step,
		_interp.fill_seconds() * 1000.0,
		_interp.buffer_seconds() * 1000.0,
		_interp.rate(),
		"是" if _interp.is_holding() else "否",
		_interp.seconds_since_unique() * 1000.0,
	]
