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

## 官方房间的地址来源变了：以前是界面里的一个常量（测试有意重复写一份），
## 现在是 config/product.cfg + 目录返回的列表。因此这里不再重复那个字面量，而是分两层断言：
##   1. 界面用的是 ProductConfig 解析出来的值（接线正确）
##   2. 那个值本身像个主机名（属性检查，不依赖配置文件的内容）
## 第 2 层取代了原来的"重复一份常量"：重复常量只能防住"改了一处忘了另一处"，
## 而属性检查能防住"配置文件被改成了不合法的值"，覆盖面更宽也更有意义。

## 官方服务器（目录与房间在同一台机器上）的地址。**有意重复写一份**：
## 上面那条注释说的是"不重复 ProductConfig 的取值"，而这里重复的是
## 目录返回的**数据**（那是网络来的，不是配置里的），因此不矛盾——
## 喂进去的 host 与断言用的 host 必须是同一个字面量，否则测不出接线错。
const OFFICIAL_HOST := "mf.example.com"
const OFFICIAL_ROOM_PORT := 40001
const OFFICIAL_FULL_PORT := 40002
const OFFICIAL_PLAYING_PORT := 40003

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
const STAGE_DIRECTORY := 3

## 目录客户端的替身。
##
## **自检不能真的去要一间房**：认领是一次写操作，它会连上官方服务器、把一间房邻走，
## 既让测试结果取决于外网，也会影响真在玩的人。取列表那一半同理（原来是真的发了，
## 只是读操作没人注意）。这里两样都只记下"被调用了"，数据由测试自己喂给 _on_* 处理，
## 与 _case_room_listed 里那句"用喂数据而不是真起一个 HTTP 服务"是同一个做法。
class DirectorySpy extends DirectoryClient:
	var fetches: Array = []
	var claims: Array = []

	func fetch_rooms(base: String) -> void:
		fetches.append(base)

	func claim_room(base: String) -> void:
		claims.append(base)


var _menu: Node = null
var _announcer: LanDiscovery = null
var _spy: DirectorySpy = null
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
			_next_stage(STAGE_DIRECTORY)
		STAGE_DIRECTORY:
			_case_directory_down()
			_finish()
	return false


# ---------------------------------------------------------------- 步骤

func _case_setup() -> void:
	# 探测端口要在界面创建之前改：listen_for_rooms() 在 open() 时就会绑定它。
	Discovery.discovery_port = TEST_DISCOVERY_PORT
	_menu = MENU_SCENE.instantiate()
	root.add_child(_menu)
	_menu.host_requested.connect(func(room_name: String, port: int, kind: int) -> void:
		_host_calls.append([room_name, port, kind]))
	_menu.join_requested.connect(func(address: String, port: int, kind: int) -> void:
		_join_calls.append([address, port, kind]))
	_ok(not _menu.visible, "初始界面上场时应当是隐藏的（何时打开由入口脚本决定）")
	_menu.open(MENU_PORT)
	_ok(_menu.visible, "open() 之后界面应当可见")
	# 把目录客户端换成替身（放在 open() 之后：那一步已经把它建好了）。
	# 此后界面对目录的读写都只落在替身上，不会真的出网。
	# **要显式放掉原来那个**：它带一个 HTTPRequest 子节点，留着会在退出时
	# 报 "ObjectDB instances were leaked"，把真正的错误淹掉。
	var original: Node = _menu.get("_directory_client")
	if original != null:
		_menu.remove_child(original)
		original.free()
	_spy = DirectorySpy.new()
	_menu.add_child(_spy)
	_menu.set("_directory_client", _spy)
	_ok(_line("PortRow/Port").text == str(MENU_PORT), "端口应当预填默认值，实际「%s」" % _line("PortRow/Port").text)
	_ok(not _line("HostRow/RoomName").text.is_empty(), "房间名应当有默认值")
	# 默认类型必须是局域网：它是当前唯一能完整跑通的，
	# 而把默认值定在一个尚不可用的选项上会让第一次点「创建房间」就失败。
	_ok(_button("KindRow/Lan").button_pressed, "公开类型应当默认选中局域网")
	_ok(not _button("KindRow/Public").button_pressed, "公网不应当默认选中")
	_ok(not _button("KindRow/Lan").disabled, "类型按钮不应当在一开始就被锁上")
	_ok(_button("RoomButtons/Join").disabled, "没有选中房间时，加入按钮应当是灰的")
	# 起一个广播源，模拟另一台机器已经创建了房间。这里走的是真实 UDP 路径。
	_announcer = Discovery.new()
	root.add_child(_announcer)
	_announcer.announce(func() -> Dictionary:
		return {"name": ROOM_NAME, "port": ROOM_PORT, "players": 2})


