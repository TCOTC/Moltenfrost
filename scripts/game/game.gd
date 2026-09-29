class_name Game
extends Node
## 一局游戏的规则层：元素分配、死亡与复活、技能、冰块、积分与通关。
##
## **权威划分**（与设计文档 4.5 一致，也是这个文件里所有判断的根据）：
##
##   玩家位置 —— 各自的机器权威。谁的角色谁模拟，因此"我踩到岩浆了"由**我自己**判定，
##     否则每帧都要往返一次服务端，手感会烂掉。
##   世界变化 —— 服务端权威。造冰、融冰、拾取积分、通关判定、复活位置全部由服务端决定后广播。
##     这些东西决定这一关可不可解，两端各自算出不同结果就等于两个人玩的是两张图。
##
## 因此本文件的形状是：本地能判的（踩到致命介质）立刻在本地表现，然后上报；
## 本地不能判的（造冰、通关）发请求等服务端回话。
##
## **所有 @rpc 都挂在这个节点上**，路径是 /root/Main/Game，在各端都成立。
## 挂在 Player 上也可以（它也在各端生成），但它是由 MultiplayerSpawner 动态生成的，
## 路径里带着 peer id；路径一旦对不上，RPC 是**静默失败**的，排查代价远高于集中在一个节点上。

const LEVEL_SCENE := preload("res://scenes/levels/level_01.tscn")
const ICE_SCENE := preload("res://scenes/game/ice_block.tscn")

## 死亡到复活的等待。给队友一点时间看清"他没了"，也给死亡动画留出时长
##（CharacterArt.DEATH_TIME 是 0.45 秒）。两者不是同一个数：观感与规则各管一段。
const RESPAWN_DELAY := 0.9
## 技能从按下到生效的延迟。机制与玩法设计 2.2 把"延后生效"定为核心机制：
## 它让两人可以错开出手、约定同时生效，所有同步谜题都建立在这上面。
const SKILL_DELAY := 0.45
## 技能作用半径（像素）。以角色为中心，2.5 格。
const SKILL_RADIUS := 160.0
## 冰块浮在水面时的干舷（露出水面的高度，像素）。
## 它必须大于 0 且足以让站在冰面上的角色的脚点离开水面判定区（Hazard 的上边界就是水面）。
const ICE_FLOAT_FREEBOARD := 16.0
## 同一位置附近禁止重复造冰的距离倍数（乘冰块宽度）。
## 这不是冷却——设计文档 2.2 明确"无冷却、无能量上限"——而是一条空间规则：
## 站在同一个点上连按会把冰叠成一堆，看起来像穿模。
const ICE_MIN_GAP := 0.5
## 场上冰块上限。防止连着按技能把节点数刷上天，同时给"冰用得太多"一个明确反馈。
const ICE_LIMIT := 24
## 单次通关的额外积分。取分点给 50，通关给 200：让"把这一关打完"比"贪分"更值。
const COMPLETE_BONUS := 200
## 通关后按 Enter 重开的键。用引擎自带的 ui_accept，它已经绑在回车与空格上。
const RESTART_ACTION := "restart"

@onready var _level_host: Node2D = $"../LevelHost"
@onready var _players: Node2D = $"../Players"
@onready var _world: Node2D = $"../World"
@onready var _ice_spawner: MultiplayerSpawner = $"../World/IceSpawner"
@onready var _hud: GameHud = $"../HUD"

var level: Level = null

## 每个 peer 到达过的最新检查点序号。只在服务端维护。
var _checkpoint: Dictionary = {}
## 每个 peer 的死亡时刻与致命介质。只在服务端维护。
var _dead: Dictionary = {}
## 已拾取的积分点下标。**两端都维护**，因为要各自把自己那份画面里的点收掉。
var _collected: Array[int] = []
var _score: int = 0
var _completed: bool = false
## 服务端等待生效的技能：{"peer": int, "kind": int, "origin": Vector2, "at": float}
var _queue: Array = []
## 自本局开始以来的秒数。只用来做计时比较，不用墙钟，避免两端时钟不一致。
var _elapsed: float = 0.0
var _next_ice_id: int = 1


