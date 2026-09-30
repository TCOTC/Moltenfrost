class_name ProductConfig
extends RefCounted
## 产品级可变量（域名、端口等）的读取入口，数据在 config/product.cfg。
##
## 与"手感数值"（scripts/player.gd 的 static var）走同一种思路：
## **代码里留一份兜底值，外部可以覆盖，启动时把生效值打进日志。**
## 这样分开的理由是它们的变化频率与变化者不同：手感数值由调参的人改，
## 产品常量（如官方服务器域名）由部署的人改，而后者不该为此动代码。
##
## 为什么用 ConfigFile（.cfg）而不是自定义 Resource（.tres）：
##   .cfg 是普通文本，任何人拿编辑器都能改，而且**引擎不会改写它**，
##   所以文件里的注释能留住；.tres 由编辑器保存时整份重写，注释必丢（见 AGENTS.md）。
##   .tres 的唯一优势是被自动识别为资源、必然进导出产物——但那件事可以由
##   export_presets.cfg 的 include_filter 解决，且它是一次性的配置。
##
## 兜底值的意义不只是"容错"：配置文件缺失、键名拼错、类型不对时都回退到它，
## 于是最坏情况只是回到编译时那个地址，而不是程序起不来。

## 配置文件路径。放在 res:// 下，因此导出后从 PCK 里读。
const PATH := "res://config/product.cfg"

## 兜底值。与 config/product.cfg 中的取值保持一致；
## 不一致时以配置文件为准。改这里只是为了"文件丢了也能用"。

const DEFAULT_OFFICIAL_HOST := "moltenfrost-server.mytemos.com"
## 官方房间目录的端口（HTTP，TCP）。
## 路线 A 之后不再有"那一个官方房间"：房间是目录里的一列，各自带自己的 host:port，
## 因此这里只需要目录的端口（见 docs/公网房间方案.md）。
const DEFAULT_OFFICIAL_DIRECTORY_PORT := 27017

## 域名解析的状态。
##
## 为什么非要有这一步：客户端拉列表与创建房间走的都是 **HTTP**，而腾讯云会拦截
## 发往**未备案域名**的 HTTP 请求（302 到 DNSPod 的封禁页），于是列表永远拉不到；
## 同一个请求换成 IP 就正常（实测见 config/product.cfg）。
## 因此配置里存域名（换机器只改 DNS），连接时用解析出的 IP。
## UDP（房间地址）不受这条拦截影响，那边的域名由服务端的 --advertise 给出。
enum Resolve {
	NONE, ## 还没开始。
	WAITING, ## 正在解析（异步，不阻塞主线程）。
	DONE, ## 解析到了 IP。
	FAILED, ## 解析失败或超时，改用配置里的域名（若那个域名没被拦，照样能用）。
}

## 解析的超时（秒）。DNS 正常时是毫秒级；**卡住时必须能往下走**，
## 否则界面会一直等一个永不到来的结果。
const RESOLVE_TIMEOUT := 5.0

static var _official_host := DEFAULT_OFFICIAL_HOST
static var _official_directory_port := DEFAULT_OFFICIAL_DIRECTORY_PORT
## 生效值是否来自配置文件。只用于日志与提示文案。
static var _loaded_from_file := false
## 已经读过一次就不再读。重复读没有意义，而且会让日志重复。
static var _done := false

## 解析状态与结果。`_resolved_for` 记住这个 IP 是**为哪个主机名**解析的：
## 配置改过（重新 load_from_disk）之后旧结果就不能再用了。
static var _resolve_state: int = Resolve.NONE
static var _resolved_for := ""
static var _resolved_address := ""
## 异步解析的队列 id（-1 表示没有）。用完要 erase，否则会占着解析槽。
static var _resolve_id := -1
static var _resolve_elapsed := 0.0


## 端口的合法范围。取值不合法时回退到兜底值，并且报告出来——
## 静默修正比报错更难查：表面上"配置生效了"，实际用的是另一个值。
const MIN_PORT := 1
const MAX_PORT := 65535


