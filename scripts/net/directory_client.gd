class_name DirectoryClient
extends Node
## 房间目录的 HTTP 客户端。两个方向都在这里，因为它们用的是同一个协议、同一套错误处理：
##   `fetch_rooms()` —— 界面用它取列表
##   `register_room()` —— 房间用它登记自己（定期刷新，靠目录的 TTL 清理）
##
## 为什么走 HTTP 而不是延续那个 UDP 网关的协议：见 tools/room-directory.py 的文件头。
## 对这里最直接的好处是**不用自己设计报文的编解码**——JSON 与一行 URL 就够，
## 而那个 UDP 网关当年为了"魔数 + 版本 + JSON"还要单独写一份编解码与一组测试。
##
## 一次只发一个请求：`HTTPRequest` 本身就是这个限制。对当前的用途（界面偶尔拉一次、
## 房间每 2 秒登记一次）完全够，而且省掉了"同一时刻两个请求"的排队问题。
## 若将来同一帧要发多个请求，得改成队列——但现在没有这个需求，先不做。

## 列表到手。`rooms` 是目录返回的那个数组，每项形如
## {name, host, port, players, max, state, age, joinable}。
##
## **注意它只会有非空的房间**：空着的备用房由目录滤掉了，玩家要进它只能走
## `claim_room()`。见 tools/room-directory.py 的 busy()。
signal rooms_fetched(rooms: Array)
## 认领的结果。`result` 形如：
##   {"ok": true, "host": "...", "port": N}   —— 拿到一间空房，去连它
##   {"ok": false, "waiting": true}             —— 服务器正在补一间备用房，过一会儿再试
##   {"ok": false, "reason": "..."}             —— 真的失败了（连不上、返回码不对……）
signal claim_finished(result: Dictionary)
## 请求失败（连不上、超时、返回码不对、JSON 解不开）。`reason` 可直接显示给玩家。
signal request_failed(reason: String)

## 单个请求的超时（秒）。目录就在同一台机器上（房间）或公网上（界面），
## 10 秒足够；比这更久说明对方真的没了，早报错比让界面干等好。
const TIMEOUT := 10.0
## 房间登记自己的间隔（秒）。目录的 TTL 默认 6 秒，取它的三分之一——
## 这样连续丢两次登记也还不会从列表里消失。
const REGISTER_INTERVAL := 2.0

var _http: HTTPRequest = null
## 当前请求的用途，用来决定把结果发给哪个信号。
var _mode: String = ""
var _elapsed := 0.0
var _interval := 0.0
var _target := ""
## 登记内容的**提供者**（返回一个 Dictionary），而不是一份快照。
##
## 快照的写法踩过坑：房间把 body 存下来之后，`_process` 每 2 秒原样重发它，
## 于是"开局 → 玩家走光 → 回到等待中"这种**状态翻转永远传不到目录**——
## 目录会一直显示"进行中"，而现象是别人看不到这间空着房。
## 改成回调之后，每次发送都重新取一遍当前状态，不再有"忘了刷新"这种可能。
var _provider: Callable = Callable()
## 最近一次发出去的正文。只用于注销时取端口。
var _last_body: Dictionary = {}
var _enabled := false
## 等着的认领请求（基址）。空表示没有。
##
## **认领不能被丢掉。** 以前它在 `_mode != ""` 时直接 return，而界面已经把
## 自己锁成"正在向官方服务器要一间房…"——于是只要点「创建」的那一刻刚好有个
## 列表请求在飞（界面每 3 秒拉一次，窗口不小），请求根本没发出去、界面也永远
## 等不到回信，而屏幕上就停在那一句话上，没有任何报错。真机上就是这么卡的。
## 现在把认领记下来，等在飞的那个一结束就发。
var _pending_claim := ""


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_completed)
	set_process(false)


## 取一次房间列表。`base` 形如 "http://host:port"。
## 与房间的定期登记不同，这是**一次性**的：界面需要时就拉一次。
func fetch_rooms(base: String) -> void:
	if _mode != "":
		# 上一个请求还在路上。丢弃新的而不是排队：列表是"尽力而为"的数据，
		# 排队只会让界面显示一份更旧的列表。
		return
	_mode = "fetch"
	_send(base.path_join("rooms"), HTTPClient.METHOD_GET, {})


## 向目录要一间空房（玩家的「创建公网房间」）。
##
## 为什么不能自己从列表里挑一间空的：列表里**根本没有空房**——空着的备用房
## 由目录滤掉了（否则玩家一打开界面就看见一堆没人进的房间）。而认领这个动作
## 必须由目录原子地完成，否则两个人同时点「创建」会拿到同一间。
## 见 tools/room-directory.py 的 claim()。
##
## 返回是**异步**的，结果走 `claim_finished` 信号。
##
## 上一个请求还在路上时**不会丢弃**：记下来，等它一结束就发（见 `_pending_claim`）。
## 这一点是必需的——丢掉的代价是界面永久卡住，而不是"少一次列表刷新"。
func claim_room(base: String) -> void:
	if _mode != "":
		_pending_claim = base
		return
	_mode = "claim"
	_send(base.path_join("rooms/claim"), HTTPClient.METHOD_POST, {})


## 把等着的那次认领发出去。用 `call_deferred` 调，因此它总在本次请求的
## 信号发完之后才跑（否则调用方会先收到旧记号的结果、再看到新请求已上路，
## 两边的状态会对不上）。
func _send_pending_claim() -> void:
	if _pending_claim.is_empty() or _mode != "":
		return
	var base := _pending_claim
	_pending_claim = ""
	_mode = "claim"
	_send(base.path_join("rooms/claim"), HTTPClient.METHOD_POST, {})