func _ready() -> void:
	add_to_group("game")
	var instance := LEVEL_SCENE.instantiate()
	_level_host.add_child(instance)
	level = instance as Level
	# 生成函数必须在任何生成请求之前设好，而接收端也要用它重建节点，
	# 因此这里在各端都会执行一次（引擎把它标为不序列化，写不进场景文件）。
	_ice_spawner.spawn_function = _build_ice
	print("[level] 载入「%s」：%d 个介质区、%d 块实心几何、%d 个检查点、%d 个积分点" % [
		level.display_name, level.hazards.size(), level.solids.size(),
		level.checkpoints.size(), level.pickups.size(),
	])
	_hud.set_level_name(level.display_name)


func _process(_delta: float) -> void:
	_push_hud()


func _physics_process(delta: float) -> void:
	_elapsed += delta
	for child in _players.get_children():
		var player := child as Player
		if player != null and player.is_local() and not player.is_dead():
			_check_hazard(player)
	if _is_server():
		_server_tick()


# ---------------------------------------------------------------- 供 Player 调用

## 点所在的介质区，没有则 null。
func hazard_at(point: Vector2) -> Hazard:
	return level.hazard_at(point) if level != null else null


## 本机角色踩进致命介质。立刻在本地表现，然后让服务端安排复活。
## 先表现再上报是有意的：上报要走一个来回，等回话才播死亡动画会明显迟一拍。
func report_death(peer_id: int, medium: int) -> void:
	_mark_dead(peer_id, medium)
	if _is_server():
		_declare_dead(peer_id, medium)
	else:
		_rpc_death.rpc_id(1, medium)


## 施放技能。按下即发出，判定与生效都在服务端。
func use_skill(player: Player) -> void:
	if player == null or player.is_dead():
		return
	if _is_server():
		_start_skill(player.peer_id, player.element, player.center())
	else:
		_rpc_skill.rpc_id(1)


## 交换角色（机制与玩法设计 2.3）。字段名与语义同设计文档：
## 两人在场上时是"对调两人的元素"，只有一人时是"切换自己的身份"（2.6）。
## 两种情形合成同一段服务端代码，因此"两人同时按下即回到原状"这条自动成立：
## 服务端串行处理两次对调，结果必然回到原状，不需要额外的冲突仲裁。
func request_swap(peer_id: int) -> void:
	if _is_server():
		_swap(peer_id)
	else:
		_rpc_swap.rpc_id(1)


## 从关卡开头重来。设计文档 1.2 允许放弃检查点重来，
## 为的是避免"队友把一个走不通的状态带了过来、卡在检查点上"。
func request_restart() -> void:
	if _is_server():
		_restart()
	else:
		_rpc_request_restart.rpc_id(1)


func is_completed() -> bool:
	return _completed


func score() -> int:
	return _score


## 服务端为新连上的 peer 补齐状态：它可能是中途进来的（虽然当前没有中途加入的入口，
## 但重开一局时两边都会重新走一次生成，因此这一步是必需的）。
func on_peer_joined(peer_id: int) -> void:
	if not _is_server():
		return
	_checkpoint[peer_id] = 0
	_dead.erase(peer_id)


func on_peer_left(peer_id: int) -> void:
	_checkpoint.erase(peer_id)
	_dead.erase(peer_id)


## 会话结束（回到初始界面）时把这一局的世界状态清掉。
## 由入口脚本调用，因为它才知道会话什么时候结束。
## **积分不清零**：它属于账号（设计文档 6.2），换一个房间继续累计。
## 而拾取点、冰块、打掉的冰墙、检查点记录都属于"这一局"，重新开局应当从干净状态开始。
func reset_for_new_session() -> void:
	for block in _ice_blocks():
		block.queue_free()
	for i in level.solids.size():
		var solid := level.solid_at_index(i)
		if solid != null:
			solid.set_broken(false)
	for i in level.pickups.size():
		var pickup := level.pickup_at_index(i)
		if pickup != null:
			pickup.set_taken(false)
	_collected.clear()
	_checkpoint.clear()
	_dead.clear()
	_queue.clear()
	_completed = false
	_hud.hide_overlay()
	# 抬头显示的"你/队友"两格不用手动清：角色一没，_push_hud 下一帧就会推成空。


