extends SceneTree
## 初始界面的接线测试。用 `--script` 直接跑，不需要显示服务器，也不需要测试框架：
##
##   godot --headless --path . --script tests/menu_test.gd
##
## 界面长什么样要人眼看，但"按钮点下去有没有发出正确的信号"只能靠这一层验证：
## 房间列表用真实的 UDP 广播填充，因此这一项顺带覆盖了"探测到的房间能正确显示、并能按它加入"。
## 退出码 0 表示全部通过，tools/net-smoke.mjs 会把它当作前置检查之一。

const MENU_SCENE := preload("res://scenes/menu.tscn")
const Discovery := preload("res://scripts/net/lan_discovery.gd")

## 官方房间的域名。这里**有意重复**写一份而不是读 MainMenu.OFFICIAL_HOST：
## 若两边一起写错（例如域名拼错），读常量就只是自己跟自己对答案，断言会通过而实际连不上。
## 独立写一份才能发现改动被漏掉。域名一旦更换，这里也要改——这是刻意的代价。
const OFFICIAL_HOST := "moltenfrost-server.mytemos.com"

## 自检取值，避开开发时常用的 27015。界面上的默认端口与广播里的游戏端口刻意取不同值，
## 这样"加入房间时用的是房间自带的端口"才是一个有内容的断言。
const MENU_PORT := 27121
const ROOM_PORT := 27122
## 自检用的探测端口。开发时编辑器里运行的实例也停在初始界面、也绑定默认的那个端口，
## 不换端口就会因「无法监听」失败。
const TEST_DISCOVERY_PORT := 27119
const ROOM_NAME := "菜单自检房间"
const NOT_A_PORT := "不是端口"
const CUSTOM_ROOM_NAME := "  自检改过的房名  "
const WAIT_LIMIT := 5.0

const STAGE_SETUP := 0
const STAGE_WAIT_ROOM := 1
const STAGE_ACTIONS := 2

var _menu: Node = null
var _announcer: LanDiscovery = null
var _host_calls: Array = []
var _join_calls: Array = []
var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _finished: bool = false
var _stage: int = STAGE_SETUP
var _stage_elapsed: float = 0.0


func _process(delta: float) -> bool:
	if _finished:
		return true
	_stage_elapsed += delta
	match _stage:
		STAGE_SETUP:
			_case_setup()
			_next_stage(STAGE_WAIT_ROOM)
		STAGE_WAIT_ROOM:
			# 阶段只在下一帧开头推进：在同一帧里先推进再判结束，动作那一段会被跳过。
			if _case_room_listed():
				_next_stage(STAGE_ACTIONS)
		STAGE_ACTIONS:
			_case_actions()
			_finish()
	return false


# ---------------------------------------------------------------- 步骤

func _case_setup() -> void:
	# 探测端口要在界面创建之前改：listen_for_rooms() 在 open() 时就会绑定它。
	Discovery.discovery_port = TEST_DISCOVERY_PORT
	_menu = MENU_SCENE.instantiate()
	root.add_child(_menu)
	_menu.host_requested.connect(func(room_name: String, port: int) -> void:
		_host_calls.append([room_name, port]))
	_menu.join_requested.connect(func(address: String, port: int) -> void:
		_join_calls.append([address, port]))
	_ok(not _menu.visible, "初始界面上场时应当是隐藏的（何时打开由入口脚本决定）")
	_menu.open(MENU_PORT)
	_ok(_menu.visible, "open() 之后界面应当可见")
	_ok(_line("DirectRow/Port").text == str(MENU_PORT), "端口应当预填默认值，实际「%s」" % _line("DirectRow/Port").text)
	_ok(not _line("HostRow/RoomName").text.is_empty(), "房间名应当有默认值")
	_ok(_button("RoomButtons/Join").disabled, "没有选中房间时，加入按钮应当是灰的")
	# 起一个广播源，模拟另一台机器已经创建了房间。这里走的是真实 UDP 路径。
	_announcer = Discovery.new()
	root.add_child(_announcer)
	_announcer.announce(func() -> Dictionary:
		return {"name": ROOM_NAME, "port": ROOM_PORT, "players": 2})


