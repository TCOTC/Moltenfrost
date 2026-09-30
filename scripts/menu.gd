class_name MainMenu
extends CanvasLayer
## 初始界面：探测局域网中的房间、创建房间、加入房间。
##
## 版面上是一块标题区（熔/霜两个字分色）+ 两栏主体（左"加入一局"、右"开一局"）+ 一条页脚状态。
## 这样排的理由是可读性而不是好看：**"加入"与"创建"是两件事，不该混在一列里**。
## 原来那版把所有控件竖着堆在一起，第一次打开的人要逐行读才知道哪个按钮是干什么的；
## 分栏之后左右各有一个标题与一句说明，扫一眼就能选。背景留下半透明的关卡画面，
## 那既是"这是个游戏"的最直接信号，也顺带让两个分色的标题有了对应的实物。
##
## 它只做两件事——把玩家选定的动作转成信号发出去，以及维护房间列表。
## 真正的会话由 scripts/main.gd 建立，因为"本机是主机的还是加入方"属于工程入口的职责，
## 界面与网络层都不该知道。这样分开也便于以后换成公网大厅：换掉房间的来源即可，
## 信号形状不变。
##
## 房间列表来自两处，合成一份：
##   **局域网** —— scripts/net/lan_discovery.gd。主机每秒广播一次，
##                  本界面按报文里的进程标识与游戏端口去重，`room_ttl` 秒收不到就移除。
##   **公网**   —— 官方房间目录（config/product.cfg 里的地址），每几秒拉一次。
##
## **公网那一份只看得到「有人」的房间。** 服务器上总有一间没人玩的空房备着，
## 而它不出现在列表里：玩家打开界面看到的是空的，自己点「创建」才会认领一间，
## 那一间随后就出现在别人的列表里。空的房间为什么要藏着、以及为什么只能由目录
## 原子地交付，见 tools/room-directory.py 的文件头与 claim()。

signal host_requested(room_name: String, port: int, kind: int)
signal join_requested(address: String, port: int, kind: int)

## 端口输入框的合法范围。
const MIN_PORT := 1
const MAX_PORT := 65535
## 认领失败后重试的间隔与次数。
##
## 需要重试是因为两种情况都不算错误：服务器正忙着补一间备用房（对账周期 2 秒 +
## 房间启动一两秒），以及刚部署完目录与房间还没起来。把它们当错误报给玩家，
## 而实际上再等一下就好了。
const CLAIM_RETRY_INTERVAL := 1.5
const CLAIM_RETRY_LIMIT := 12

var _discovery: LanDiscovery = null
## 正在连接或创建房间时禁用输入，避免连点。
## 此时房间列表的变化也不再改状态栏：否则每秒一次的列表刷新会把"正在连接…"冲掉。
var _busy := false
## 列表里当前选中的房间，为空表示没有选中任何房间。
var _selected: Dictionary = {}
## 创建房间时选的公开类型（Lobby.Kind）。默认局域网：它是当前唯一能完整跑通的，
## 而把默认值定在一个尚不可用的选项上会让第一次点「创建房间」就失败。
var _room_kind: int = Lobby.Kind.LAN

@onready var _rooms: ItemList = $Root/Layout/Body/RoomsPanel/RoomsMargin/RoomsBox/Rooms
@onready var _refresh: Button = $Root/Layout/Body/RoomsPanel/RoomsMargin/RoomsBox/RoomButtons/Refresh
@onready var _join: Button = $Root/Layout/Body/RoomsPanel/RoomsMargin/RoomsBox/RoomButtons/Join
@onready var _room_name: LineEdit = $Root/Layout/Body/HostPanel/HostMargin/HostBox/HostRow/RoomName
@onready var _host: Button = $Root/Layout/Body/HostPanel/HostMargin/HostBox/HostRow/Host
@onready var _lan_kind: Button = $Root/Layout/Body/HostPanel/HostMargin/HostBox/KindRow/Lan
@onready var _pub_kind: Button = $Root/Layout/Body/HostPanel/HostMargin/HostBox/KindRow/Public
@onready var _kind_hint: Label = $Root/Layout/Body/HostPanel/HostMargin/HostBox/KindHint
@onready var _address: LineEdit = $Root/Layout/Body/HostPanel/HostMargin/HostBox/DirectRow/Address
## 端口只有这一格，创建房间与手动填地址加入共用。
## 拆成两格反而更难用：填了一个以为两个都改了，是这类界面最常见的报错来源。
@onready var _port: LineEdit = $Root/Layout/Body/HostPanel/HostMargin/HostBox/PortRow/Port
@onready var _direct: Button = $Root/Layout/Body/HostPanel/HostMargin/HostBox/DirectRow/Direct
@onready var _status: Label = $Root/Layout/Footer/Status