# ---------------------------------------------------------------- 输入

func _unhandled_input(event: InputEvent) -> void:
	if not _input_enabled():
		return
	if _completed and event.is_action_pressed("ui_accept"):
		request_restart()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(RESTART_ACTION):
		request_restart()
		get_viewport().set_input_as_handled()


## 初始界面开着时不接受对局内的按键。判断放在入口脚本那边（它才知道界面在不在），
## 这里只问一句，避免 Game 反过来依赖菜单。
func _input_enabled() -> bool:
	var main := get_parent()
	if main != null and main.has_method("is_menu_open"):
		return not bool(main.call("is_menu_open"))
	return true


# ---------------------------------------------------------------- 本地判定

func _check_hazard(player: Player) -> void:
	var hazard := hazard_at(player.feet())
	if hazard == null:
		return
	if not Element.is_lethal(player.element, hazard.medium):
		return
	report_death(player.peer_id, hazard.medium)


# ---------------------------------------------------------------- 服务端 tick

func _server_tick() -> void:
	_tick_checkpoints()
	_tick_respawn()
	_tick_skills()
	_tick_pickups()
	_tick_goal()


## 记录每个 peer 到过的最新检查点。用角色的中心点判定，
## 与 Checkpoint 的触发范围配套（它按"站着不动的角色中心点"设计）。
func _tick_checkpoints() -> void:
	for child in _players.get_children():
		var player := child as Player
		if player == null or player.is_dead():
			continue
		var index := level.checkpoint_at(player.center())
		if index > int(_checkpoint.get(player.peer_id, 0)):
			_checkpoint[player.peer_id] = index


func _tick_respawn() -> void:
	for peer in _dead.keys():
		var info: Dictionary = _dead[peer]
		if _elapsed - float(info["at"]) < RESPAWN_DELAY:
			continue
		_dead.erase(peer)
		_broadcast_respawn(int(peer))


func _tick_skills() -> void:
	while not _queue.is_empty() and _elapsed >= float(_queue[0]["at"]):
		var item: Dictionary = _queue.pop_front()
		_server_apply_skill(int(item["peer"]), int(item["kind"]), item["origin"])


func _tick_pickups() -> void:
	for i in level.pickups.size():
		if _collected.has(i):
			continue
		var pickup := level.pickup_at_index(i)
		if pickup == null:
			continue
		for child in _players.get_children():
			var player := child as Player
			if player == null or player.is_dead():
				continue
			if not pickup.contains_point(player.center()):
				continue
			_broadcast_pickup(i, pickup.value)
			break


## 通关条件：所有在场的角色都站在出口里。单人游玩时同一个判定自然退化为"一个人进去"，
## 因为场上本来就只有一个角色。
func _tick_goal() -> void:
	if _completed or level.goal == null:
		return
	var total := 0
	var inside := 0
	for child in _players.get_children():
		var player := child as Player
		if player == null:
			continue
		total += 1
		if player.is_dead():
			continue
		if level.goal.contains_point(player.center()):
			inside += 1
	if total > 0 and inside == total:
		_completed = true
		_apply_completed(COMPLETE_BONUS)
		_broadcast(&"_rpc_completed", [COMPLETE_BONUS])


# ---------------------------------------------------------------- 技能

func _start_skill(peer_id: int, kind: int, origin: Vector2) -> void:
	# 预告先发出去：两端从收到它的那一刻开始画收拢的圆环，
	# 而真正的效果在 SKILL_DELAY 之后。这正是 2.2 要的"按下与生效分离"。
	_apply_skill_charge(peer_id, kind, origin)
	_broadcast(&"_rpc_skill_charge", [peer_id, kind, origin])
	_queue.append({"peer": peer_id, "kind": kind, "origin": origin, "at": _elapsed + SKILL_DELAY})
	_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["at"]) < float(b["at"]))


