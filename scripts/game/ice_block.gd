class_name IceBlock
extends CharacterBody2D
## 霜造出来的冰块。三种身份叠在同一个实体上（见机制与玩法设计 3.2）：
## 限时平台、团队通路、以及挡在敌人面前的墙（敌人部分尚未实现，碰撞层已经就位）。
##
## **服务端权威**。位置由服务端推进并同步，客户端只负责显示。
## 这条与设计文档 4.5 一致：冰块决定这一关可不可解，两端各自算出不同位置
## 就等于两个人玩的是两张图。反过来，玩家位置仍然是各自权威的（见 player.gd），
## 因此"我推冰块"这件事在客户端看起来是：我顶着它、它每收到一次新位置才往前挪一格。
## 网络延迟会直接表现为推动的顿挫，局域网下可以接受——这是把推箱做成服务端权威
## 必须付出的代价，而它换来的是"两人的冰块位置不会分歧"。
##
## 推得慢（PUSH_SPEED 110 px/s，60 Hz 下每帧不到 2 px）是有意为之：
## 同步过来的位置是跳变的，走快了就会看出一格一格的挪动；慢速让它看不出来，
## 而"冰很重"这件事本来就该在操作手感上体现出来。

## 尺寸。宽 96（1.5 格）、高 64（1 格）。
const SIZE := Vector2(96.0, 64.0)
## 落在岩浆上之后多久下沉。机制与玩法设计 3.2 只写了"一段时间"，这里是初值。
const LAVA_LIFETIME := 4.0
## 推动速度（px/s）。见类注释：慢是刻意的。
const PUSH_SPEED := 110.0
## 侧面推动的判定余量（像素）。太小学生会推不动，太大能从一格之外推动。
const PUSH_REACH := 8.0
## 判定“冰块底下是什么”时用的点相对底边的抬升量。
## 用底边中点正上方一点点：贴着底边会被 Rect2 的边界规则排除在外。
const PROBE_LIFT := 4.0
## 底下既不是地面也不是介质时的下落速度（px/s）。没有这一段的话，
## 被推下台阶的冰会悬在半空——而它看着像实体，玩家会以为踩得上去。
## 慢于角色的下落是刻意的：冰很重。
const FALL_SPEED := 380.0

## 由生成包带过来，各端一致。用于节点命名与排查。
var id: int = 0
## 发出时刻（毫秒）。与玩家同步同一个用途，见 player.gd 里 sync_time 的说明。
var sync_time: int = 0

## 融化进度 0→1。所有端各自按位置推算，因此不需要同步；
## 真正把这块冰去掉的只有服务端。
var _melt: float = 0.0

var _collision: CollisionShape2D = null
var _level: Level = null


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	var shape := RectangleShape2D.new()
	shape.size = SIZE
	_collision = CollisionShape2D.new()
	_collision.shape = shape
	add_child(_collision)
	queue_redraw()


## 从生成参数建出节点。由 Game 交给 MultiplayerSpawner 的 spawn_function 调用，
## 各端拿到的是同一份参数，因此节点树一致。
func setup(data: Dictionary) -> void:
	id = int(data.get("id", 0))
	name = "ice%d" % id
	position = data.get("position", Vector2.ZERO)


func bind_level(level: Level) -> void:
	_level = level


func _physics_process(delta: float) -> void:
	# 权威端只在物理帧推进：融化计时、下落与推动都写在这里，避免与 _process 各推一次。
	if not is_multiplayer_authority():
		return
	_tick(delta)
	sync_time = Time.get_ticks_msec()
	_settle(delta)
	_push_by_players(delta)


func _process(delta: float) -> void:
	# 非权威端只在显示帧推进融化计时；权威端已经在上面推过了。
	if not is_multiplayer_authority():
		_tick(delta)
	queue_redraw()


## 融化计时。两端各自按"冰块当前位置是否落在岩浆里"推算，结果一致，
## 因此不需要为它增加同步包。服务端在进度满了之后把节点删掉，
## MultiplayerSpawner 会把删除同步出去。
func _tick(delta: float) -> void:
	var hazard := _hazard_under()
	if hazard != null and hazard.medium == Element.Medium.LAVA:
		_melt = minf(_melt + delta / LAVA_LIFETIME, 1.0)
	else:
		_melt = 0.0
	if _melt >= 1.0 and is_multiplayer_authority():
		queue_free()