func _case_room_listed() -> bool:
	# 先等局域网那个房间出现（走的是真实 UDP 广播路径）。
	if _lan_count() == 0:
		if _stage_elapsed > WAIT_LIMIT:
			_fail("广播之后 %.1f 秒内列表里没有出现局域网房间（当前共 %d 项）" % [WAIT_LIMIT, _list().item_count])
			return true
		return false

	# 再喂一份"目录返回的列表"。**用喂数据而不是真起一个 HTTP 服务**：
	# 这一层要验的是"目录响应 → 列表 → 选中 → 加入"这段接线，
	# 而 HTTP 本身（状态码、JSON、UTF-8 字节）由 tools/room-directory.py --selftest
	# 与服务器上的 curl 检查负责，两边各管一段，不重复。
	_menu.call("_on_directory_rooms", [
		{"name": "官方·等待中", "host": OFFICIAL_HOST, "port": OFFICIAL_ROOM_PORT,
		 "players": 1, "max": 2, "state": "waiting", "joinable": true},
		{"name": "官方·已满", "host": OFFICIAL_HOST, "port": OFFICIAL_FULL_PORT,
		 "players": 2, "max": 2, "state": "waiting", "joinable": false},
		{"name": "官方·进行中", "host": OFFICIAL_HOST, "port": OFFICIAL_PLAYING_PORT,
		 "players": 1, "max": 2, "state": "playing", "joinable": false},
	])

	_ok(_list().item_count == 4, "应当是 3 间公网房 + 1 间局域网房，实际 %d 项" % _list().item_count)

	# 公网房间的文案要能一眼看出人数与状态——“1/2 等待中”与“1/2 进行中”是不同的选择。
	var labels := PackedStringArray()
	for i in _list().item_count:
		labels.append(_list().get_item_text(i))
	_ok(labels[0].contains("1/2"), "公网房间应当显示人数上限，实际「%s」" % labels[0])
	_ok(labels[0].contains("等待中"), "等待中的房间应当写等待中，实际「%s」" % labels[0])
	_ok(labels[2].contains("进行中"), "已开局的房间应当写进行中，实际「%s」" % labels[2])
	_ok(labels[3].contains("局域网"), "探测到的房间应当标明是局域网，实际「%s」" % labels[3])

	# 与配置内容无关的属性检查。上一条只证明"界面读到了同一个值"，
	# 若那个值本身是拼错的域名，两条都会通过。这里查它会像个主机名：
	# 非空、不含空格、带点（域名或 IP 都符合）。这能拦住最常见的误操作——
	# 把地址写成空、写了带空格的、或删掉了点。
	var host := ProductConfig.official_host()
	_ok(not host.is_empty(), "官方目录的地址不应为空")
	_ok(not host.contains(" "), "官方目录的地址不应含空格，实际「%s」" % host)
	_ok(host.contains("."), "官方目录的地址应当像个域名或 IP（含点），实际「%s」" % host)
	_ok(ProductConfig.official_directory_port() > 0, "官方目录的端口应当为正，实际 %d" % ProductConfig.official_directory_port())

	# 加入一间公网房：地址与端口都取自那一项，与输入框无关，且类型是公网。
	_select(0)
	_ok(not _button("RoomButtons/Join").disabled, "选中可进的公网房之后加入按钮应当可用")
	_button("RoomButtons/Join").pressed.emit()
	_ok(_join_calls.size() == 1, "选中公网房后点加入应当发出一次 join_requested，实际 %d 次" % _join_calls.size())
	if _join_calls.size() == 1:
		_ok(String(_join_calls[0][0]) == OFFICIAL_HOST, "公网房的加入地址应当取自列表，实际「%s」" % _join_calls[0][0])
		_ok(int(_join_calls[0][1]) == OFFICIAL_ROOM_PORT, "公网房的加入端口应当取自列表，实际 %d" % int(_join_calls[0][1]))
		_ok(int(_join_calls[0][2]) == Lobby.Kind.PUBLIC, "公网房应当带 PUBLIC 类型，实际 %d" % int(_join_calls[0][2]))

	# **进不了的房间点不动。** 这一条是新增的：以前列表里只有一固定条目，没有"满了/在打"这个概念。
	# 不置灰的话，玩家点下去只会白等一次连接超时，而超时的提示又把罪名归给地址与防火墙。
	for index in [1, 2]:
		_select(index)
		_ok(_button("RoomButtons/Join").disabled,
			"第 %d 项进不了（满/进行中），加入按钮应当是灰的" % index)
	_ok(not _status().text.is_empty(), "选中进不了的房间时状态栏应当说明原因")

	# 加入探测到的局域网房间：端口必须取自房间，而不是界面上的默认端口。
	# 这两个值在测试里刻意取成不同，这样这一条才是有内容的断言。
	var lan_index := _lan_index()
	_ok(lan_index > 0, "探测到的房间应当排在公网房之后，实际下标 %d" % lan_index)
	# 先把忙碌状态解除。上面点过"加入"，界面就进入"正在连接…"（输入锁上、按钮置灰），
	# 而真实流程里连接有结果（成功或失败）时会回到可操作状态。
	# 不解除的话下面测的就不是"能不能进"，而是"上一步的忙碌状态还在不在"。
	_menu.set_message("自检：解除忙碌")
	_select(lan_index)
	_ok(not _button("RoomButtons/Join").disabled, "局域网房间应当总是可以进（人数是否已满由房间自己管）")
	_button("RoomButtons/Join").pressed.emit()
	_ok(_join_calls.size() == 2, "再加入探测到的房间应当发出第二次 join_requested，实际 %d 次" % _join_calls.size())
	if _join_calls.size() == 2:
		var address := String(_join_calls[1][0])
		_ok(not address.is_empty() and address != "0.0.0.0", "加入的地址应当是收到广播的那个地址，实际「%s」" % address)
		_ok(int(_join_calls[1][1]) == ROOM_PORT, "加入的端口应当取自房间而不是界面上的默认值，实际 %d" % int(_join_calls[1][1]))
		_ok(int(_join_calls[1][2]) == Lobby.Kind.LAN, "局域网房应当带 LAN 类型，实际 %d" % int(_join_calls[1][2]))

	# **同一地址、同一名字的两间房也必须能分辨。** 这是真机上被问到的那一种：
	# 官方那边几间房共用一个域名，而一开始的行里只写了地址、没写端口，
	# 于是列表里出现两条一字不差的行，看起来像列表重复了同一个条目。
	# 这里刻意把名字也取成一样的，把"能不能分辨"逼到只剩端口这一个变量——
	# 上面那几条用的是三个不同的名字，恰好绕开了这个坑。
	_menu.call("_on_directory_rooms", [
		{"name": "未命名房间", "host": OFFICIAL_HOST, "port": OFFICIAL_ROOM_PORT,
		 "players": 0, "max": 2, "state": "waiting", "joinable": true},
		{"name": "未命名房间", "host": OFFICIAL_HOST, "port": OFFICIAL_FULL_PORT,
		 "players": 0, "max": 2, "state": "waiting", "joinable": true},
	])
	var twins := [_list().get_item_text(0), _list().get_item_text(1)]
	_ok(twins[0] != twins[1], "同地址同名的两间房不应当显示成一模一样，都是「%s」" % twins[0])
	_ok(twins[0].contains(str(OFFICIAL_ROOM_PORT)) and twins[1].contains(str(OFFICIAL_FULL_PORT)),
		"公网房间的行里应当带各自的端口，实际「%s」/「%s」" % twins)
	return true