func _server_apply_skill(peer_id: int, kind: int, origin: Vector2) -> void:
	if Element.melts(kind):
		_melt_ice(origin)
		_break_walls(origin)
	if kind == Element.Kind.FROST:
		var placement := ice_placement(origin)
		if bool(placement.get("ok", false)):
			_spawn_ice(placement.get("position") as Vector2)
	_apply_skill_burst(peer_id, kind, origin)
	_broadcast(&"_rpc_skill_burst", [peer_id, kind, origin])


## 熔的技能：融掉作用半径内的冰块。
func _melt_ice(origin: Vector2) -> void:
	for block in _ice_blocks():
		if block.global_position.distance_to(origin) <= SKILL_RADIUS:
			block.queue_free()


## 熔的技能：打掉作用半径内可融的实心块（冰墙）。走 RPC 是因为它们是关卡场景的一部分，
## 两端各有一份，必须两边一起改。传下标而不是路径：下标由节点树顺序决定，
## 两端一致，而路径一旦有一边改了节点名就会静默失效。
func _break_walls(origin: Vector2) -> void:
	for i in level.solids.size():
		var solid := level.solid_at_index(i)
		if solid == null or not solid.meltable or solid.is_broken():
			continue
		if _rect_distance(solid_rect(solid), origin) > SKILL_RADIUS:
			continue
		solid.set_broken(true)
		_broadcast(&"_rpc_break_solid", [i])


## 霜的技能：算出这一块新冰应当放在哪里。参数 origin 是**施放者的中心点**
##（技能的圆形范围以角色为中心，与熔的融冰判定同一个口径），
## 而冰落在它脚下——中心与脚点差半个身高，混用会让冰出现在半空。
## 返回 {"ok": bool, "position": Vector2, "reason": String}。
##
## 三条限制都来自设计文档，只有第一条是这里推出来的：
##   1. 要站在落脚点上（地面或水里），跳在空中不造——否则会造出一块悬空的冰；
##   2. 不能造在熔岩表面，必须先造在别处再推上去（机制与玩法设计 3.2）；
##   3. 不能造在已有的冰上——否则可以一边站在自己的冰上一边往上摞，等于一把无限高的梯子。
## 返回值用字典而不是 Variant：失败理由要能直接显示给玩家，
## 而"用 null 表示失败"会让调用方处处判空，也说不清为什么失败。
func ice_placement(origin: Vector2) -> Dictionary:
	if level == null:
		return {"ok": false, "reason": "关卡还没载入"}
	var feet := origin + Vector2(0.0, Player.HALF_HEIGHT)
	var candidate := Vector2.ZERO
	var hazard := level.hazard_at(feet)
	if hazard != null:
		if hazard.medium != Element.Medium.WATER:
			# 站在岩浆里只可能是熔，而熔不造冰；真发生也不该在岩浆面上生成冰。
			return {"ok": false, "reason": "冰不能在岩浆表面上生成"}
		# 站在水里：冰浮起来，**顶面**高出液面一个干舷，其余没入水中。
		# 于是站在冰上的人脚点在液面之上，不会被判成落水——这正是冰能当桥用的原因。
		# 反过来（底面高于液面）会让冰整个浮在空中，人踩上去与水面之间空一格。
		var top := hazard.surface_y() - ICE_FLOAT_FREEBOARD
		candidate = Vector2(feet.x, top + IceBlock.SIZE.y * 0.5)
	else:
		var ground := ground_below(feet)
		if ground == null:
			return {"ok": false, "reason": "脚下没有落脚点，造不出冰"}
		if ground is IceBlock:
			return {"ok": false, "reason": "不能在冰上再摞一块冰"}
		candidate = Vector2(feet.x, feet.y - IceBlock.SIZE.y * 0.5)
	# 密集判定放在最后、比的是**候选位置**而不是脚点：浮在水面上的冰，其位置比脚点高出
	# 一大截（液面在池底之上），拿脚点去比永远比不中，于是同一个位置能反复叠出冰来。
	if _ice_too_dense(candidate):
		return {"ok": false, "reason": "这里已经有一块冰了"}
	return {"ok": true, "position": candidate}