## 读一次配置文件并写进内存。由入口脚本在启动时调用一次；
## 单独测试时也可以直接调用，因此它不依赖自动加载或场景树。
## 返回是否成功从文件读到（内容不合法而回退的项会单独报告）。
static func load_from_disk() -> bool:
	_done = true
	# 先回到兜底值再尝试覆盖，这样重复调用不会把上一次的取值留在内存里。
	_official_host = DEFAULT_OFFICIAL_HOST
	_official_directory_port = DEFAULT_OFFICIAL_DIRECTORY_PORT
	_loaded_from_file = false
	# 主机名可能变了，旧解析结果作废（见 _resolved_for）。
	_clear_resolution()

	var config := ConfigFile.new()
	var err := config.load(PATH)
	if err != OK:
		push_warning("读不到 %s（%s），官方房间改用代码里的兜底值" % [PATH, error_string(err)])
		return false

	_loaded_from_file = true
	_official_host = _read_host(config)
	_official_directory_port = _read_port(config)
	return true


static func official_host() -> String:
	_ensure_loaded()
	return _official_host


static func official_directory_port() -> int:
	_ensure_loaded()
	return _official_directory_port


## 目录 HTTP 实际要连的地址。**配置里是域名时用解析出的 IP**（理由见 Resolve 的说明）。
static func directory_host() -> String:
	_ensure_loaded()
	if _resolved_for == _official_host and not _resolved_address.is_empty():
		return _resolved_address
	return _official_host


## 目录的基址，形如 "http://host:port"。拼法只有这一份。
##
## 用的是 directory_host()，因此域名会被换成解析出的 IP——**Host 头也跟着是 IP**，
## 那正是绕开拦截的关键（拦截看的是 Host 里那个没备案的域名）。
static func official_directory_url() -> String:
	return DirectoryClient.base_url(directory_host(), official_directory_port())


## 现在能不能向目录发请求。域名还在解析时是 false。
##
## 为什么不让调用方自己决定：拿域名去发一次注定被拦的请求，报出来的错是"拉不到列表"，
## 而那与"服务坏了"长得一模一样——会把人往错的方向带。等几百毫秒比给一个误导的报错好。
static func directory_ready() -> bool:
	_ensure_loaded()
	return _resolve_state != Resolve.WAITING


## 开始解析官方目录的主机名。幂等：已经解析过或正在解析时什么都不做。
static func begin_resolving() -> void:
	begin_resolving_for(official_host())


## 对任意主机名走同一条解析路径（给测试用，以及将来可能有第二个地址时复用）。
static func begin_resolving_for(host: String) -> void:
	var target := host.strip_edges()
	if target.is_empty():
		return
	if _resolve_state == Resolve.WAITING or (_resolved_for == target and _resolve_state == Resolve.DONE):
		return
	_clear_resolution()
	_resolved_for = target
	_resolve_elapsed = 0.0
	if target.is_valid_ip_address():
		# 配的就是 IP，不必解析（这种情况仍然支持：备案之后可能有人直接写 IP）。
		_resolved_address = target
		_resolve_state = Resolve.DONE
		return
	# **异步**，不在主线程里做 DNS：getaddrinfo 在 DNS 不通时可能卡好几秒，
	# 而这一步发生在启动路径上。
	_resolve_id = IP.resolve_hostname_queue_item(target, IP.TYPE_IPV4)
	if _resolve_id == IP.RESOLVER_INVALID_ID:
		push_warning("无法发起对 %s 的域名解析，直接用域名（若它被拦就拉不到列表）" % target)
		_resolve_state = Resolve.FAILED
		return
	_resolve_state = Resolve.WAITING


## 每帧推一下解析。由入口脚本的 `_process` 调。
##
## 返回 true 表示**状态刚刚变成可用**（解析成功、失败、或超时），
## 调用方据此立刻重试一次（否则要等到下一个刷新周期才知道地址能用）。
static func pump_resolving(delta: float) -> bool:
	if _resolve_state != Resolve.WAITING:
		return false
	_resolve_elapsed += delta
	if _resolve_elapsed >= RESOLVE_TIMEOUT:
		_report_resolve_failure("等了 %.0f 秒没有结果" % RESOLVE_TIMEOUT)
		return true
	match IP.get_resolve_item_status(_resolve_id):
		IP.RESOLVER_STATUS_WAITING:
			return false
		IP.RESOLVER_STATUS_DONE:
			var address := IP.get_resolve_item_address(_resolve_id)
			_erase_resolve_item()
			if not address.is_valid_ip_address():
				_report_resolve_failure("解析结果为「%s」，不像个 IP" % address)
				return true
			_resolved_address = address
			_resolve_state = Resolve.DONE
			return true
		IP.RESOLVER_STATUS_ERROR:
			_erase_resolve_item()
			_report_resolve_failure("解析失败（域名拼错？DNS 不可用？）")
			return true
	# RESOLVER_STATUS_NONE：队列项已经没了（不该发生），当作失败而不是继续等。
	_erase_resolve_item()
	_report_resolve_failure("解析队列项不见了")
	return true