func _case_room_listed() -> bool:
	# 官方房间是固定条目、一直在列表里，所以"列表非空"不是判据；
	# 要等的是**探测到的那个**房间出现。
	if _lan_count() == 0:
		if _stage_elapsed > WAIT_LIMIT:
			_fail("广播之后 %.1f 秒内列表里没有出现局域网房间（当前共 %d 项）" % [WAIT_LIMIT, _list().item_count])
			return true
		return false

	_ok(_list().item_count == 2, "应当有官方房间与一个探测到的房间，实际 %d 项" % _list().item_count)

	# 固定条目必须排在最前：它不随每秒的刷新而移动，玩家刚点中的项就不会跳走位置。
	var first: Dictionary = _list().get_item_metadata(0)
	_ok(bool(first.get("official", false)), "列表第一项应当是官方房间")
	_ok(String(first.get("address", "")) == OFFICIAL_HOST, "官方房间的地址应当是内置域名，实际「%s」" % first.get("address", ""))
	_ok(int(first.get("port", 0)) == Net.DEFAULT_PORT, "官方房间的端口应当是默认游戏端口，实际 %d" % int(first.get("port", 0)))
	_ok(_list().get_item_text(0).contains("公网"), "官方房间的文案应当标明是公网，实际「%s」" % _list().get_item_text(0))

	# 加入官方房间：地址与端口都来自固定条目，与界面上的输入框无关。
	_select(0)
	_ok(not _button("RoomButtons/Join").disabled, "选中官方房间之后加入按钮应当可用")
	_button("RoomButtons/Join").pressed.emit()
	_ok(_join_calls.size() == 1, "选中官方房间后点加入应当发出一次 join_requested，实际 %d 次" % _join_calls.size())
	if _join_calls.size() == 1:
		_ok(String(_join_calls[0][0]) == OFFICIAL_HOST, "官方房间的加入地址应当是内置域名，实际「%s」" % _join_calls[0][0])
		_ok(int(_join_calls[0][1]) == Net.DEFAULT_PORT, "官方房间的加入端口应当是默认游戏端口，实际 %d" % int(_join_calls[0][1]))

	# 加入探测到的房间：端口必须取自房间，而不是界面上的默认端口。
	# 这两个值在测试里刻意取成不同，这样这一条才是有内容的断言。
	var lan_index := _lan_index()
	_ok(lan_index > 0, "探测到的房间应当排在官方房间之后，实际下标 %d" % lan_index)
	_select(lan_index)
	_button("RoomButtons/Join").pressed.emit()
	_ok(_join_calls.size() == 2, "再加入探测到的房间应当发出第二次 join_requested，实际 %d 次" % _join_calls.size())
	if _join_calls.size() == 2:
		var address := String(_join_calls[1][0])
		_ok(not address.is_empty() and address != "0.0.0.0", "加入的地址应当是收到广播的那个地址，实际「%s」" % address)
		_ok(int(_join_calls[1][1]) == ROOM_PORT, "加入的端口应当取自房间而不是界面上的默认值，实际 %d" % int(_join_calls[1][1]))
	return true


## 选中某一项。select() 不保证发出 item_selected，显式补一次，
## 让选中状态与真人点击的行为一致（_selected 是在那个信号里写入的）。
func _select(index: int) -> void:
	_list().select(index)
	_list().emit_signal("item_selected", index)


## 探测到的房间数量（不含官方房间）。
func _lan_count() -> int:
	var count := 0
	for i in _list().item_count:
		var meta = _list().get_item_metadata(i)
		if meta is Dictionary and not bool((meta as Dictionary).get("official", false)):
			count += 1
	return count


## 第一个探测到的房间的下标，没有则返回 -1。
func _lan_index() -> int:
	for i in _list().item_count:
		var meta = _list().get_item_metadata(i)
		if meta is Dictionary and not bool((meta as Dictionary).get("official", false)):
			return i
	return -1


func _case_actions() -> void:
	# 端口填错：不发信号，只在状态栏提示。
	_line("DirectRow/Port").text = NOT_A_PORT
	_button("HostRow/Host").pressed.emit()
	_ok(_host_calls.is_empty(), "端口不是数字时，创建房间不应当发出信号")
	_ok(not _status().text.is_empty(), "端口不合法时状态栏应当给出提示")

	# 创建房间：房间名要去掉首尾空白，端口取输入框里的值。
	_line("DirectRow/Port").text = str(MENU_PORT)
	_line("HostRow/RoomName").text = CUSTOM_ROOM_NAME
	_button("HostRow/Host").pressed.emit()
	_ok(_host_calls.size() == 1, "点创建房间应当发出一次 host_requested，实际 %d 次" % _host_calls.size())
	if _host_calls.size() == 1:
		_ok(String(_host_calls[0][0]) == CUSTOM_ROOM_NAME.strip_edges(), "房间名应当去掉首尾空白，实际「%s」" % _host_calls[0][0])
		_ok(int(_host_calls[0][1]) == MENU_PORT, "端口应当取自输入框，实际 %d" % int(_host_calls[0][1]))

	# 手动加入：地址与端口都取自输入框。
	# 计数用"调用前先记一笔"的方式，不写死序号——上一个阶段已经发过两次 join_requested，
	# 写死序号会让这一条在别的断言增删之后悄悄失效。
	var before := _join_calls.size()
	_line("DirectRow/Address").text = "127.0.0.1"
	_line("DirectRow/Port").text = str(MENU_PORT)
	_button("DirectRow/Direct").pressed.emit()
	_ok(_join_calls.size() == before + 1, "手动填地址后点加入应当再发一次 join_requested，实际增了 %d 次" % (_join_calls.size() - before))
	if _join_calls.size() == before + 1:
		var call: Array = _join_calls[before]
		_ok(String(call[0]) == "127.0.0.1", "手动加入的地址应当取自输入框，实际「%s」" % call[0])
		_ok(int(call[1]) == MENU_PORT, "手动加入的端口应当取自输入框，实际 %d" % int(call[1]))

	_menu.close()
	_ok(not _menu.visible, "close() 之后界面应当隐藏")


# ---------------------------------------------------------------- 收尾与节点定位

func _finish() -> void:
	_finished = true
	_announcer.stop()
	_menu.close()
	if _failures.is_empty():
		print("初始界面接线测试通过（%d 项断言）。" % _checks)
		quit(0)
	else:
		print("初始界面接线测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		quit(1)


## 界面里的节点路径按 boxes 拼。写成一层 helper 是为了让断言读起来只剩节点名。
func _line(path: String) -> LineEdit:
	return _menu.get_node("Center/Panel/Margin/Box/" + path)


func _button(path: String) -> Button:
	return _menu.get_node("Center/Panel/Margin/Box/" + path)


func _list() -> ItemList:
	return _menu.get_node("Center/Panel/Margin/Box/Rooms")


func _status() -> Label:
	return _menu.get_node("Center/Panel/Margin/Box/Status")


func _next_stage(stage: int) -> void:
	_stage = stage
	_stage_elapsed = 0.0


func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _fail(message: String) -> void:
	_failures.append(message)