## 同一位置附近已经有冰了就拒绝。见 ICE_MIN_GAP 的说明：这是空间规则而不是冷却。
## 参数是**候选位置**（冰块的节点位置），不是施放者的脚点：浮在水面时两者差得很远。
func _ice_too_dense(candidate: Vector2) -> bool:
	var gap := IceBlock.SIZE.x * ICE_MIN_GAP
	for block in _ice_blocks():
		if absf(block.global_position.x - candidate.x) < gap \
				and absf(block.global_position.y - candidate.y) < IceBlock.SIZE.y * 0.5:
			return true
	return false


## 从某点向下找第一个实心块。射线起点刻意放在该点**上方** 8 像素：
## 从脚下那颗点起算的话，射线起点已经在地面形状内部，而射线不会报告"起点在内部"的命中，
## 于是永远找不到自己踩着的那块地。
func ground_below(point: Vector2) -> Node:
	var space := _world.get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(
		point + Vector2(0.0, -8.0), point + Vector2(0.0, 48.0), 1)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit["collider"]


func _spawn_ice(at: Vector2) -> void:
	var blocks := _ice_blocks()
	if blocks.size() >= ICE_LIMIT:
		return
	var data := {"id": _next_ice_id, "position": at}
	_next_ice_id += 1
	_ice_spawner.spawn(data)


## MultiplayerSpawner 的生成函数。各端都会用它重建节点，因此只能依赖入参。
func _build_ice(data: Variant) -> Node:
	var info: Dictionary = data if data is Dictionary else {}
	var block := ICE_SCENE.instantiate() as IceBlock
	block.setup(info)
	block.bind_level(level)
	return block


func _ice_blocks() -> Array[IceBlock]:
	var out: Array[IceBlock] = []
	for child in _world.get_children():
		if child is IceBlock:
			out.append(child)
	return out


# ---------------------------------------------------------------- 死亡与复活

func _declare_dead(peer_id: int, medium: int) -> void:
	if _dead.has(peer_id):
		return
	_dead[peer_id] = {"at": _elapsed, "medium": medium}
	_mark_dead(peer_id, medium)
	_broadcast(&"_rpc_mark_dead", [peer_id, medium])


## 把角色置为死亡。各端各自执行，因此必须**幂等**：本机自己那条路径已经先执行过一次，
## 服务端的广播随后还会到，重复执行不能有效果（否则会出现两条波纹、两次提示）。
func _mark_dead(peer_id: int, medium: int) -> void:
	var player := _player(peer_id)
	if player == null or player.is_dead():
		return
	player.kill()
	Fx.ripple(_world, player.center(), Element.medium_color(medium), 84.0)
	if player.is_local():
		_hud.toast("阵亡了，正在回到最近的检查点…", 1.4)


## 把某个角色放到它最近到过的检查点。位置由它**自己那台机器**写入：
## 角色位置是各自权威的，服务端直接写别人的 position 会被对方的同步覆盖掉。
func _broadcast_respawn(peer_id: int) -> void:
	var index := int(_checkpoint.get(peer_id, 0))
	var at := level.checkpoint_respawn(index)
	var player := _player(peer_id)
	if player != null:
		player.revive(at)
	_broadcast(&"_rpc_respawn", [peer_id, at])


# ---------------------------------------------------------------- 交换角色

func _swap(peer_id: int) -> void:
	var target := _player(peer_id)
	if target == null:
		return
	# 两人时对调；只有一人时切换自己的身份。两者是同一段代码：
	# "把自己的元素换成对面那个"，而单人时对面为空，于是退化为取反。
	var mate := _mate_of(target)
	var new_kind := Element.other(target.element) if mate == null else mate.element
	var table := {peer_id: new_kind}
	if mate != null:
		table[mate.peer_id] = target.element
	_apply_elements(table)
	_broadcast(&"_rpc_elements", [table])


func _apply_elements(table: Dictionary) -> void:
	for peer in table.keys():
		var player := _player(int(peer))
		if player != null:
			player.set_element(int(table[peer]))


# ---------------------------------------------------------------- 积分与通关

