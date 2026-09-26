class_name MainMenu
extends CanvasLayer
## 初始界面：探测局域网中的房间、创建房间、加入房间。
##
## 它只做两件事——把玩家选定的动作转成信号发出去，以及维护房间列表。
## 真正的会话由 scripts/main.gd 建立，因为"本机是主机的还是加入方"属于工程入口的职责，
## 界面与网络层都不该知道。这样分开也便于以后换成公网大厅：换掉房间的来源即可，
## 信号形状不变。
##
## 房间列表来自 scripts/net/lan_discovery.gd：主机每秒广播一次，
## 本界面按报文里的进程标识与游戏端口去重，`room_ttl` 秒收不到同一个房间的广播就把它移除。
##
## 除了探测到的房间，列表最前面还有一个**固定条目：官方公网服务端**。
## 它的存在有两个理由：跨网联机时局域网探测本来就收不到对方的广播（受限广播只走默认路由那张网卡），
## 而玩家也不该为了连官方服务器去手输一遍域名。
##
## 那个地址**不写在这里**，而是读 config/product.cfg（见 scripts/product_config.gd）：
## 它随部署变化（换机器、换域名），而界面只是它的一个使用者。

signal host_requested(room_name: String, port: int)
signal join_requested(address: String, port: int)

## 固定条目在列表里的显示名。带"官方"二字是为了与探测到的玩家房间区分开。
## 这是展示文案而非环境相关的值，所以留在代码里。
const OFFICIAL_NAME := "官方房间（公网）"

## 端口输入框的合法范围。
const MIN_PORT := 1
const MAX_PORT := 65535

var _discovery: LanDiscovery = null
## 正在连接或创建房间时禁用输入，避免连点。
## 此时房间列表的变化也不再改状态栏：否则每秒一次的列表刷新会把"正在连接…"冲掉。
var _busy := false
## 列表里当前选中的房间，为空表示没有选中任何房间。
var _selected: Dictionary = {}

@onready var _rooms: ItemList = $Center/Panel/Margin/Box/Rooms
@onready var _refresh: Button = $Center/Panel/Margin/Box/RoomButtons/Refresh
@onready var _join: Button = $Center/Panel/Margin/Box/RoomButtons/Join
@onready var _room_name: LineEdit = $Center/Panel/Margin/Box/HostRow/RoomName
@onready var _host: Button = $Center/Panel/Margin/Box/HostRow/Host
@onready var _address: LineEdit = $Center/Panel/Margin/Box/DirectRow/Address
@onready var _port: LineEdit = $Center/Panel/Margin/Box/DirectRow/Port
@onready var _direct: Button = $Center/Panel/Margin/Box/DirectRow/Direct
@onready var _status: Label = $Center/Panel/Margin/Box/Status

## 可禁用/可编辑的输入控件。创建或连接进行中会把它们锁上。
var _inputs: Array[Control] = []


func _ready() -> void:
	visible = false
	_inputs = [_refresh, _join, _host, _direct, _room_name, _address, _port]
	# 探测逻辑是界面自己的子节点：界面关掉就不再接收广播，也就不会占用探测端口。
	_discovery = LanDiscovery.new()
	_discovery.rooms_changed.connect(_on_rooms_changed)
	add_child(_discovery)
	_refresh.pressed.connect(_on_refresh_pressed)
	_join.pressed.connect(_on_join_pressed)
	_host.pressed.connect(_on_host_pressed)
	_direct.pressed.connect(_on_direct_pressed)
	_rooms.item_selected.connect(_on_room_selected)
	_rooms.item_activated.connect(_on_room_activated)
	_port.text = str(Net.DEFAULT_PORT)
	_room_name.text = LanDiscovery.default_room_name()
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


## 创建房间：把房间名与端口交给入口脚本，由它决定怎么启动服务端。
func _on_host_pressed() -> void:
	var port := _parse_port()
	if port <= 0:
		return
	var room_name := _room_name.text.strip_edges()
	if room_name.is_empty():
		room_name = LanDiscovery.default_room_name()
	# 写回界面，让玩家看到实际生效的房间名。
	_room_name.text = room_name
	_set_busy("正在创建房间…")
	host_requested.emit(room_name, port)


