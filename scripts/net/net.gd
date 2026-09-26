extends Node
## 联机连接层，以自动加载（autoload）的形式提供为全局单例 `Net`。
##
## 整个工程里只有这个文件直接使用具体的 MultiplayerPeer 实现，其余脚本一律通过
## multiplayer 与 Net.role / Net.is_server() 工作。这样分开是为了将来更换传输层时
## 只改这一个文件：自建服务端（当前的 ENet 直连）、Steam 数据报中继、EOS P2P
## 都共用同一套上层同步代码（@rpc、MultiplayerSpawner、MultiplayerSynchronizer）。
##
## 关于"权威节点放在哪"：本项目没有公网入口，两台开发机与大多数玩家一样无法接受入站连接，
## 因此最终形态是自建的权威服务端（见 memory/networking.md）。本文件的接口按
## "本机可能是服务端，也可能只是客户端"来设计，不假设存在本机玩家。

enum Role {
	OFFLINE, ## 尚未开始会话。
	SERVER, ## 本机是权威节点。headless 启动时没有本机玩家。
	CLIENT, ## 本机连接到远端权威节点。
}

const DEFAULT_PORT := 27015
## 双人协作，留出余量便于调试时多开实例。
const MAX_CLIENTS := 4

signal hosting_started(port: int)
signal join_succeeded()
signal join_failed()
## 与主机的会话结束。`reason` 是一句可以直接显示给玩家的话（"与主机断开"、
## "与主机失去联系（心跳超时）"……），因此上层不必再加一段猜测成因的文案。
## 断开的原因只有两种，但两者的等待时间相差很多，分清楚才能给出有用的提示：
##   ENet 报了断开（对端主动关、或 ENet 自己超时）
##   心跳超时（本文件自己判定，见 HEARTBEAT_TIMEOUT）
signal server_left(reason: String)

var role: Role = Role.OFFLINE
var port: int = DEFAULT_PORT

## 往返时延（毫秒），由每秒一次的 ping/pong 实测。-1 表示还没测到。
## 它单独测量而不是从同步包推算，因为同步包单向到达时间需要知道两端时钟偏差；
## 而 ping 把发送方自己的时刻带过去再带回来，因此用发送方自己的时钟就能算出往返时延。
var rtt_ms: float = -1.0

const PING_INTERVAL := 1.0
## 时延测量保留的最大在途样本数。防止丢包时表越来越大。
const PING_MAX_IN_FLIGHT := 16

## 服务端离线的判定窗口（秒）。
## 客户端每秒发一次 ping、服务端立刻回 pong，因此连续这么长时间收不到 pong 就可判定下线。
## 为什么要自己判而不用等 ENet：ENet 的超时长度随 RTT 变化（实测同一链路上 6～10 秒），
## 而“服务端被强制结束”时客户端只能干等——期间画面完全静止、也没有任何提示，
## 玩家分不清是卡住了还是对方已经退出。自己判能给出一个明确的上限与原因。
## 取值要能容忍偶发丢包（5 秒相当于容忍连续 4 次丢失），也要明显短于 ENet 的等待。
const HEARTBEAT_TIMEOUT := 5.0

var _ping_elapsed: float = 0.0
var _ping_seq: int = 0
## 序号 → 发出时的本地毫秒时刻。
var _ping_sent: Dictionary = {}
## 最近一次收到 pong 的时刻（毫秒）。0 表示本次会话还没收到过样本。
var _last_pong_ms: int = 0

var _peer: MultiplayerPeer = null
var _dedicated: bool = false


func _ready() -> void:
	# 这些信号一经连接就长期有效：没有 peer 时它们不会触发。
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _process(delta: float) -> void:
	if role == Role.OFFLINE:
		return
	# 心跳判定放在发 ping 之前：它每秒才跑一次，而判定窗口是若干秒，顺序无关。
	if role == Role.CLIENT and is_connected_to_server():
		_check_server_liveness()
	_ping_elapsed += delta
	if _ping_elapsed < PING_INTERVAL:
		return
	_ping_elapsed = 0.0
	_ping_peers()