## 可禁用/可编辑的输入控件。创建或连接进行中会把它们锁上。
var _inputs: Array[Control] = []
## 列表空着时显示在那块区域里的说明。它不是一个新控件类型，
## 而是把一句提示叠在列表上方——ItemList 自己没有“占位文案”这个能力。
var _empty_hint: Label = null
## 最近一次探测到的局域网房间，与最近一次从目录拉到的公网房间。
## 两份分开存：它们各自刷新（局域网靠广播、公网靠 HTTP），
## 合成只在 _rebuild_list() 里做一次。
var _lan_rooms: Array = []
var _official_rooms: Array = []
## 目录列表是否拉到了，以及拉不到的原因（直接显示给玩家）。
var _directory_ok := false
var _directory_error := "还没拉过"
var _directory_client: DirectoryClient = null
## 目录列表的刷新计时。
var _directory_elapsed := 0.0
## 目录列表的刷新间隔（秒）。比房间的登记间隔慢：列表不需要那么灵敏，
## 而它每次都是一次 HTTP 往返。
const DIRECTORY_REFRESH := 3.0
## 正在等认领结果时的剩余重试次数与计时。见 CLAIM_RETRY_INTERVAL。
var _claim_retries := 0
var _claim_waiting := false
var _claim_elapsed := 0.0


func _ready() -> void:
	visible = false
	# 主题在代码里构建（理由见 scripts/ui/game_theme.gd）。贴在 Root 上而不是场景里逐个
	# 控件写覆盖：主题会向下传播，改一处颜色两栏一起变，不会出现"左边是新的、右边还是旧的"。
	$Root.theme = GameTheme.build()
	# 两个"主动作"用暖色实心按钮，与其它按钮拉开主次。
	# 界面上的第一眼应该落在"开一局"与"进入选中的房间"上，而不是一排长得一样的按钮。
	GameTheme.apply_primary(_join)
	GameTheme.apply_primary(_host)
	_inputs = [_refresh, _join, _host, _direct, _room_name, _address, _port, _lan_kind, _pub_kind]
	# 两个类型按钮靠 ButtonGroup 互斥，因此“选中”这件事只有一份状态（按钮自己），
	# 不需要另外维护一个“当前选中的是哪个”的变量去与界面对齐。
	var kind_group := ButtonGroup.new()
	_lan_kind.button_group = kind_group
	_pub_kind.button_group = kind_group
	_lan_kind.button_pressed = true
	_lan_kind.toggled.connect(func(on: bool) -> void: if on: _set_room_kind(Lobby.Kind.LAN))
	_pub_kind.toggled.connect(func(on: bool) -> void: if on: _set_room_kind(Lobby.Kind.PUBLIC))
	# 走同一条设置路径而不是直接 _refresh_kind_hint()：房间名那一格的锁状态也归它管，
	# 两条路会分成两种初始状态。
	_set_room_kind(Lobby.Kind.LAN)
	# 探测逻辑是界面自己的子节点：界面关掉就不再接收广播，也就不会占用探测端口。
	_discovery = LanDiscovery.new()
	_discovery.rooms_changed.connect(_on_rooms_changed)
	add_child(_discovery)
	# 目录客户端也是界面自己的：列表是界面的事，关掉界面就不该再发请求。
	_directory_client = DirectoryClient.new()
	_directory_client.rooms_fetched.connect(_on_directory_rooms)
	_directory_client.request_failed.connect(_on_directory_failed)
	_directory_client.claim_finished.connect(_on_claim_finished)
	add_child(_directory_client)
	set_process(true)
	_refresh.pressed.connect(_on_refresh_pressed)
	_join.pressed.connect(_on_join_pressed)
	_host.pressed.connect(_on_host_pressed)
	_direct.pressed.connect(_on_direct_pressed)
	_rooms.item_selected.connect(_on_room_selected)
	_rooms.item_activated.connect(_on_room_activated)
	_port.text = str(Net.DEFAULT_PORT)
	_room_name.text = LanDiscovery.default_room_name()
	_build_empty_hint()
	_update_join_enabled()