## 加入列表里选中的那个房间。
func _on_join_pressed() -> void:
	if _selected.is_empty():
		_set_status("请先在上面的列表里选中一个房间。")
		return
	var address := String(_selected.get("address", ""))
	var port := int(_selected.get("port", 0))
	_begin_join(address, port)


func _on_direct_pressed() -> void:
	var address := _address.text.strip_edges()
	if address.is_empty():
		_set_status("请填写主机的地址，例如 192.168.5.210。")
		return
	var port := _parse_port()
	if port <= 0:
		return
	_begin_join(address, port)


func _begin_join(address: String, port: int) -> void:
	_set_busy("正在连接 %s:%d…" % [address, port])
	join_requested.emit(address, port)


# ---------------------------------------------------------------- 列表

func _on_rooms_changed(listed: Array) -> void:
	var merged := _merge_rooms(listed)
	# 重建列表时必须把选中项还原：列表每秒可能刷新一次，
	# 每次都清空选择的话，玩家刚点中的房间会在下一帧自己取消。
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
	if _busy:
		# 连接进行中：状态栏留给"正在连接…"，不被列表刷新覆盖。
		return
	var found := listed.size()
	if found == 0:
		_set_status("局域网里没有探测到房间，但官方房间随时可加入（选中它再点加入）。也可以自己创建一个房间。")
	else:
		_set_status("局域网中发现 %d 个房间，加上官方房间共 %d 个（每秒刷新，%d 秒没有广播的会被移除）。" % [
			found, merged.size(), int(_discovery.room_ttl),
		])


## 固定条目与探测到的房间合成一份列表：固定条目在前，探测到的在后。
## 同地址同端口的探测结果会被去掉，否则同一台服务器会在列表里出现两次——
## 调试时把 config/product.cfg 里的地址临时改成本机地址就会遇到那种情况。
func _merge_rooms(discovered: Array) -> Array:
	var merged: Array = _builtin_rooms()
	var taken: Dictionary = {}
	for room in merged:
		taken[_address_key(room)] = true
	for room in discovered:
		var key := _address_key(room)
		if taken.has(key):
			continue
		taken[key] = true
		merged.append(room)
	return merged


## 固定条目。形状与探测到的房间一致，因此列表重建、选中、加入都不用分两条路径。
## 地址与端口取自 config/product.cfg；那里读不到时会回退到代码里的兜底值。
func _builtin_rooms() -> Array:
	var host := ProductConfig.official_host()
	var port := ProductConfig.official_port()
	return [{
		"key": "official:%s:%d" % [host, port],
		"name": OFFICIAL_NAME,
		"address": host,
		"port": port,
		"official": true,
	}]


## 去重用的键。固定条目用域名，探测到的用 IP，两者不会撞；
## 真正会撞的情形是固定条目被临时指向一个局域网地址。
func _address_key(room: Dictionary) -> String:
	return "%s:%d" % [String(room.get("address", "")), int(room.get("port", 0))]


func _room_label(room: Dictionary) -> String:
	# 官方房间的人数无从得知（没有连上去就不存在这份信息），所以不显示人数而显示"公网"。
	# 给它编个数字反而会让人以为那是真的。
	if bool(room.get("official", false)):
		return "%s    %s:%d    公网" % [
			String(room.get("name", "官方房间")),
			String(room.get("address", "?")),
			int(room.get("port", 0)),
		]
	return "%s    %s:%d    %d 人" % [
		String(room.get("name", "房间")),
		String(room.get("address", "?")),
		int(room.get("port", 0)),
		int(room.get("players", 1)),
	]


func _on_room_selected(index: int) -> void:
	var room = _rooms.get_item_metadata(index)
	_selected = room if room is Dictionary else {}
	_update_join_enabled()


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
		_update_join_enabled()


## 没有选中房间时不能加入。
func _update_join_enabled() -> void:
	_join.disabled = _busy or _selected.is_empty()


func _set_status(text: String) -> void:
	_status.text = text