## 解析结果（没有时为空串）。给日志与测试用。
static func resolved_address() -> String:
	return _resolved_address


## 解析状态，见 Resolve。
static func resolve_state() -> int:
	return _resolve_state


## 生效值来自配置文件还是兜底值。给调用方决定提示文案用，
## 也让测试可以断言"文件确实被读到了"——否则把路径写错时测试照样会通过
##（因为兜底值恰好等于文件里的值）。
static func loaded_from_file() -> bool:
	_ensure_loaded()
	return _loaded_from_file


## 一行摘要，供入口脚本打进日志。
##
## **解析结果也在这一行里**：现场排查时首先要看的就是"到底连的是哪个地址"，
## 而域名与 IP 是两个不同的东西（拦截就是卡在这两者之间）。
static func describe() -> String:
	_ensure_loaded()
	var source := "来自 %s" % PATH if _loaded_from_file else "来自代码里的兜底值"
	var extra := ""
	match _resolve_state:
		Resolve.WAITING:
			extra = "；正在解析域名…"
		Resolve.DONE:
			if _resolved_for == _official_host and _resolved_address != _official_host:
				extra = "；域名解析为 %s" % _resolved_address
		Resolve.FAILED:
			extra = "；域名没解析出来，直接用域名（若它被拦就拉不到列表）"
	return "%s:%d（%s%s）" % [_official_host, _official_directory_port, source, extra]


# ---------------------------------------------------------------- 内部

## 清掉解析状态。**不碰 _official_host**：它由配置文件决定。
static func _clear_resolution() -> void:
	_erase_resolve_item()
	_resolve_state = Resolve.NONE
	_resolved_for = ""
	_resolved_address = ""
	_resolve_elapsed = 0.0


static func _erase_resolve_item() -> void:
	if _resolve_id != IP.RESOLVER_INVALID_ID:
		# 用完要还回去：解析槽是有限的（IP.RESOLVER_MAX_QUERIES）。
		IP.erase_resolve_item(_resolve_id)
		_resolve_id = -1


## 解析没成功时的收尾。**不当作致命**：域名可能就是通的（已备案），
## 或者配置里写的就是 IP。因此只记一行说明，然后正常往下走。
static func _report_resolve_failure(reason: String) -> void:
	_resolve_state = Resolve.FAILED
	_resolve_elapsed = 0.0
	print("[config] %s 没能解析成 IP（%s），直接用域名——若它被拦截，列表会拉不到" % [
		_resolved_for, reason,
	])


static func _ensure_loaded() -> void:
	if not _done:
		load_from_disk()


## 读主机名并校验。空字符串是非法的：它会生成一个连不上的条目，
## 而那种条目在界面上看起来完全正常，只有点下去才会失败。
static func _read_host(config: ConfigFile) -> String:
	var raw := String(config.get_value("network", "official_host", DEFAULT_OFFICIAL_HOST)).strip_edges()
	if raw.is_empty():
		push_error("%s 的 network/official_host 是空的，官方房间改用兜底值 %s" % [PATH, DEFAULT_OFFICIAL_HOST])
		return DEFAULT_OFFICIAL_HOST
	return raw


## 读端口并校验范围。取值来自文本文件，可能写成任何东西，
## 因此这里既查类型也查范围，越界就报告并回退。
static func _read_port(config: ConfigFile) -> int:
	var raw = config.get_value("network", "official_directory_port", DEFAULT_OFFICIAL_DIRECTORY_PORT)
	# ConfigFile 会把纯数字读成 int，但写成 "27017" 这样的带引号形式就是 String。
	# 两种都接受，其余一律回退。
	var port := 0
	if raw is int:
		port = raw
	elif raw is String and (raw as String).is_valid_int():
		port = int(raw)
	else:
		push_error("%s 的 network/official_directory_port 不是整数（%s），改用兜底值 %d" % [
			PATH, raw, DEFAULT_OFFICIAL_DIRECTORY_PORT,
		])
		return DEFAULT_OFFICIAL_DIRECTORY_PORT
	if port < MIN_PORT or port > MAX_PORT:
		push_error("%s 的 network/official_directory_port=%d 超出 %d～%d，改用兜底值 %d" % [
			PATH, port, MIN_PORT, MAX_PORT, DEFAULT_OFFICIAL_DIRECTORY_PORT,
		])
		return DEFAULT_OFFICIAL_DIRECTORY_PORT
	return port
