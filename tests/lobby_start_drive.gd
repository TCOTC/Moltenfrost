extends Node
## 「等待大厅 → 人齐 → 房主开局 → 两人进同一关」这条路径的驱动器。
##
## 用法（以场景为入口跑一个**客户端**，两个客户端都跑它）：
##   godot --headless --path . res://tests/lobby_start_drive.tscn -- \
##         --join <网关或主机> --port 27015 --lobby [--rename=名字] [--escape]
##
## `--escape` 额外验一段：开局之后房主按 Esc → 两端回到等待房间、房主不变、
## 而且还能再开一局。它是"局中 Esc 不该退出房间"这条需求的自动检查。
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
## 房主要改成的房间名（`--rename=名字`）。空表示不改。
## 它让验证脚本能走完"房主改名 → 目录里那一项跟着变"这条链——
## 房间名是 UTF-8、跨 HTTP 与 JSON 传两跳，光看代码看不出它有没有被截断。
var _rename_to := ""
var _renamed := false
## `--escape`：开局之后房主按 Esc，验"回到等待房间"那一段。
var _escape_test := false
## Esc 那一段的阶段：0=未开始 1=等回大厅 2=再开一局 3=等第二局
var _escape_stage := 0
var _escape_left := 0.0
## 进入 Esc 那一段之前本机是不是房主。回到房间之后要对比它。
var _was_host := false
## Esc 那一段有断言不成立。**收集而不是立刻 quit**：
## 后面还要走"再开一局"才能完整地验"房主身份没丢"，半路退出就查不到那一条。
var _escape_failed := false
## 每一次等段的上限（秒）。
const ESCAPE_SETTLE := 3.0
const ESCAPE_LIMIT := 25.0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--rename="):
			_rename_to = arg.substr("--rename=".length())
		elif arg == "--escape":
			_escape_test = true
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
			if _escape_test:
				_start_escape_test()
			else:
				_finish()
		return

	if _escape_stage > 0:
		_tick_escape(delta)
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
		# 先改名再开局：改名会广播给客户端并刷新目录登记，因此验证脚本能在
		# 客户端那侧与目录那一侧同时看到它。走的是与真人相同的路径
		#（填进输入框 → 提交 → 大厅发信号 → 入口脚本落地）。
		if not _renamed and not _rename_to.is_empty():
			_renamed = true
			print("[drive] 房主改名「%s」" % _rename_to)
			var rename_field: Node = lobby.get_node_or_null(
				"Root/Layout/Body/InfoPanel/InfoMargin/InfoBox/RenameRow/Rename")
			if rename_field is LineEdit:
				(rename_field as LineEdit).text = _rename_to
				lobby.call("_emit_rename")
		_requested = true
		print("[drive] 房主：名单里有 %d 人，请求开局（真人点「开始游戏」走的就是这里）" % count)
		_main.call("_on_lobby_start_requested")

	if _elapsed > WAIT_LIMIT:
		_finished = true
		push_error("[drive] %.0f 秒内没有开局（%s，大厅人数=%d，本机是房主=%s）" % [
			WAIT_LIMIT, _role(), count, is_host,
		])
		get_tree().quit(1)


## 开局之后进入 Esc 那一段。
##
## **只有房主真的按**（与真人一致：无头环境里没人能点，所以由驱动器代按）。
## 另一端什么都不做，它要证明的是"那个通知真的广播到了客户端"——
## 只断言房主那侧不够，因为房主是自己触发的。
func _start_escape_test() -> void:
	var lobby = _main.get("_lobby")
	_was_host = lobby != null and bool(lobby.get("_is_host"))
	_escape_stage = 1
	_escape_left = ESCAPE_LIMIT
	if not _was_host:
		print("[drive] 非房主：等房主按 Esc")
		return
	print("[drive] 房主：按 Esc（应当回到等待房间，而不是离开房间）")
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	_main.call("_unhandled_input", cancel)


func _tick_escape(delta: float) -> void:
	_escape_left -= delta
	var started := bool(_main.get("_game_started"))
	var lobby = _main.get("_lobby")
	match _escape_stage:
		1:
			# 等"回到等待房间"：入口脚本的 _game_started 变回 false、且大厅可见。
			if not started and lobby != null and bool(lobby.get("visible")):
				var count := int(lobby.get("_player_count"))
				# 这三条就是这一段的全部价值：
				#   人还在（不是"离开房间"）、房主没变（_join_order 没被清）、场上没人
				_ok(count >= 2, "回到房间后名单里还有 %d 人（不是离开了房间）" % count)
				_ok(bool(lobby.get("_is_host")) == _was_host,
					"回到房间后房主没变（本机此前是房主=%s）" % _was_host)
				_ok(_player_count() == 0, "回到房间后场上没有角色（实际 %d 个）" % _player_count())
				print("[drive] 回到等待房间：%s" % _role())
				_escape_stage = 2
				_escape_left = ESCAPE_SETTLE
				return
		2:
			if _escape_left > 0.0:
				return
			# 再开一局。这一步验的是 _join_order 没被清：清掉的话 host_id() 会变成 0，
			# 房主自己也不再是房主，于是谁也开不了下一局（而界面上只是按钮变灰）。
			if _was_host:
				print("[drive] 房主：再开一局（验房主身份没丢）")
				_main.call("_on_lobby_start_requested")
			_escape_stage = 3
			_escape_left = ESCAPE_LIMIT
			return
		3:
			if started:
				print("[drive] 第二局已开始：%s" % _role())
				_ok(_player_count() == 2, "第二局场上也是 2 个角色（实际 %d 个）" % _player_count())
				_finish()
				return
	if _escape_left > 0.0:
		return
	_escape_failed = true
	push_error("[drive] Esc 那一段在第 %d 步超时（%s，已开局=%s）" % [
		_escape_stage, _role(), started,
	])
	_finish()


func _ok(condition: bool, message: String) -> void:
	if condition:
		print("[drive] OK: %s" % message)
		return
	_escape_failed = true
	push_error("[drive] 失败：%s" % message)


func _finish() -> void:
	_finished = true
	var players := _player_count()
	print("[drive] %s：场上角色 %d 个" % [_role(), players])
	if players < 2:
		push_error("[drive] %s：开局之后场上只有 %d 个角色（期望 %d）" % [_role(), players, 2])
		get_tree().quit(1)
		return
	if _escape_failed:
		push_error("[drive] %s：Esc 那一段有断言不成立（见上面的失败行）" % _role())
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