## 冰块底下是哪个介质区，没有则 null。用底边中点判定而不是整块重叠：
## 冰块大半没在水里，整块重叠的话区分不出“浮着”与“沉到底”。
func _hazard_under() -> Hazard:
	if _level == null:
		return null
	return _level.hazard_at(global_position + Vector2(0.0, SIZE.y * 0.5 - PROBE_LIFT))


## 往下落，直到碰到地面或落到介质里为止。
## 底下是介质时不落：浮在水面上正是冰能当桥的原因（见 Game.ice_placement）。
func _settle(delta: float) -> void:
	if _hazard_under() != null:
		return
	move_and_collide(Vector2(0.0, FALL_SPEED * delta))


# ---------------------------------------------------------------- 推动

## 把冰块朝正在推它的玩家那一侧移动。只有服务端调用。
## 判定条件三条，缺一不可：玩家与冰块在高度上重叠、玩家贴着冰块的这一侧、
## 玩家的水平速度朝向冰块。第三条用的是同步过来的 velocity——
## 位置同步只能看出"玩家挪了没有"，看不出"他想往哪边挪"，而推动需要的正是后者。
func _push_by_players(delta: float) -> void:
	var dir := _push_direction()
	if dir == 0.0:
		return
	move_and_collide(Vector2(dir * PUSH_SPEED * delta, 0.0))


func _push_direction() -> float:
	for node in get_tree().get_nodes_in_group("player"):
		var player := node as Player
		if player == null or player.is_dead():
			continue
		var towards := signf(global_position.x - player.global_position.x)
		if towards == 0.0:
			continue
		if signf(player.velocity.x) != towards:
			continue
		if not _pushed_from_side(player, towards):
			continue
		return towards
	return 0.0


## 玩家是否从冰块的某一侧贴着它。towards 为 1 表示冰块在玩家右边。
func _pushed_from_side(player: Player, towards: float) -> bool:
	var block := Rect2(global_position - SIZE * 0.5, SIZE)
	var body := Rect2(player.global_position - Vector2(24.0, 48.0), Vector2(48.0, 96.0))
	# 站在冰块顶上不算推：那种情况下玩家的脚在冰块顶面之上。
	if body.position.y + body.size.y <= block.position.y + 2.0:
		return false
	# 把判定框朝玩家所在的那一侧放宽，避免"贴上了但差一像素"。
	if towards > 0.0:
		block.position.x -= PUSH_REACH
		block.size.x += PUSH_REACH
	else:
		block.size.x += PUSH_REACH
	return block.intersects(body, true)


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var half := SIZE * 0.5
	# 融化时整体下沉并缩小，给"这块冰要没了"一个提前量。
	var sink := _melt * 26.0
	var shrink := 1.0 - _melt * 0.45
	var rect := Rect2(Vector2(-half.x, -half.y * shrink + sink), Vector2(SIZE.x, SIZE.y * shrink))
	var top := Color(0.79, 0.94, 1.0, 0.95 - _melt * 0.35)
	var deep := Color(0.33, 0.62, 0.83, 0.95 - _melt * 0.35)
	draw_rect(rect, deep)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, maxf(4.0, rect.size.y * 0.22))), top)
	draw_rect(rect, top.darkened(0.25), false, 2.0)
	# 内部裂纹。位置按尺寸取比例，因此缩放时不会跑出冰块外面。
	var x := -half.x + 18.0
	while x < half.x - 8.0:
		draw_line(
			Vector2(x, rect.position.y + 8.0),
			Vector2(x + 16.0, rect.position.y + rect.size.y - 6.0),
			Color(0.86, 0.97, 1.0, 0.45 * (1.0 - _melt)), 1.8)
		x += 30.0
	if _melt > 0.0:
		# 融化中的水汽。
		draw_circle(Vector2(0.0, rect.position.y - 10.0), 26.0 * _melt, Color(0.85, 0.95, 1.0, 0.24 * (1.0 - _melt)))