func _broadcast_pickup(index: int, value: int) -> void:
	_apply_pickup(index, value)
	_broadcast(&"_rpc_pickup", [index, value])


func _apply_completed(bonus: int) -> void:
	_score += bonus
	_hud.show_overlay("关卡完成", "本关剩余积分已结算 · 按 Enter 从头再来一局")
	_hud.toast("两人都到达了出口，关卡完成", 2.5)


func _apply_pickup(index: int, value: int) -> void:
	# 幂等：服务端自己那条路径与广播可能都会走到这里。
	if _collected.has(index):
		return
	_collected.append(index)
	_score += value
	var pickup := level.pickup_at_index(index)
	if pickup != null:
		pickup.set_taken(true)
	_hud.toast("+%d 积分" % value, 1.2)


func _restart() -> void:
	# 服务端做的三件事：清掉所有冰、把检查点记录清零、把每个人放回出生点。
	# 已被打掉的冰墙**恢复**（关卡重开就是重开），而已经拾取的积分**不恢复**——
	# 积分属于账号（设计文档 6.2），让它随重开复活就等于给了一个刷分按钮。
	for block in _ice_blocks():
		block.queue_free()
	for i in level.solids.size():
		var solid := level.solid_at_index(i)
		if solid != null:
			solid.set_broken(false)
	_checkpoint.clear()
	_dead.clear()
	_queue.clear()
	_completed = false
	var positions := {}
	for child in _players.get_children():
		var player := child as Player
		if player != null:
			positions[player.peer_id] = level.spawn_point(player.spawn_slot)
	_apply_restart(positions)
	_broadcast(&"_rpc_restart", [positions])


func _apply_restart(positions: Dictionary) -> void:
	_completed = false
	_hud.hide_overlay()
	for i in level.solids.size():
		var solid := level.solid_at_index(i)
		if solid != null:
			solid.set_broken(false)
	for peer in positions.keys():
		var player := _player(int(peer))
		if player != null:
			player.revive(positions[peer])
	_hud.toast("从头再来", 1.4)


# ---------------------------------------------------------------- RPC

@rpc("any_peer", "call_remote", "reliable")
func _rpc_death(medium: int) -> void:
	if not _is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	_declare_dead(sender, medium)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_skill() -> void:
	if not _is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var player := _player(sender)
	if player == null:
		return
	_start_skill(sender, player.element, player.center())


@rpc("any_peer", "call_remote", "reliable")
func _rpc_swap() -> void:
	if not _is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		return
	_swap(sender)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_restart() -> void:
	if not _is_server():
		return
	_restart()


@rpc("authority", "call_remote", "reliable")
func _rpc_mark_dead(peer_id: int, medium: int) -> void:
	_mark_dead(peer_id, medium)


@rpc("authority", "call_remote", "reliable")
func _rpc_respawn(peer_id: int, at: Vector2) -> void:
	var player := _player(peer_id)
	if player != null:
		player.revive(at)


@rpc("authority", "call_remote", "reliable")
func _rpc_elements(table: Dictionary) -> void:
	_apply_elements(table)


@rpc("authority", "call_remote", "reliable")
func _rpc_skill_charge(peer_id: int, kind: int, origin: Vector2) -> void:
	_apply_skill_charge(peer_id, kind, origin)


@rpc("authority", "call_remote", "reliable")
func _rpc_skill_burst(peer_id: int, kind: int, origin: Vector2) -> void:
	_apply_skill_burst(peer_id, kind, origin)


@rpc("authority", "call_remote", "reliable")
func _rpc_break_solid(index: int) -> void:
	var solid := level.solid_at_index(index)
	if solid != null:
		solid.set_broken(true)


@rpc("authority", "call_remote", "reliable")
func _rpc_pickup(index: int, value: int) -> void:
	_apply_pickup(index, value)


@rpc("authority", "call_remote", "reliable")
func _rpc_completed(bonus: int) -> void:
	if _completed:
		return
	_completed = true
	_apply_completed(bonus)


@rpc("authority", "call_remote", "reliable")
func _rpc_restart(positions: Dictionary) -> void:
	_apply_restart(positions)


# ---------------------------------------------------------------- 表现与查询