## 目录拉不到时的表现：不能把列表清空成"没有房间"（那与"真的没有房间"分不出来），
## 而要明说拉不到、并把原因写出来。
func _case_directory_down() -> void:
	# 先解除忙碌：否则 _rebuild_list() 会为了留住"正在连接…"而不刷新状态栏，
	# 于是这一条测的就不是"拉不到时的表现"。
	_menu.set_message("自检：解除忙碌")
	var before := _list().item_count
	_menu.call("_on_directory_failed", "连不上")
	# 拉不到时保留上一份公网列表：那是我们最后知道的真相，
	# 而清空会让玩家以为房间没了（他可能正盯着某一间在等它空出来）。
	_ok(_list().item_count == before, "目录拉不到时不应把已有的列表清掉，实际 %d → %d" % [before, _list().item_count])
	_ok(_status().text.contains("连不上"), "状态栏应当写出拉不到的原因，实际「%s」" % _status().text)


## 选中某一项。select() 不保证发出 item_selected，显式补一次，
## 让选中状态与真人点击的行为一致（_selected 是在那个信号里写入的）。
func _select(index: int) -> void:
	_list().select(index)
	_list().emit_signal("item_selected", index)


## 探测到的房间数量（不含公网房间）。
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
	_line("PortRow/Port").text = NOT_A_PORT
	_button("HostRow/Host").pressed.emit()
	_ok(_host_calls.is_empty(), "端口不是数字时，创建房间不应当发出信号")
	_ok(not _status().text.is_empty(), "端口不合法时状态栏应当给出提示")

	# 创建房间：房间名要去掉首尾空白，端口取输入框里的值，并带上当前选中的类型。
	_line("PortRow/Port").text = str(MENU_PORT)
	_line("HostRow/RoomName").text = CUSTOM_ROOM_NAME
	_button("HostRow/Host").pressed.emit()
	_ok(_host_calls.size() == 1, "点创建房间应当发出一次 host_requested，实际 %d 次" % _host_calls.size())
	if _host_calls.size() == 1:
		_ok(String(_host_calls[0][0]) == CUSTOM_ROOM_NAME.strip_edges(), "房间名应当去掉首尾空白，实际「%s」" % _host_calls[0][0])
		_ok(int(_host_calls[0][1]) == MENU_PORT, "端口应当取自输入框，实际 %d" % int(_host_calls[0][1]))
		_ok(int(_host_calls[0][2]) == Lobby.Kind.LAN, "默认应当是局域网类型，实际 %d" % int(_host_calls[0][2]))

	# 选公网：创建公网房间**先向目录要一间空房**，拿到地址之后才连过去。
	#
	# 为什么不能再用列表：空着的备用房根本不在列表里（目录把它们滤掉了，否则玩家一
	# 打开界面就看见一堆没人进的房间），而且"两个人同时点创建"必须拿到两间不同的房，
	# 这件事只能由目录原子地做。因此这里验的是两段：点创建只发请求、不该立刻加入；
	# 目录回了地址之后才发 join_requested。
	_button("KindRow/Public").button_pressed = true
	_ok(not _line("HostRow/RoomName").editable, "选公网后房间名那一格应当锁上（名字由房主在大厅里改）")
	# 端口框里放一个非法值：公网创建不看它（房间在服务器上），所以也不该被它拦住。
	_line("PortRow/Port").text = NOT_A_PORT
	var before_public := _join_calls.size()
	var claims_before := _spy.claims.size()
	_button("HostRow/Host").pressed.emit()
	_ok(_spy.claims.size() == claims_before + 1,
		"公网创建应当向目录要一间房，实际发了 %d 次" % (_spy.claims.size() - claims_before))
	_ok(_join_calls.size() == before_public,
		"公网创建不应当立刻加入（要先向目录要房），实际增了 %d 次" % (_join_calls.size() - before_public))
	_ok(_status().text.contains("要一间房"), "点了创建之后应当说明正在向服务器要房，实际「%s」" % _status().text)

	# 「稍等」不是失败：服务器正忙着补一间备用房时不该报错，也不该当成功。
	_menu.call("_on_claim_finished", {"ok": false, "waiting": true})
	_ok(_join_calls.size() == before_public, "「稍等」时不应发加入请求")
	_ok(_status().text.contains("准备"), "「稍等」时应当说正在准备房间，实际「%s」" % _status().text)

	# 目录回了地址：这才发 join_requested，且类型是公网。
	_menu.call("_on_claim_finished", {"ok": true, "host": OFFICIAL_HOST, "port": OFFICIAL_ROOM_PORT})
	_ok(_join_calls.size() == before_public + 1,
		"拿到房间地址后应当发一次 join_requested，实际增了 %d 次" % (_join_calls.size() - before_public))
	if _join_calls.size() == before_public + 1:
		var public_call: Array = _join_calls[before_public]
		_ok(String(public_call[0]) == OFFICIAL_HOST, "应当连目录给出的地址，实际「%s」" % public_call[0])
		_ok(int(public_call[1]) == OFFICIAL_ROOM_PORT, "应当连目录给出的端口，实际 %d" % int(public_call[1]))
		_ok(int(public_call[2]) == Lobby.Kind.PUBLIC, "公网创建应当带 PUBLIC 类型，实际 %d" % int(public_call[2]))
	_ok(_host_calls.size() == 1, "公网创建不应当发 host_requested（那会在本机开服务端），实际共 %d 次" % _host_calls.size())
	_ok(_label("KindHint").text.contains("公网"), "类型说明行应当跟着切到公网的说明")

	# 认领真的失败时：不发请求，并把原因写出来。
	# 这一条锁的是"不要默默失败"——点了没反应会让玩家反复点。
	_menu.set_message("自检：解除忙碌")
	var before_fail := _join_calls.size()
	_button("HostRow/Host").pressed.emit()
	_menu.call("_on_claim_finished", {"ok": false, "reason": "连不上"})
	_ok(_join_calls.size() == before_fail, "认领失败时不应当发出加入请求，实际增了 %d 次" % (_join_calls.size() - before_fail))
	_ok(_status().text.contains("连不上"), "失败时状态栏应当写出原因，实际「%s」" % _status().text)

	# 切回局域网：房间名那一格要重新可编辑，并且再点一次应当能正常创建。
	# 先解除忙碌状态：创建进行中时所有输入都被锁着，而真人要等到连接有结果才能改，
	# 因此不解除就直接切类型并不反映真实路径。
	_menu.set_message("自检：解除忙碌")
	_button("KindRow/Lan").button_pressed = true
	_ok(_line("HostRow/RoomName").editable, "切回局域网后房间名那一格应当恢复可编辑")
	_line("PortRow/Port").text = str(MENU_PORT)
	_button("HostRow/Host").pressed.emit()
	_ok(_host_calls.size() == 2, "切回局域网后应当能再次创建房间，实际共 %d 次" % _host_calls.size())
	if _host_calls.size() == 2:
		_ok(int(_host_calls[1][2]) == Lobby.Kind.LAN, "切回局域网后应当带上局域网类型，实际 %d" % int(_host_calls[1][2]))
		_ok(int(_host_calls[1][1]) == MENU_PORT, "局域网创建应当用本机端口，实际 %d" % int(_host_calls[1][1]))

	# 手动加入：地址与端口都取自输入框。
	# 计数用"调用前先记一笔"的方式，不写死序号——上一个阶段已经发过两次 join_requested，
	# 写死序号会让这一条在别的断言增删之后悄悄失效。
	var before := _join_calls.size()
	_line("DirectRow/Address").text = "127.0.0.1"
	_line("PortRow/Port").text = str(MENU_PORT)
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


