class_name LanDiscovery
extends Node
## 局域网房间的广播与探测。
##
## 一个类两种角色，互不干扰：
##   `announce(provider)`   主机侧，周期性把房间信息广播出去，供别人的初始界面列出
##   `listen_for_rooms()`   选房侧，绑定固定端口接收广播，并在房间超时后把它移除
##
## 为什么是"主机广播、选房侧只听"，而不是"选房侧广播询问、主机应答"：
## 后者要求主机也绑定 DISCOVERY_PORT 才能收到询问，于是同一台机器上开两个实例
##（一个当主机、一个停在初始界面）会争抢同一个端口。让选房侧独占该端口、
## 主机用临时端口发送，两边就不冲突；代价是主机每秒多发出一个很小的包。
##
## 广播地址用受限广播 255.255.255.255，它会被送到所有接口，
## 因此在有多个网卡（例如同时装了虚拟机网卡）的机器上不需要指定网卡。
## 每个周期另外向 127.0.0.1 发送一份：受限广播会不会被协议栈发回本机由系统决定，
## 另外发送这一份可以保证同一台机器上多开实例时一定能互相发现。2026-09-26 实测 Windows 上两条都会到达，
## 因此同一台主机在选房侧的列表里会出现两次，靠报文里的进程标识合成一个（见 `host` 字段）。
##
## 报文是"魔数 + 协议版本 + 一个 JSON 对象"，收到不认识的内容直接忽略：
## 这个端口可能收到别的程序的包，版本不匹配时也必须忽略，
## 否则两端字段对不上会在运行时读出不存在的键。

## 探测用的端口，与游戏端口（Net.DEFAULT_PORT）分开。
## 分开的另一个好处是主机换游戏端口时不影响探测，选房侧始终只听这一个端口。
const DISCOVERY_PORT := 27016
const MAGIC := "MOLTENFROST"
## 报文格式版本。字段含义变化时递增，旧版本的一律忽略。
const PROTOCOL := 1
## 受限广播地址与环回地址。后者见文件头对同机多实例的说明。
const BROADCAST_ADDRESS := "255.255.255.255"
const LOCAL_ADDRESS := "127.0.0.1"
## 主机广播房间的间隔（秒）。选房侧的一秒刷新就是它。
const ANNOUNCE_INTERVAL := 1.0
## 房间多久没有新广播就从列表里移除（秒）。主机崩溃或被关掉时不会有"再见"包，
## 只能由超时清理。取值大于两倍广播间隔，这样偶尔缺少一个广播不会让房间在列表里消失。
var room_ttl := 3.0
## 名单上限，防止异常来源把内存涨满。
const MAX_ROOMS := 64
## 发送用的临时端口。0 表示让系统分配。
const ANY_PORT := 0

signal rooms_changed(rooms: Array)

## 发送套接字，只在主机侧存在。
var _send: PacketPeerUDP = null
## 接收套接字，只在选房侧存在。
var _recv: PacketPeerUDP = null
## 主机侧每秒调用一次，返回 {name, port, players}。
var _provider: Callable = Callable()
var _announce_elapsed: float = 0.0
## 本进程的房间标识，由 announce() 生成，随每份广播发出。
## 它的作用只有一个：让选房侧把同一台主机从多个地址（受限广播与 127.0.0.1 各一份）
## 发来的同一份广播合成一个房间。跨进程不稳定也没关系，重启就换一个，旧房间会自然过期。
var _instance_id: int = 0
## 房间键（进程标识:游戏端口）→ {key, name, address, port, players, seen}。
## 用进程标识而不是发送地址做键：同一台主机会从多个地址发出广播，
## 而房间名只是给人看的，允许重名。
var _rooms: Dictionary = {}
## 上一次发出去的名单签名。只有它变了才发信号，
## 否则界面每秒重建一次列表，会把人正在选中的那一项清掉。
var _signature: String = ""
## 强制发信号的哨兵。空名单的签名是空字符串，与初始值相同，
## 因此清空之后必须先把签名改成一个不可能出现的值，否则界面会一直显示上一次的结果。
const FORCE_EMIT := "<强制>"


func _ready() -> void:
	# 两个套接字都还没有，先不参与逐帧处理。
	set_process(false)


# ---------------------------------------------------------------- 主机侧

