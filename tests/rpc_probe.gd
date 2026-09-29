extends Node
## RPC 送达探针：确认 `Game._broadcast()` 那条路真能把对局事件送到对端。
##
##   godot --headless --path . res://tests/rpc_probe.tscn -- --host --port 27133
##   godot --headless --path . res://tests/rpc_probe.tscn -- --join 127.0.0.1 --port 27133
##
## 为什么需要单独一个探针：`Game._broadcast()` 是**绕开 `Node.rpc()`** 自己写的，
## 它逐 peer 调 `rpc_id`（理由见 game.gd）。这条路一旦不通，症状是"对端什么都看不到"，
## 而且**不报任何错**——本地单机测试与单元测试全都覆盖不到它，只有两台机器一起跑才看得出来。
##
## 探针复用的是真正的对局 RPC：服务端按正常流程广播一次"拿到积分"，
## 客户端应当在自己的计分上看到同一个数。用真 RPC 而不是自己再写一条测试用的，
## 是因为要验证的正是"这条既有路径有没有通"。
##
## 退出码 0 表示客户端收到了；服务端由 net-smoke 结束。

const MAIN_SCENE := preload("res://scenes/main.tscn")

## 与服务端约定好的广播内容。取一个不会与真实拾取混淆的下标（关卡只有一个积分点）。
const PROBE_INDEX := 7
const PROBE_VALUE := 35
## 等多久还没收到就判定失败。
const WAIT_LIMIT := 8.0

var _game: Game = null
var _elapsed: float = 0.0
var _done: bool = false


func _ready() -> void:
	add_child(MAIN_SCENE.instantiate())
	_game = get_node("Main/Game") as Game
	if Net.role == Net.Role.SERVER:
		# 等对端连上再广播。连上之前没有 peer，_broadcast 会静默地什么都不做。
		multiplayer.peer_connected.connect(func(_id: int) -> void: _send())


func _send() -> void:
	# 走的就是真实路径：本地先应用一次，再逐 peer 发出去。
	_game.call("_broadcast_pickup", PROBE_INDEX, PROBE_VALUE)
	print("[probe] 服务端已广播积分 +%d" % PROBE_VALUE)


func _process(delta: float) -> void:
	if _done or Net.role != Net.Role.CLIENT:
		return
	_elapsed += delta
	if _game.score() >= PROBE_VALUE:
		_done = true
		print("[probe] 探针：客户端收到积分同步（score=%d）" % _game.score())
		get_tree().quit(0)
		return
	if _elapsed > WAIT_LIMIT:
		_done = true
		push_error("[probe] 探针：%.0f 秒内没有收到对局事件，_broadcast 这条路可能没通" % WAIT_LIMIT)
		get_tree().quit(1)