## 逐帧检查服务端是否还在。只有已连接的客户端需要它。
func _check_server_liveness() -> void:
	var now := Time.get_ticks_msec()
	if _last_pong_ms == 0:
		# 还没有样本（刚连上）。从这一刻开始计，避免把"连接建立之前"的时间算进去。
		_last_pong_ms = now
		return
	var silent := float(now - _last_pong_ms) / 1000.0
	if silent <= HEARTBEAT_TIMEOUT:
		return
	push_warning("与主机的心跳中断 %.1f 秒（上限 %.0f），判定为已下线" % [silent, HEARTBEAT_TIMEOUT])
	_finish_session("与主机失去联系（超过 %.0f 秒没有回应）" % HEARTBEAT_TIMEOUT)


## 向所有已知 peer 发一次时延探测。用不可靠传输：
## 重传会把等待时间算进往返时延，测出来的就不是链路时延了。
##
## 客户端要等到**连接已建立**才发：`join()` 一返回 role 就是 CLIENT，而 ENet 建客户端是即时的，
## 真正的连接结果要等 connection_failed 或超时（实测约 32 秒），这段窗口里 rpc_id 会报
## `Trying to call an RPC via a multiplayer peer which is not connected`，每秒两条地刷。
## 从初始界面加入一个填错的地址是最常见的失败方式，所以这个窗口不能不管。
## 服务端侧不需要这个判断：没有 peer 时 `get_peers()` 是空列表，循环本身不执行。
func _ping_peers() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if role == Role.CLIENT and not is_connected_to_server():
		return
	_ping_seq += 1
	var seq := _ping_seq
	_ping_sent[seq] = Time.get_ticks_msec()
	while _ping_sent.size() > PING_MAX_IN_FLIGHT:
		# 丢包时对应的回复不会来，丢掉最旧的样本（字典保持插入顺序）。
		_ping_sent.erase(_ping_sent.keys()[0])
	var sent := int(_ping_sent[seq])
	if role == Role.CLIENT:
		ping.rpc_id(1, seq, sent)
	else:
		for id in multiplayer.get_peers():
			ping.rpc_id(id, seq, sent)


@rpc("any_peer", "call_remote", "unreliable")
func ping(seq: int, sent_msec: int) -> void:
	# 原样把发起方的时刻带回去，由发起方用自己的钟算往返时延。
	pong.rpc_id(multiplayer.get_remote_sender_id(), seq, sent_msec)


@rpc("any_peer", "call_remote", "unreliable")
func pong(seq: int, sent_msec: int) -> void:
	# 能收到 pong 就是"服务端还在"的证据，因此每次都要更新，
	# 不看下面那个 case（序号对不上也可能对方重发过）。
	_last_pong_ms = Time.get_ticks_msec()
	if not _ping_sent.has(seq):
		return
	_ping_sent.erase(seq)
	var sample := float(_last_pong_ms - sent_msec)
	# 指数平滑：单个样本会被一次调度尖峰拉高很多。
	rtt_ms = sample if rtt_ms < 0.0 else lerpf(rtt_ms, sample, 0.3)


## 本机是否为权威节点。
## 不能改用 multiplayer.is_server()：没有 peer 时它同样返回 true，
## 于是无法区分"还没开始会话"与"正在监听"。
func is_server() -> bool:
	return role != Role.CLIENT


## 作为客户端时，与主机的连接是否已经建立。
## `join()` 一返回 role 就是 CLIENT，而 ENet 创建客户端是即时的：真正的连接结果要等
## connection_failed 或超时（实测约 32 秒）。这段窗口里 peer 已经设好但并不可用，
## 往它上面发 RPC 会报「not connected」并刷屏（见 _ping_peers 的说明），
## 所以需要这个判断把"已连接"与"正在连接"分开。
## 本机是服务端、或尚未开始会话时恒为 false，因此调用方要先看 role。
func is_connected_to_server() -> bool:
	if _peer == null or role != Role.CLIENT:
		return false
	return _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## 本机是否为专用服务端，也就是本机没有玩家角色。