## 开始广播本机房间。`provider` 每秒被调用一次，返回 {name, port, players}。
## 端口是游戏端口，不能为 0（由系统分配的端口无法告诉别人）。
func announce(provider: Callable) -> void:
	stop_announcing()
	_provider = provider
	var sock := PacketPeerUDP.new()
	# 绑定临时端口：这个套接字只用于发送，因此不需要固定端口，
	# 也就不会和同一台机器上选房侧要绑的 DISCOVERY_PORT 冲突。
	var err := sock.bind(ANY_PORT)
	if err != OK:
		push_error("局域网房间广播无法建立发送套接字：%s" % error_string(err))
		_provider = Callable()
		return
	sock.set_broadcast_enabled(true)
	_send = sock
	_instance_id = _make_instance_id()
	# 立刻发一次：不让人在初始界面里白等一个广播间隔。
	_announce_elapsed = ANNOUNCE_INTERVAL
	set_process(true)


func stop_announcing() -> void:
	if _send != null:
		_send.close()
	_send = null
	_provider = Callable()
	_update_process()


func _announce_once() -> void:
	var info = _provider.call()
	if not (info is Dictionary):
		return
	if int(info.get("port", 0)) <= 0:
		return
	# 进程标识在这里加上，不要求 provider 关心：它只是传输层用来去重的信息。
	var beacon: Dictionary = (info as Dictionary).duplicate()
	beacon["host"] = _instance_id
	var payload := encode_beacon(beacon)
	# 改变目标地址不会影响这个套接字已有的绑定，因此两个地址可以共用同一个套接字。
	for address in [BROADCAST_ADDRESS, LOCAL_ADDRESS]:
		_send.set_dest_address(address, DISCOVERY_PORT)
		_send.put_packet(payload)


# ---------------------------------------------------------------- 选房侧

## 绑定探测端口并开始收集广播。返回是否绑定成功。
## 失败不影响游戏本身（只是这次看不到房间列表），因此由调用方决定怎么提示，
## 这里只报告结果，不抛错也不中断。
func listen_for_rooms() -> bool:
	stop_listening()
	var sock := PacketPeerUDP.new()
	# 这个套接字必须是固定端口：主机侧只知道把广播发到哪个端口，无从得知接收方的临时端口。
	var err := sock.bind(DISCOVERY_PORT)
	if err != OK:
		push_warning("UDP %d 无法监听（%s），本次运行时自动探测局域网房间不可用" % [
			DISCOVERY_PORT, error_string(err),
		])
		sock.close()
		# 清空界面上的旧结果：这次绑定失败意味着收不到任何新的广播，
		# 留着上一次的房间会让人以为它还在线。
		_rooms.clear()
		rooms_changed.emit([])
		return false
	sock.set_broadcast_enabled(true)
	_recv = sock
	_rooms.clear()
	_force_emit()
	set_process(true)
	return true


func stop_listening() -> void:
	if _recv != null:
		_recv.close()
	_recv = null
	_rooms.clear()
	_signature = FORCE_EMIT
	_update_process()


## 当前房间列表，按地址与端口排序（字典的插入顺序取决于广播到达的先后，不适合直接展示）。
func rooms() -> Array:
	var listed: Array = []
	for key in _rooms.keys():
		listed.append(_rooms[key])
	listed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["key"]) < String(b["key"]))
	return listed


func _collect() -> void:
	var now := _now()
	while _recv.get_available_packet_count() > 0:
		var payload := _recv.get_packet()
		var from := _recv.get_packet_ip()
		var info := decode_beacon(payload)
		if info.is_empty():
			continue
		var port := int(info.get("port", 0))
		if port <= 0 or from.is_empty():
			continue
		var host := int(info.get("host", 0))
		# 优先用进程标识当键：同一台主机可能从两个地址（受限广播与 127.0.0.1）各发来一份，
		# 只有它能保证合成一个房间。标识缺失时退回按发送地址去重。
		var key := "%d:%d" % [host, port] if host > 0 else "%s:%d" % [from, port]
		var existing: Dictionary = _rooms.get(key, {})
		var address := from
		if not existing.is_empty() and (_is_loopback(from) or not _is_loopback(String(existing["address"]))):
			# 保留已有的地址：已有的是非环回地址，或者两份都是环回。
			# 环回地址只有本机能连，而房间是给别的机器看的。
			address = String(existing["address"])
		if _rooms.size() >= MAX_ROOMS and existing.is_empty():
			continue
		# 一个地址加一个游戏端口只可能对应一个房间（第二次监听同一个端口必然失败），
		# 因此把同地址同端口、但键不同的旧条目去掉。主机在房间超时之前重启会换一个进程标识，
		# 没有这一步的话列表里会同时出现新旧两个一模一样的房间，直到旧的超时。
		for other in _rooms.keys():
			if other == key:
				continue
			if String(_rooms[other]["address"]) == address and int(_rooms[other]["port"]) == port:
				_rooms.erase(other)
		_rooms[key] = {
			"key": key,
			"name": String(info.get("name", "未命名房间")),
			"address": address,
			"port": port,
			"players": int(info.get("players", 1)),
			"seen": now,
		}
	# 清理超时的房间。主机关掉或崩溃之后不会再发广播，只能由这一步把它从列表里去掉。
	for key in _rooms.keys():
		if now - float(_rooms[key]["seen"]) > room_ttl:
			_rooms.erase(key)
	_emit_if_changed()


