extends SceneTree
## LanDiscovery 的行为测试。用 `--script` 直接跑，不需要测试框架：
##
##   godot --headless --path . --script tests/lan_discovery_test.gd
##
## 退出码 0 表示全部通过。tools/net-smoke.mjs 会先跑这个与插值测试，再做双实例检查。
##
## 覆盖三件事：
##   1. 报文的编解码，以及对外来内容的拒绝（这个端口可能收到别的程序的包）
##   2. 真实的 UDP 路径：一个套接字广播、另一个套接字接收。
##      同一台机器上多开实例能不能互相发现，就靠这一条验证；
##      而"多开实例"既是开发时的调试方式，也是这个自动检查的前提。
##   3. 主机停止广播之后，房间会因超时从列表里移除
##
## 覆盖不到的：跨机器的广播是否被防火墙放行，那只能由两台真机验证。
## 因此这里的门限放宽到四秒（广播间隔一秒），允许丢一个包。

const Discovery := preload("res://scripts/net/lan_discovery.gd")

## 自检用的隔离取值，避免与正常运行时互相影响。
const TEST_ROOM_NAME := "自检房间"
const TEST_ROOM_PORT := 27199
## 自检用的探测端口，避开默认的 27016：开发时编辑器里运行的实例也停在初始界面、
## 也绑定那个端口，用它就会以「无法监听」失败，而那行错误看起来像探测功能坏了。
## 三个自检脚本串行执行，因此共用这一个值不会冲突。
const TEST_DISCOVERY_PORT := 27119
## 房间超时取小一点，让这个检查不必真等三秒。它比广播间隔短没关系——
## 这里只验证"没有广播就会过期"，而这一路是在停掉广播之后才计的。
const TEST_ROOM_TTL := 1.0
## 等待房间出现或过期的上限（秒）。
const WAIT_LIMIT := 4.0

const STAGE_LISTEN := 0
const STAGE_ROOM_APPEARS := 1
const STAGE_ROOM_EXPIRES := 2
const STAGE_DONE := 3

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _finished: bool = false
var _stage: int = STAGE_LISTEN
var _stage_elapsed: float = 0.0
var _listener: LanDiscovery = null
var _announcer: LanDiscovery = null
## 最近一次收到的房间列表，由 rooms_changed 写入。
var _latest: Array = []


func _process(delta: float) -> bool:
	if _finished:
		return true
	_stage_elapsed += delta

	if _stage == STAGE_LISTEN:
		_case_beacon_codec()
		_start_sockets()
		_next_stage(STAGE_ROOM_APPEARS)
		return false

	if _stage == STAGE_ROOM_APPEARS:
		if not _latest.is_empty():
			_case_received_room()
			# 停掉广播，接下来验证超时清理。
			_announcer.stop_announcing()
			_next_stage(STAGE_ROOM_EXPIRES)
		elif _stage_elapsed > WAIT_LIMIT:
			_fail("广播之后 %.1f 秒内没有在列表里看到房间（本机发出的广播可能被系统丢弃了）" % WAIT_LIMIT)
			_finish()
		return false

	if _stage == STAGE_ROOM_EXPIRES:
		if _latest.is_empty():
			_ok(true, "停止广播后房间在超时时间内从列表里移除")
			_next_stage(STAGE_DONE)
		elif _stage_elapsed > TEST_ROOM_TTL + WAIT_LIMIT:
			_fail("停止广播后房间没有移除（等了 %.1f 秒）" % (TEST_ROOM_TTL + WAIT_LIMIT))
			_finish()
		return false

	_finish()
	return false


# ---------------------------------------------------------------- 步骤

func _start_sockets() -> void:
	Discovery.discovery_port = TEST_DISCOVERY_PORT
	_listener = Discovery.new()
	_listener.room_ttl = TEST_ROOM_TTL
	_listener.rooms_changed.connect(_on_rooms_changed)
	root.add_child(_listener)
	_ok(_listener.listen_for_rooms(), "监听探测端口应当成功（端口被占用时这里会失败）")

	_announcer = Discovery.new()
	root.add_child(_announcer)
	# announce() 会立刻发一次，因此不必在这里等一个广播间隔。
	_announcer.announce(func() -> Dictionary:
		return {"name": TEST_ROOM_NAME, "port": TEST_ROOM_PORT, "players": 1})


func _case_beacon_codec() -> void:
	# 逐字段比较而不是整体比较字典：JSON 里的数字解析回来是浮点，与写进去的整数
	# 不是同一种类型，整体比较的结论依赖引擎内部的比较规则，不适合作为断言。
	var decoded := Discovery.decode_beacon(Discovery.encode_beacon(
		{"name": "甲的房间", "port": 27015, "players": 2}))
	_ok(String(decoded.get("name", "")) == "甲的房间", "房间名应当原样往返")
	_ok(int(decoded.get("port", 0)) == 27015, "端口应当原样往返，实际 %s" % decoded.get("port", 0))
	_ok(int(decoded.get("players", 0)) == 2, "人数应当原样往返")

	# 这个端口可能收到别的程序的包，也可能收到旧版本的本程序发来的包，两类都必须忽略。
	_ok(Discovery.decode_beacon("别的程序的报文".to_utf8_buffer()).is_empty(), "不认识的前缀应当被忽略")
	_ok(Discovery.decode_beacon("MOLTENFROST/99 {\"port\":27015}".to_utf8_buffer()).is_empty(), "协议版本不同应当被忽略")
	_ok(Discovery.decode_beacon("MOLTENFROST/1 不是 JSON".to_utf8_buffer()).is_empty(), "内容不是 JSON 应当被忽略")
	_ok(Discovery.decode_beacon("MOLTENFROST/1 [1, 2]".to_utf8_buffer()).is_empty(), "内容不是对象应当被忽略")


func _case_received_room() -> void:
	_ok(_latest.size() == 1, "应当只看到一个房间，实际 %d 个" % _latest.size())
	var room: Dictionary = _latest[0]
	_ok(String(room.get("name", "")) == TEST_ROOM_NAME, "房间名应当来自广播，实际「%s」" % room.get("name", ""))
	_ok(int(room.get("port", 0)) == TEST_ROOM_PORT, "游戏端口应当来自广播，实际 %d" % room.get("port", 0))
	# 地址必须是能用来连接的真实地址，而不是空串或 0.0.0.0。
	var address := String(room.get("address", ""))
	_ok(not address.is_empty() and address != "0.0.0.0", "房间地址应当是发出广播的那台机器的地址，实际「%s」" % address)


# ---------------------------------------------------------------- 收尾

func _on_rooms_changed(listed: Array) -> void:
	_latest = listed


func _next_stage(stage: int) -> void:
	_stage = stage
	_stage_elapsed = 0.0


func _finish() -> void:
	_finished = true
	_announcer.stop()
	_listener.stop()
	if _failures.is_empty():
		print("局域网房间探测测试通过（%d 项断言）。" % _checks)
		quit(0)
	else:
		print("局域网房间探测测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		quit(1)


func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _fail(message: String) -> void:
	_failures.append(message)
