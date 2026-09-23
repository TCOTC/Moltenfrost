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
signal server_left()

var role: Role = Role.OFFLINE
var port: int = DEFAULT_PORT

var _peer: MultiplayerPeer = null
var _dedicated: bool = false


func _ready() -> void:
	# 这些信号一经连接就长期有效：没有 peer 时它们不会触发。
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


## 本机是否为权威节点。
## 不能改用 multiplayer.is_server()：没有 peer 时它同样返回 true，
## 于是无法区分"还没开始会话"与"正在监听"。
func is_server() -> bool:
	return role != Role.CLIENT


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
	return OK


## 结束会话，回到未开始状态。
func close() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	multiplayer.multiplayer_peer = null
	role = Role.OFFLINE
	_dedicated = false


func _on_connected_to_server() -> void:
	join_succeeded.emit()


func _on_connection_failed() -> void:
	close()
	join_failed.emit()


func _on_server_disconnected() -> void:
	close()
	server_left.emit()