# ---------------------------------------------------------------- 报文编解码

## 打包成 `MOLTENFROST/<版本> {JSON}`。编解码是静态的，便于单独验证。
static func encode_beacon(info: Dictionary) -> PackedByteArray:
	return ("%s/%d %s" % [MAGIC, PROTOCOL, JSON.stringify(info)]).to_utf8_buffer()


## 解析一个广播报文。不是本协议的、版本不对的、内容不是 JSON 对象的都返回空字典，
## 由调用方当作"不是房间广播"忽略。
static func decode_beacon(payload: PackedByteArray) -> Dictionary:
	var text := payload.get_string_from_utf8()
	var prefix := "%s/%d " % [MAGIC, PROTOCOL]
	if not text.begins_with(prefix):
		return {}
	# 用 JSON.parse() 而不是 JSON.parse_string()：后者在解析失败时会打一行引擎错误，
	# 而这里的失败是预期之内的（这个端口会收到别的程序的包）。
	var json := JSON.new()
	if json.parse(text.substr(prefix.length())) != OK:
		return {}
	if not (json.data is Dictionary):
		return {}
	return json.data


## 房间名的默认值。用系统登录名，让局域网里的另一个人能认出是谁创建的房间。
## 放在这里是因为创建房间的一方（scripts/main.gd）与初始界面都要用它。
static func default_room_name() -> String:
	var who := OS.get_environment("USERNAME")
	if who.is_empty():
		who = OS.get_environment("USER")
	if who.is_empty():
		who = "玩家"
	return "%s 的房间" % who


# ---------------------------------------------------------------- 内部

func _process(delta: float) -> void:
	if _send != null:
		_announce_elapsed += delta
		if _announce_elapsed >= ANNOUNCE_INTERVAL:
			_announce_elapsed = 0.0
			_announce_once()
	if _recv != null:
		_collect()


func _emit_if_changed() -> void:
	var listed := rooms()
	var parts := PackedStringArray()
	# 地址也要进签名：同一个房间可能先从环回地址收到、随后被非环回地址取代，
	# 界面上的地址要跟着改，只比人数与名字的话它会一直显示旧的那一个。
	for room in listed:
		parts.append("%s|%s|%s|%d" % [room["key"], room["address"], room["name"], room["players"]])
	var signature := "；".join(parts)
	if signature == _signature:
		return
	_signature = signature
	rooms_changed.emit(listed)


## 让界面收到一次当前名单，哪怕它与上一次相同。清空结果之后要用。
func _force_emit() -> void:
	_signature = FORCE_EMIT
	_emit_if_changed()


func _update_process() -> void:
	set_process(_send != null or _recv != null)


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


## 本进程的房间标识。取"系统时刻 + 进程号"：
## 进程号保证同一台机器上多开实例不会撞号，系统时刻保证两台机器几乎不会撞号。
## 不用随机数是为了不依赖全局随机数是否已被 randomize()。
## 即使撞号，后果也只是列表里少一个房间，且房间会随超时消失，代价可控。
static func _make_instance_id() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0) + OS.get_process_id()


## 环回地址对别的机器没有意义，因此收到同一房间的两个来源时优先保留非环回的那个。
## 空地址与 0.0.0.0 一并归入这一类：它们同样只有本机能用。
static func _is_loopback(address: String) -> bool:
	return address.is_empty() or address.begins_with("127.") or address == "0.0.0.0"


## 关掉两个套接字。退出场景之前调用可以立刻释放端口，
## 否则依赖引用计数被回收的时机，重开界面时可能撞上"端口被占用"。
func stop() -> void:
	stop_announcing()
	stop_listening()