## 开始定期登记。`base` 形如 "http://host:port"，`provider` 是一个**每次发送时**
## 被调用、返回房间当前自我描述（Dictionary）的可调用对象。
## 立即发一次（不让列表空等一个周期），之后每 REGISTER_INTERVAL 秒刷新。
func start_registering(base: String, provider: Callable) -> void:
	_target = base
	_provider = provider
	_interval = REGISTER_INTERVAL
	_enabled = true
	_elapsed = _interval
	set_process(true)


## 立刻发一次登记，不等下一个周期。用于玩家等了会明显看出滞后的时刻
##（刚开局、刚改完名字）。
func refresh_now() -> void:
	if _enabled:
		_elapsed = _interval


## 停止登记，并尽量通知目录把自己摘掉（`DELETE`）。
## 进程被强杀时这一步跑不到，那种情况由目录的 TTL 兜住。
func stop_registering() -> void:
	if not _enabled:
		return
	_enabled = false
	set_process(false)
	if _mode == "":
		_mode = "unregister"
		_send(_target.path_join("rooms") + "?port=%d" % int(_last_body.get("port", 0)),
			HTTPClient.METHOD_DELETE, {})


func _process(delta: float) -> void:
	if not _enabled:
		return
	_elapsed += delta
	if _elapsed < _interval:
		return
	_elapsed = 0.0
	if _mode != "":
		# 上一个登记还在路上。跳过这一轮而不是排队：登记是"最新的说了算"，
		# 补发一条过期的没有意义。
		return
	var body = _provider.call()
	if not (body is Dictionary) or (body as Dictionary).is_empty():
		# 提供者拿不到内容（例如还没有对外地址）。不发，但也不报错：
		# 下一个周期会再试，而那正是需要的行为（地址可能晚一步才拿得到）。
		return
	_last_body = body
	_mode = "register"
	_send(_target.path_join("rooms"), HTTPClient.METHOD_POST, _last_body)


func _send(url: String, method: int, body: Dictionary) -> void:
	var headers := PackedStringArray(["Content-Type: application/json; charset=utf-8"])
	var payload := "" if method == HTTPClient.METHOD_GET else JSON.stringify(body)
	# JSON.stringify 会产生非 ASCII 的转义（\u7194 这类），因此正文是纯 ASCII，
	# 但把它显式声明成 UTF-8 仍然是对的：房间名可能是中文，而抓包与调试时
	# 一个声明正确的字符集能省掉一轮"是不是编码问题"的怀疑。
	var err := _http.request(url, headers, method, payload)
	if err != OK:
		_finish("无法连接房间目录（%s）" % error_string(err))


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var mode := _mode
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish("房间目录没有响应（%s）" % _result_name(result))
		return
	if code < 200 or code >= 300:
		_finish("房间目录返回了 HTTP %d" % code)
		return
	var text := body.get_string_from_utf8()
	match mode:
		"fetch":
			var parsed = JSON.parse_string(text)
			if not (parsed is Dictionary) or not ((parsed as Dictionary).get("rooms") is Array):
				_finish("房间目录返回的内容看不懂")
				return
			_finish("")
			rooms_fetched.emit((parsed as Dictionary)["rooms"] as Array)
		"claim":
			var claimed = JSON.parse_string(text)
			if not (claimed is Dictionary):
				_finish("房间目录返回的内容看不懂")
				return
			# `waiting` 是成功的一次往返（HTTP 200），只是目录现在没有空房。
			# 因此这里不走 _finish 的报错分支，否则日志里会多出一行不存在的错误。
			var payload := claimed as Dictionary
			if bool(payload.get("waiting", false)):
				_finish("")
				claim_finished.emit({"ok": false, "waiting": true})
				return
			if not bool(payload.get("ok", false)):
				# 不在这里自己 emit：_finish 在 claim 模式下会把原因发出去，
				# 两处都发就会让上游收到两次（界面上表现为重试两次）。
				_finish("房间目录拒绝了这次请求")
				return
			_finish("")
			claim_finished.emit(payload)
		"register":
			# 登记的结果不影响游戏本身（失败只是这一间不会出现在列表里）。
			# 因此只记一行，不弹给玩家——玩家在大厅里，看到的应该是房间，不是目录的事。
			_finish("")
		"unregister":
			_finish("")
		_:
			_finish("")


## 收尾。出错时发信号并给出一条可直接显示的说明；成功时 reason 为空。
func _finish(reason: String) -> void:
	var mode := _mode
	_mode = ""
	if not reason.is_empty():
		# **用 print 而不是 push_warning。** 事后会把整段 GDScript 调用栈写进 journal，
		# 而登记每 2 秒重试一次——目录重启的那几秒会给日志刷满没人看懂的堆栈，
		# 把真正的报错淹掉。这里要的只是"知道了"，一行就够了。
		print("[dir] %s（%s）" % [reason, mode])
		# 登记失败不打扰玩家（见上），只有取列表与认领失败才是玩家能感知的。
		if mode == "fetch":
			request_failed.emit(reason)
		elif mode == "claim":
			claim_finished.emit({"ok": false, "reason": reason})
	if not _pending_claim.is_empty():
		call_deferred("_send_pending_claim")


func _result_name(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "连不上"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "域名解析不了"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "连接中断"
		HTTPRequest.RESULT_TIMEOUT:
			return "超时"
	return "错误码 %d" % result


## 由主机与端口拼出目录的基址。放在这里而不是各调用点：拼法只有一份，
## 不会出现"界面用 http:// 而房间用了别的"这种不一致。
static func base_url(host: String, port: int) -> String:
	return "http://%s:%d" % [host, port]