## 界面里的节点路径按两栏拼。写成 helper 是为了让断言读起来只剩节点名：
## 左边那一栏是房间列表与它的两个按钮，右边那一栏是创建与直接加入。
func _line(path: String) -> LineEdit:
	return _menu.get_node(_prefix(path) + path)


func _button(path: String) -> Button:
	return _menu.get_node(_prefix(path) + path)


func _label(path: String) -> Label:
	return _menu.get_node(_prefix(path) + path)


## 房间相关的控件在左栏，其余在右栏。
## 判据取 "Room" 前缀而不是 "Rooms"：左栏里的按钮路径是 RoomButtons/…，
## 而右栏的输入框是 HostRow/RoomName，两者靠前缀能分开。
func _prefix(path: String) -> String:
	if path.begins_with("Room"):
		return "Root/Layout/Body/RoomsPanel/RoomsMargin/RoomsBox/"
	return "Root/Layout/Body/HostPanel/HostMargin/HostBox/"


func _list() -> ItemList:
	return _menu.get_node("Root/Layout/Body/RoomsPanel/RoomsMargin/RoomsBox/Rooms")


func _status() -> Label:
	return _menu.get_node("Root/Layout/Footer/Status")


func _next_stage(stage: int) -> void:
	_stage = stage
	_stage_elapsed = 0.0


func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _fail(message: String) -> void:
	_failures.append(message)
