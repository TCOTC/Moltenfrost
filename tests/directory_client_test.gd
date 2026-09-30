extends SceneTree
## 目录客户端的接线测试，重点是**认领不能被丢掉**。
##
## 真机上踩到过：点「创建房间」之后界面永久停在「正在向官方服务器要一间房…」，
## 而服务器日志里**根本没有那次请求**。原因是 `claim_room()` 在 `_mode != ""` 时
## 直接 return，于是在飞的那个请求（界面每 3 秒拉一次列表）会把认领吞掉，
## 界面那边却已经把自己锁住了。
##
## 这条只有对着**真目录**才测得出来：要断言的是"请求真的发出去了、回信真的到了"，
## 而替身（tests/menu_test.gd 里那个）恰好把这两件事都跳过了。
##
## 由 tools/directory-client-check.mjs 起一个真目录并把基址传进来：
##   godot --headless --path . --script tests/directory_client_test.gd -- \
##         --base http://127.0.0.1:27123 --expect-port 40231
##
## 退出码 0 表示全部通过。

const DirectoryClientScript := preload("res://scripts/net/directory_client.gd")

## 每一步的等待上限（秒）。认领最坏情况要等目录那边补一间，给它宽一点。
const STEP_TIMEOUT := 20.0

var _base := ""
var _expect_port := 0

var _checks := 0
var _failures := PackedStringArray()

## 故意不写类型：`claim_finished` / `fetch_rooms` 都是脚本上的方法，
## 而这一层要验的就是"这些方法按约定的方式被调用"，不必要额外的类型约束。
var _client = null
var _probe = null

var _claims: Array = []
var _listed: Array = []
var _claim_port := 0
var _stage := 0
var _stage_elapsed := 0.0
var _finished := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--base" and i + 1 < args.size():
			_base = String(args[i + 1])
		elif args[i] == "--expect-port" and i + 1 < args.size():
			_expect_port = int(args[i + 1])


func _process(delta: float) -> bool:
	if _finished:
		return true
	_stage_elapsed += delta
	if _stage_elapsed > STEP_TIMEOUT:
		_fail("第 %d 步等了 %.0f 秒没有结果" % [_stage, STEP_TIMEOUT])
		_finish()
		return true
	match _stage:
		0:
			_setup()
		# 认领的结果必须到（这一步就是真机上的那个 bug）
		1:
			_wait_claim()
		# 用另一个客户端拉一次列表，确认服务器那边**确实**收到了这次认领
		2:
			_probe_list()
		3:
			_wait_list()
		# 认领排队在**认领**后面（不只是排在列表后面）
		4:
			_queue_two_claims()
		5:
			_wait_two_claims()
		_:
			_finish()
	return false


# ---------------------------------------------------------------- 步骤

func _setup() -> void:
	if _base.is_empty() or _expect_port <= 0:
		_fail("没有拿到 --base / --expect-port，检查 tools/directory-client-check.mjs 的调用")
		_finish()
		return
	_client = DirectoryClientScript.new()
	root.add_child(_client)
	_client.claim_finished.connect(_on_claim_finished)
	# **起一个列表请求，紧接着就认领**——这正是真机上的那一刻：
	# 界面的定期刷新还在飞，玩家点了「创建房间」。
	_client.fetch_rooms(_base)
	_client.claim_room(_base)
	_next_stage()


func _wait_claim() -> void:
	if _claims.is_empty():
		return
	var result: Dictionary = _claims[0]
	_ok(bool(result.get("ok", false)), "列表请求在飞时发起的认领也拿到了房间（实际 %s）" % result)
	_claim_port = int(result.get("port", 0))
	_ok(_claim_port == _expect_port, "拿到的应当是目录里那一间（期望 %d，实际 %d）" % [_expect_port, _claim_port])
	_next_stage()


func _probe_list() -> void:
	_probe = DirectoryClientScript.new()
	root.add_child(_probe)
	_probe.rooms_fetched.connect(_on_rooms_fetched)
	_probe.fetch_rooms(_base)
	_next_stage()


func _wait_list() -> void:
	if _listed.is_empty():
		return
	var ports: Array = []
	for item in _listed:
		if item is Dictionary:
			ports.append(int((item as Dictionary).get("port", 0)))
	# 被认领的房间**必须出现在公开列表里**：这条同时证明了三件事——
	# 请求确实发到了服务器、目录把它算作"非空闲"、别人因此才看得到它。
	_ok(ports.has(_claim_port),
		"被认领的房间应当出现在公开列表里（列表里是 %s，认领到的是 %d）" % [ports, _claim_port])
	_next_stage()


func _queue_two_claims() -> void:
	# 连着两次认领：第二次一定在第一次的结果之前发生（第一次还在飞），
	# 因此它必须被排队而不是被吞掉。
	_client.claim_room(_base)
	_client.claim_room(_base)
	_next_stage()


func _wait_two_claims() -> void:
	# 1 次（前面那次）+ 2 次 = 3 次结果。此时那间房已被认领并保留着，
	# 所以后两次回答 `waiting` 是正常的——这里要断言的只是**回信到了**。
	if _claims.size() < 3:
		return
	_ok(true, "连着两次认领都收到了回信（收到 %d 次结果）" % _claims.size())
	_finish()


func _on_claim_finished(result: Dictionary) -> void:
	_claims.append(result)


func _on_rooms_fetched(rooms: Array) -> void:
	_listed = rooms


# ---------------------------------------------------------------- 断言与收尾

func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  ok  %s" % message)
	else:
		print("  --  %s" % message)
		_failures.append(message)


func _fail(message: String) -> void:
	_checks += 1
	print("  --  %s" % message)
	_failures.append(message)


func _next_stage() -> void:
	_stage += 1
	_stage_elapsed = 0.0


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if _failures.is_empty():
		print("目录客户端接线测试通过（%d 项断言）。" % _checks)
		quit(0)
	else:
		print("目录客户端接线测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		quit(1)