func is_dedicated() -> bool:
	return _dedicated


## 本机的 peer id。离线时为 1，与 Godot 对服务端的约定一致。
func local_id() -> int:
	if _peer == null:
		return 1
	return multiplayer.get_unique_id()


## 开始监听。绑定地址用默认的通配符，因此环回与局域网网卡同时生效：
## 同一台机器上的第二个实例连 127.0.0.1，局域网内其他设备连内网 IP，都不需要额外配置。
func host(p_port: int = DEFAULT_PORT, p_dedicated: bool = false) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(p_port, MAX_CLIENTS)
	if err != OK:
		push_error("端口 %d 无法监听：%s" % [p_port, error_string(err)])
		return err
	_peer = peer
	multiplayer.multiplayer_peer = peer
	role = Role.SERVER
	_dedicated = p_dedicated
	port = p_port
	hosting_started.emit(p_port)
	return OK


## 连接到远端权威节点。
## 注意 ENet 在创建客户端时不会立刻判断目标是否可达，真正失败要等 connection_failed 信号，
## 所以调用方必须连那个信号，不能只看本函数的返回值。
func join(address: String, p_port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, p_port)
	if err != OK:
		push_error("无法连接 %s:%d：%s" % [address, p_port, error_string(err)])
		return err
	_peer = peer
	multiplayer.multiplayer_peer = peer
	role = Role.CLIENT
	_dedicated = false
	port = p_port
	# 清掉上一次会话的心跳样本，否则刚连上就会被误判为超时。
	_last_pong_ms = 0
	return OK


## 结束会话，回到未开始状态。
func close() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	multiplayer.multiplayer_peer = null
	role = Role.OFFLINE
	_dedicated = false
	rtt_ms = -1.0
	_last_pong_ms = 0
	_ping_sent.clear()


## 会话结束的统一收尾。两条路径都汇聚到这里：ENet 报的断开，以及本文件自己的心跳超时。
## 它们可能先后到达（心跳先超时、ENet 随后才报），所以先看 role 去重——
## 否则上层会收到两次 server_left，表现为提示文案被覆盖一次、角色节点被清两遍。
func _finish_session(reason: String) -> void:
	if role == Role.OFFLINE:
		return
	close()
	server_left.emit(reason)


## 告诉各客户端本次会话即将结束，然后关闭。由 main.gd 在退出时调用。
##
## **手动 poll() 是这里的关键。** 引擎平日每帧替我们 poll 一次，但调用这个方法时进程即将
## 结束、不会再有任何一帧，不主动 poll 的话 RPC 只会留在发送队列里随进程一起消失。
## 2026-09-26 实测过这个差别：不 poll 时服务端虽然调了 close()，客户端却仍然要等
## 心跳超时（5 秒）才发现，也就是主动告知完全没生效；加一行 poll() 之后降到一秒以内。
## tools/check-server.mjs 会守住这个差别（预算 3.5 秒，明显短于心跳阈值）。
func shutdown_gracefully() -> void:
	if role == Role.OFFLINE or not multiplayer.has_multiplayer_peer():
		return
	for id in multiplayer.get_peers():
		goodbye.rpc_id(id)
	multiplayer.poll()
	close()


## 服务端主动告知的收尾。与心跳超时走同一条路径，因此上层只处理一次。
## 用 reliable：这个包丢失就失去了主动告知的意义，而它只在结束时发一次，重传的代价可忽略。
@rpc("authority", "call_remote", "reliable")
func goodbye() -> void:
	_finish_session("主机已关闭房间")


func _on_connected_to_server() -> void:
	join_succeeded.emit()


func _on_connection_failed() -> void:
	close()
	join_failed.emit()


func _on_server_disconnected() -> void:
	_finish_session("与主机断开")