# ---------------------------------------------------------------- 由入口脚本调用

## 打开界面并开始探测。重复调用是安全的：创建房间失败之后要留在界面上换端口重试，
## 用的也是这个方法，因此第二次进来不能把已经填好的内容清掉。
func open(default_port: int) -> void:
	if not visible:
		_port.text = str(default_port)
		_room_name.text = LanDiscovery.default_room_name()
	visible = true
	_clear_busy()
	_start_probing()
	# 立刻拉一次，然后按间隔刷新。不拉的话第一次进界面会看到一份空列表，
	# 而玩家无从得知"是还没有房间"还是"还在等"。
	_directory_elapsed = DIRECTORY_REFRESH
	_fetch_directory()


func _process(delta: float) -> void:
	# 隐藏时不发请求：界面关掉之后玩家在跑关卡，没必要再拉列表。
	if not visible:
		return
	if _claim_waiting:
		_claim_elapsed += delta
		if _claim_elapsed >= CLAIM_RETRY_INTERVAL:
			_claim_waiting = false
			_request_public_room()
			return
	_directory_elapsed += delta
	if _directory_elapsed < DIRECTORY_REFRESH:
		return
	_directory_elapsed = 0.0
	_fetch_directory()


func _fetch_directory() -> void:
	# 地址取自 config/product.cfg（换机器/换域名只改那一个文件）。
	_directory_client.fetch_rooms(ProductConfig.official_directory_url())


## 关闭界面并停止探测。房间的广播不在这里处理：那是创建房间那一方的责任，
## 它要一直持续到对局结束，和界面在不在无关。
func close() -> void:
	visible = false
	_discovery.stop()


## 把界面恢复到可操作状态并显示一条说明。用于连接失败、从对局退回等场景。
func set_message(text: String) -> void:
	_clear_busy()
	_set_status(text)


## 解除忙碌状态：输入可编辑、按钮可用、加入按钮按当前选中项决定。
func _clear_busy() -> void:
	_busy = false
	_set_inputs_enabled(true)
	_update_join_enabled()


# ---------------------------------------------------------------- 按钮

func _on_refresh_pressed() -> void:
	_start_probing()
	# 「重新探测」把两份列表都重拉一遍：玩家点它的意思就是"现在到底有什么"，
	# 只刷新局域网会让官方那一半看起来卡住了。
	_directory_elapsed = DIRECTORY_REFRESH
	_fetch_public_rooms_now()


## 创建房间。两条路不同，而且**不同之处是本质的**：
##   局域网 —— 真的在本机开一个服务端（房间是这一把创建的）
##   公网 —— 官方服务器上那几间房是**预先存在**的，因此"创建"就是**进一间空的并当房主**
##（见 docs/公网房间方案.md 的路线 A）。两者都只发信号，怎么建会话由入口脚本决定。
func _on_host_pressed() -> void:
	if _room_kind == Lobby.Kind.PUBLIC:
		_create_public_room()
		return
	var room_name := _room_name.text.strip_edges()
	if room_name.is_empty():
		room_name = LanDiscovery.default_room_name()
	# 写回界面，让玩家看到实际生效的房间名。
	_room_name.text = room_name
	var port := _parse_port()
	if port <= 0:
		return
	_set_busy("正在创建房间…")
	host_requested.emit(room_name, port, _room_kind)


## 「创建公网房间」= 找一间空房进去当房主。
##
## 不校验本机端口：公网房间跑在官方服务器上，本机那个端口用不上。
##
## **不再自己从列表里挑一间空房。** 列表里根本没有空房（目录把备用房滤掉了），
## 而且“两个人同时点创建”必须拿到两间不同的房，这件事只能由目录原子地做。
## 因此这里只是一个请求：要一间空房 → 拿回地址 → 连它。见 DirectoryClient.claim_room。
func _create_public_room() -> void:
	_claim_retries = CLAIM_RETRY_LIMIT
	_claim_waiting = false
	_request_public_room()


## 发一次认领请求。失败与“稍等”都由 _on_claim_finished 处理。
func _request_public_room() -> void:
	_set_busy("正在向官方服务器要一间房…")
	_directory_client.claim_room(ProductConfig.official_directory_url())


