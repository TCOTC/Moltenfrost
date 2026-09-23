class_name ExitPortal
extends Area3D
## 出口：全部玩家同时位于范围内即通关。
##
## 判定放在服务端，理由与按钮、门相同：它需要「所有人分别在哪」这个全局事实。
## 客户端只接收通关结果用于显示（延迟一个往返，可接受）。
##
## 为什么出口要求的是「全部玩家同时在内」而不是「有人到达」：这是关卡里唯一
## 无法由一个人取巧完成的判据——即使两人能走同一条路，也必须一起走完最后一段。
## 它与按钮的区别在于按钮可以锁存，而通关不能：先到的人不能替后到的人签退。

## 通关时发出。参数是触发时的玩家数。
signal cleared(player_count: int)

## 判定所需的最少人数。设为 2 是因为本作是双人协作；若将来支持单人加 AI 同伴，
## 这里要改为「按参与人数」而不是固定值。
const MIN_PLAYERS := 2

var is_cleared: bool = false


func _ready() -> void:
	# 这里不用在 _ready 里判断 Net.is_server() 来决定是否处理：
	# 本节点先于 main.gd 的 _ready 就绪，那时还没建立会话，
	# 而离线状态下 is_server() 同样返回 true（见 net.gd）。改为每帧判断。
	pass


func _physics_process(_delta: float) -> void:
	if is_cleared or not Net.is_server():
		return
	var players := get_tree().get_nodes_in_group(Player.GROUP_NAME)
	if players.size() < MIN_PLAYERS:
		return
	# 逐个核对：任何一个不在范围内都不算通关。
	# 用 overlaps_body 而不是自己维护进出名单，是因为名单在掉线、复位、瞬移时都要跟着修，
	# 而这些恰好是联机里最容易出错的地方。
	for node in players:
		if not (node is Player):
			return
		if not overlaps_body(node as Player):
			return
	_apply_cleared.rpc(players.size())


## 通关广播。可靠传输：这是整局的目标状态，丢一次就会有一端看不到通关。
@rpc("authority", "call_local", "reliable")
func _apply_cleared(player_count: int) -> void:
	if is_cleared:
		return
	is_cleared = true
	print("[exit] 全部 %d 名玩家到达出口，本关通关" % player_count)
	cleared.emit(player_count)