func _apply_skill_charge(peer_id: int, kind: int, origin: Vector2) -> void:
	Fx.telegraph(_world, origin, kind, SKILL_RADIUS, SKILL_DELAY)


func _apply_skill_burst(peer_id: int, kind: int, origin: Vector2) -> void:
	Fx.burst(_world, origin, kind, SKILL_RADIUS)
	# 霜造不出冰时给出**具体理由**（"脚下没有落脚点"与"这里已经有一块冰了"是两件事，
	# 合起来说"造不出来"等于让人去猜）。判定条件与服务端那段完全一样，
	# 因此"看到这句话"与"冰块没出现"必然同时发生，不会互相矛盾。
	if kind != Element.Kind.FROST:
		return
	var local := _local_player()
	if local == null or local.peer_id != peer_id:
		return
	var placement := ice_placement(origin)
	if not bool(placement.get("ok", false)):
		_hud.toast(String(placement.get("reason", "造不出冰")), 1.6)


func _push_hud() -> void:
	if level == null:
		return
	var me := _local_player()
	var mate := _mate_of(me)
	_hud.set_score(_score)
	_hud.set_elements(me.element if me != null else -1, mate.element if mate != null else -1)
	_hud.set_you_alive(me == null or not me.is_dead())
	_hud.set_mate_alive(mate != null and not mate.is_dead())


func _player(peer_id: int) -> Player:
	for child in _players.get_children():
		var player := child as Player
		if player != null and player.peer_id == peer_id:
			return player
	return null


func _local_player() -> Player:
	for child in _players.get_children():
		var player := child as Player
		if player != null and player.is_local():
			return player
	return null


## 场上的另一个角色。单人游玩时返回 null——2.6 定的单人模式里
## 屏幕上只有一个角色，因此"队友"这个概念在那种情形下不存在。
func _mate_of(player: Player) -> Player:
	if player == null:
		return null
	for child in _players.get_children():
		var other := child as Player
		if other != null and other != player:
			return other
	return null


## 场上的角色按 peer id 排序。只用于日志与调试的可读性；
## "两人同时按交换键等于回到原状"这条性质由服务端串行处理保证（见 request_swap），
## 不依赖这里的顺序。
func _player_order() -> Array[Player]:
	var out: Array[Player] = []
	for child in _players.get_children():
		var player := child as Player
		if player != null:
			out.append(player)
	out.sort_custom(func(a: Player, b: Player) -> bool: return a.peer_id < b.peer_id)
	return out


## 把一件事广播给其余各端。**本地那一遍由调用方自己调**，这里只发远端。
##
## 为什么不用 Node.rpc() 的广播形式：rpc() 会不会在本地也执行一遍，取决于 @rpc 的
## sync 模式（call_remote / call_local），而这一点在不同 Godot 版本上行为并不一致，
## 端上表现就是"特效演两遍"或者"主机自己看不到特效"——两种都极难查，
## 因为它们只在有第二台机器时出现。逐 peer 用 rpc_id 发送把"本地执行"变成显式的：
## 该演一次的地方自己调一次，不存在"顺带又演了一遍"。
func _broadcast(method: StringName, args: Array) -> void:
	for id in multiplayer.get_peers():
		callv("rpc_id", [id, method] + args)


func _is_server() -> bool:
	return Net.role == Net.Role.SERVER


## 实心块的碰撞矩形（世界坐标）。用于"技能半径内有没有它"的判定。
func solid_rect(solid: Solid) -> Rect2:
	return Rect2(solid.global_position, solid.size)


## 点到矩形的距离。点在矩形内时为 0。
## 用它而不是"点到中心"是因为冰墙是个 64×192 的长条：
## 用中心算的话，站在它正下方（贴着墙根）的人会因为离中心太远而够不到它。
func _rect_distance(rect: Rect2, point: Vector2) -> float:
	var far := rect.position + rect.size
	var dx := maxf(maxf(rect.position.x - point.x, 0.0), point.x - far.x)
	var dy := maxf(maxf(rect.position.y - point.y, 0.0), point.y - far.y)
	return Vector2(dx, dy).length()
