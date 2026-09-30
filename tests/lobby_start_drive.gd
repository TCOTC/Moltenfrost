extends Node
## 「等待大厅 → 人齐 → 房主开局 → 两人进同一关」这条路径的驱动器。
##
## 用法（以场景为入口跑一个**客户端**，两个客户端都跑它）：
##   godot --headless --path . res://tests/lobby_start_drive.tscn -- \
##         --join <网关或主机> --port 27015 --lobby
##
## 为什么要它：headless 的客户端点不了按钮，而"人齐才允许开始"是需求的核心，
## 而 tools/net-smoke.mjs 走的全是 `--host`/`--join` 的"连上即开局"，
## 因此这条路径原先没有任何自动检查覆盖。
##
## 两个客户端跑同一个场景，各自按自己的角色行事：
##   房主  —— 看到 ≥2 人时请求开局（就是真人点那个按钮会走的那条路）
##   非房主 —— 什么都不做，只等开局通知
## 两边的断言是一样的：`_game_started` 变真 + 场上出现 2 个角色。
## 非房主那一边同时证明了**开局通知真的广播到了客户端**（只断言房主那侧不够）。
##
## 退出码 0 表示通过。

const MAIN_SCENE := preload("res://scenes/main.tscn")
## 等开局的上限。要容得下：连上（约 1 秒）+ 名单下发 + 另一个客户端进来 + 生成包往返。
const WAIT_LIMIT := 40.0
## 开局之后等生成包的时间。
const SETTLE := 2.0

var _main: Node = null
var _elapsed := 0.0
var _settle_left := -1.0
var _finished := false
var _requested := false
var _diag_left := 0.0
var _frames := 0


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	# **必须挂到 /root 下、并延用 "Main" 这个名字。**
	# 入口脚本上的 @rpc 走的是固定路径 /root/Main（与 Game 的 /root/Main/Game 同理），
	# 路径对不上时 RPC 是**静默失败**的——不报错，只是什么都没发生。
	# 挂在驱动器下面时路径成了 /root/LobbyStartDrive/Main，于是客户端永远收不到大厅名单
	# （实测：服务端日志里名单一直是对的，而客户端只有一句“已连接到主机”）。
	get_tree().root.add_child.call_deferred(_main)
	_main.name = "Main"


func _process(delta: float) -> void:
	# 无条件打一行首帧诊断，**放在所有 return 之前**：这条路径上一旦某个判据提前返回，
	# 后面那些带条件的日志都打不出来，现象就是"驱动器一行都没输出"。
	# 已实测踩到：加了周期自查却排在 `lobby == null` 的 return 之后，什么也看不到。
	_frames += 1
	if _frames == 1 or _frames == 300:
		print("[drive] 第 %d 帧：main=%s lobby=%s（进程在跑，脚本已加载）" % [
			_frames, _main != null,
			_main != null and _main.get("_lobby") != null,
		])
	if _finished:
		return
	_elapsed += delta

	if _settle_left > 0.0:
		_settle_left -= delta
		if _settle_left <= 0.0:
			_finish()
		return

	var started := bool(_main.get("_game_started"))
	if started:
		print("[drive] 对局已开始（%s）。等 %.1f 秒让生成包到达" % [_role(), SETTLE])
		_settle_left = SETTLE
		return

	var lobby = _main.get("_lobby")
	if lobby == null:
		return
	var count := int(lobby.get("_player_count"))
	var is_host := bool(lobby.get("_is_host"))
	# 周期性把自己的判断依据打出来。两个"我是不是房主"的判据是分开实现的
	#（入口脚本的 is_local_host() 比下发的那份 id，大厅的 _is_host 看名单里哪一行
	# 同时是 you 与 host），两者不一致时现象是"日志说我是房主，但按钮没反应"，
	# 而只有把这两个值并排打出来才看得见是哪一个不对。
	_diag_left -= delta
	if _diag_left <= 0.0:
		_diag_left = 5.0
		print("[drive] 自查：大厅人数=%d 大厅判我=%s 入口脚本判我=%s 已开局=%s" % [
			count, is_host, bool(_main.call("is_local_host")), started,
		])
	if is_host and not _requested and count >= 2:
		_requested = true
		print("[drive] 房主：名单里有 %d 人，请求开局（真人点「开始游戏」走的就是这里）" % count)
		_main.call("_on_lobby_start_requested")

	if _elapsed > WAIT_LIMIT:
		_finished = true
		push_error("[drive] %.0f 秒内没有开局（%s，大厅人数=%d，本机是房主=%s）" % [
			WAIT_LIMIT, _role(), count, is_host,
		])
		get_tree().quit(1)


func _finish() -> void:
	_finished = true
	var players := _player_count()
	print("[drive] %s：场上角色 %d 个" % [_role(), players])
	if players < 2:
		push_error("[drive] %s：开局之后场上只有 %d 个角色（期望 %d）" % [_role(), players, 2])
		get_tree().quit(1)
		return
	print("[drive] %s：通过" % _role())
	get_tree().quit(0)


## 本机在这次对局里的角色。用它区分两端的日志，排查时一眼看得出是谁。
func _role() -> String:
	return "房主" if _requested else "非房主"


func _player_count() -> int:
	var count := 0
	for child in _main.get_node("Players").get_children():
		if child is Player:
			count += 1
	return count