## 认领的结果。三种情况，而且"稍等"那一种不是错误：
##   ok       —— 拿到了地址，直接连过去（接下来就是普通的一次加入）
##   waiting  —— 服务器正在补一间备用房（对账 2 秒 + 房间启动一两秒），过一会儿再试
##   其它     —— 真的失败了，把原因原样给玩家
func _on_claim_finished(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_claim_retries = 0
		_claim_waiting = false
		_begin_join(String(result.get("host", "")), int(result.get("port", 0)), Lobby.Kind.PUBLIC)
		return
	if bool(result.get("waiting", false)):
		if _claim_retries > 0:
			# 不把重试次数一次用完：第一次“稍等”是**正常**的，服务器总要几秒
			# 才能补上新的一间。直接报失败会让玩家以为功能坏了。
			_claim_retries -= 1
			_claim_waiting = true
			_claim_elapsed = 0.0
			_set_busy("官方服务器正在准备房间，稍等一下…")
			return
		_clear_busy()
		_set_status("等了很久还是没有空房。官方那边的名额可能已经满了，稍后再试，或者先开一间局域网房间。")
		return
	_claim_waiting = false
	_clear_busy()
	_set_status("申请房间失败：%s" % String(result.get("reason", "未知原因")))


## 手动拉一次列表。与定期的那个共用一次请求，只是不等计时器。
func _fetch_public_rooms_now() -> void:
	_fetch_directory()


## 加入列表里选中的那个房间。
func _on_join_pressed() -> void:
	if _selected.is_empty():
		_set_status("请先在上面的列表里选中一个房间。")
		return
	var kind := Lobby.Kind.PUBLIC if bool(_selected.get("official", false)) else Lobby.Kind.LAN
	var address := String(_selected.get("address", ""))
	var port := int(_selected.get("port", 0))
	_begin_join(address, port, kind)


## 不能进的房间要点得动的话，点了之后只会白等一次连接超时。
## 因此直接置灰，并把原因写在状态栏。
##
## 空着的备用房根本不会出现在列表里（目录滤掉了），所以这里不需要处理"没人但可以当房主"
## 那一种：想当房主就点「创建房间」，那条路会去认领。
func _joinable(room: Dictionary) -> bool:
	if not bool(room.get("official", false)):
		return true
	if String(room.get("state", "waiting")) != "waiting":
		return false
	return int(room.get("players", 0)) < int(room.get("max", 2))


func _on_direct_pressed() -> void:
	var address := _address.text.strip_edges()
	if address.is_empty():
		_set_status("请填写主机的地址，例如 192.168.5.210。")
		return
	var port := _parse_port()
	if port <= 0:
		return
	# 手填地址的一律按局域网算：那条路径上的超时就是地址/防火墙问题，
	# 按公网提示会把玩家引到"房间都满了"上去。
	_begin_join(address, port, Lobby.Kind.LAN)


## 切换公开类型。只改状态与那行说明，不发信号——发信号是点「创建房间」时的事。
func _set_room_kind(kind: int) -> void:
	_room_kind = kind
	# 公网下锁上房间名那一格：公网房间是官方服务器上已经存在的一间，
	# 它的名字由**房主在大厅里改**（路线 A），不是在创建时填的。
	# 留着一个填了但不生效的输入框是最差的一种：玩家会以为房间名是他定的。
	# `not _busy` 那一半是必要的：创建进行中时所有输入都被锁着，
	# 而这里若只按类型判断，会把那一格在这一刻意外解锁。
	_room_name.editable = kind != Lobby.Kind.PUBLIC and not _busy
	_refresh_kind_hint()


## 类型说明。两个选项各有一句"选了会怎么样"，而不是只给一个名字：
## "公网/局域网"对不熟悉网络的人来说不是自明的，尤其是跨网时能不能加入这件事。
## 公网那句要说清一个容易被误解的点：这个按钮**不是在"本机开服"**，
## 而是从官方列表里挑一间空房进去当房主。
func _refresh_kind_hint() -> void:
	if _room_kind == Lobby.Kind.PUBLIC:
		_kind_hint.text = "公网 · 房间开在官方服务器上，跨网也能加入。点创建会领一间空房并由你当房主，进去之后可以改房间名；别人也能在左侧列表里看到它并加入。"
	else:
		_kind_hint.text = "局域网 · 房间开在本机，同一局域网里的人在左侧列表里就能看到它。"


func _begin_join(address: String, port: int, kind: int) -> void:
	_set_busy("正在连接 %s:%d…" % [address, port])
	join_requested.emit(address, port, kind)


# ---------------------------------------------------------------- 列表

## 局域网探测结果变了。只是换一份数据，真正的合成在 _rebuild_list() 里。
func _on_rooms_changed(listed: Array) -> void:
	_lan_rooms = listed
	_rebuild_list()


## 目录返回了列表。
func _on_directory_rooms(listed: Array) -> void:
	_official_rooms.clear()
	for item in listed:
		if item is Dictionary:
			_official_rooms.append(_listed_to_room(item))
	_directory_ok = true
	_rebuild_list()


func _on_directory_failed(reason: String) -> void:
	_directory_ok = false
	_directory_error = reason
	_rebuild_list()


## 重建整张列表。局域网每秒刷新一次，因此这个方法会被频繁调用，
## 选中的那一项必须还原（否则玩家刚点中的房间会在下一帧自己取消）。
func _rebuild_list() -> void:
	var merged := _merge_rooms(_lan_rooms, _official_rooms)
	var keep := String(_selected.get("key", ""))
	_rooms.clear()
	_selected = {}
	var reselect := -1
	for room in merged:
		var index := _rooms.add_item(_room_label(room))
		_rooms.set_item_metadata(index, room)
		if String(room.get("key", "")) == keep:
			reselect = index
	if reselect >= 0:
		# 这一行会触发 item_selected，_selected 在那里被写入。
		_rooms.select(reselect)
	_update_join_enabled()
	_empty_hint.visible = _room_count() == 0
	if _busy:
		# 连接进行中：状态栏留给"正在连接…"，不被列表刷新覆盖。
		return
	_set_status(_list_summary())


## 状态栏那一句。把三件事一起说清：列表里有什么、多久刷新、拉不到时为什么。
func _list_summary() -> String:
	var lan := _lan_rooms.size()
	var official := _official_rooms.size()
	if not _directory_ok:
		return "官方房间列表拉不到（%s）。局域网里有 %d 个房间；也可以在右边自建一间。" % [_directory_error, lan]
	if lan == 0 and official == 0:
		return "暂时没有可选的房间。可以在右边自建一间局域网房间，或稍后再看。"
	return "官方 %d 间、局域网 %d 间（每几秒刷新；局域网里 %d 秒没有广播的会被移除）。" % [
		official, lan, int(_discovery.room_ttl),
	]


## 把目录里的公网房间与探测到的局域网房间合成一份列表。
##
## 为什么不再有那个「官方房间（公网）」固定条目：路线 A 之后官方那边是**一列房间**
##（见 docs/公网房间方案.md），而固定条目会把"选一间"这件事退化成"只能连那一间"。
##
## 去重按 host:port：同一间房可能既在目录里、又收到了它的局域网广播
##（开发时把 local 房间也配了目录就会这样），留目录那一份——它带人数与状态。
func _merge_rooms(discovered: Array, listed: Array) -> Array:
	var merged: Array = []
	var taken: Dictionary = {}
	for room in listed:
		taken[_address_key(room)] = true
		merged.append(room)
	for room in discovered:
		var key := _address_key(room)
		if taken.has(key):
			continue
		taken[key] = true
		merged.append(room)
	return merged


## 把目录返回的一项转成列表条目。**在这里统一形状**，于是下面的选中、
## 加入、显示都不必分"公网"与"局域网"两条路径。
func _listed_to_room(item: Dictionary) -> Dictionary:
	return {
		"key": "official:%s:%d" % [String(item.get("host", "")), int(item.get("port", 0))],
		"name": String(item.get("name", "未命名房间")),
		"address": String(item.get("host", "")),
		"port": int(item.get("port", 0)),
		"players": int(item.get("players", 1)),
		"max": int(item.get("max", 2)),
		"state": String(item.get("state", "waiting")),
		"official": true,
	}


## 去重用的键。公网房间用域名、探测到的用 IP，两者不会撞；
## 真正会撞的情形是把公网房间也配上了局域网广播。
func _address_key(room: Dictionary) -> String:
	return "%s:%d" % [String(room.get("address", "")), int(room.get("port", 0))]


func _room_label(room: Dictionary) -> String:
	if bool(room.get("official", false)):
		var max_players := int(room.get("max", 2))
		var state := "进行中" if String(room.get("state", "waiting")) == "playing" else "等待中"
		# 人数与状态都对玩家有用：“2/2 等待中”与“1/2 等待中”是不同的选择。
		# **端口必须带上**：官方那几间房在同一个域名上，只有端口不同，只写地址会让
		# 若干行一字不差（真机上被当成“列表重复了一个条目”的 bug）。形式与局域网那一行
		# 统一，因为它就是玩家要填进「手动连接」的那个地址。
		return "%s    %d/%d 人    %s    %s:%d" % [
			String(room.get("name", "房间")), int(room.get("players", 0)), max_players,
			state, String(room.get("address", "?")), int(room.get("port", 0)),
		]
	return "%s    %s:%d    %d 人    局域网" % [
		String(room.get("name", "房间")),
		String(room.get("address", "?")),
		int(room.get("port", 0)),
		int(room.get("players", 1)),
	]


func _on_room_selected(index: int) -> void:
	var room = _rooms.get_item_metadata(index)
	_selected = room if room is Dictionary else {}
	if not _selected.is_empty() and not _joinable(_selected):
		# 说清楚为什么点不动，而不是只把按钮置灰。
		_set_status("「%s」现在进不了：%s。" % [
			String(_selected.get("name", "这间房")),
			"已经在打了" if String(_selected.get("state", "")) == "playing" else "人已经满了",
		])
	_update_join_enabled()


## 列表空着时的那句说明。它叠在列表上方（ItemList 没有占位文案这个能力）。
func _build_empty_hint() -> void:
	_empty_hint = Label.new()
	_empty_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_hint.add_theme_color_override("font_color", GameTheme.TEXT_DIM)
	_empty_hint.add_theme_font_size_override("font_size", GameTheme.FONT_LABEL)
	_empty_hint.text = "还没有可选的房间。\n在右边「开一局」自己创建一个局域网房间，或者稍后再看（官方房间列表每隔几秒刷新）。"
	_rooms.add_child(_empty_hint)
	_empty_hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_empty_hint.visible = false


## 可选的房间数（公网与局域网都算）。用于决定要不要显示那句空状态说明。
func _room_count() -> int:
	return _rooms.item_count


func _on_room_activated(index: int) -> void:
	_on_room_selected(index)
	_on_join_pressed()


# ---------------------------------------------------------------- 内部

func _start_probing() -> void:
	if _discovery.listen_for_rooms():
		_set_status("正在探测局域网中的房间…")
	else:
		# 探测端口被占用只影响局域网列表。官方房间在列表里是固定条目、不经探测，
		# 因此这种情况仍然能加入官方服务器，要把这一点说清楚。
		_set_status("UDP %d 无法监听，局域网自动探测不可用，但仍可加入上面的官方房间或手动填写地址。若同一台机器上已有另一个实例停在初始界面，它会占用这个端口。" % LanDiscovery.discovery_port)


## 读端口输入框。不合法时把提示写到状态栏并返回 0（0 不是合法端口，可当失败标记）。
func _parse_port() -> int:
	var text := _port.text.strip_edges()
	if not text.is_valid_int():
		_set_status("端口要填整数，例如 %d。" % Net.DEFAULT_PORT)
		return 0
	var port := int(text)
	if port < MIN_PORT or port > MAX_PORT:
		_set_status("端口要在 %d 到 %d 之间。" % [MIN_PORT, MAX_PORT])
		return 0
	return port


func _set_busy(text: String) -> void:
	_busy = true
	_set_inputs_enabled(false)
	_set_status(text)


func _set_inputs_enabled(enabled: bool) -> void:
	for node in _inputs:
		if node is LineEdit:
			# 端口输入框在连接进行中也不该改，因此一并锁上。
			(node as LineEdit).editable = enabled
		else:
			(node as Button).disabled = not enabled
	if enabled:
		# 解除锁定时要把公网下该锁的那一格重新锁上：上面那个循环是“一刀切”，
		# 而房间名在公网下始终不可编辑（理由见 _set_room_kind）。
		_room_name.editable = _room_kind != Lobby.Kind.PUBLIC
		_update_join_enabled()


## 没有选中房间、或选中的房间进不了时，不能加入。
func _update_join_enabled() -> void:
	_join.disabled = _busy or _selected.is_empty() or not _joinable(_selected)


func _set_status(text: String) -> void:
	_status.text = text
