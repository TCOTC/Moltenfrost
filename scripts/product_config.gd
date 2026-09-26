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
const DEFAULT_OFFICIAL_PORT := 27015

## 端口的合法范围。取值不合法时回退到兜底值，并且报告出来——
## 静默修正比报错更难查：表面上"配置生效了"，实际用的是另一个值。
const MIN_PORT := 1
const MAX_PORT := 65535

static var _official_host := DEFAULT_OFFICIAL_HOST
static var _official_port := DEFAULT_OFFICIAL_PORT
## 生效值是否来自配置文件。只用于日志与提示文案。
static var _loaded_from_file := false
## 已经读过一次就不再读。重复读没有意义，而且会让日志重复。
static var _done := false


## 读一次配置文件并写进内存。由入口脚本在启动时调用一次；
## 单独测试时也可以直接调用，因此它不依赖自动加载或场景树。
## 返回是否成功从文件读到（内容不合法而回退的项会单独报告）。
static func load_from_disk() -> bool:
	_done = true
	# 先回到兜底值再尝试覆盖，这样重复调用不会把上一次的取值留在内存里。
	_official_host = DEFAULT_OFFICIAL_HOST
	_official_port = DEFAULT_OFFICIAL_PORT
	_loaded_from_file = false

	var config := ConfigFile.new()
	var err := config.load(PATH)
	if err != OK:
		push_warning("读不到 %s（%s），官方房间改用代码里的兜底值" % [PATH, error_string(err)])
		return false

	_loaded_from_file = true
	_official_host = _read_host(config)
	_official_port = _read_port(config)
	return true


static func official_host() -> String:
	_ensure_loaded()
	return _official_host


static func official_port() -> int:
	_ensure_loaded()
	return _official_port


## 生效值来自配置文件还是兜底值。给调用方决定提示文案用，
## 也让测试可以断言"文件确实被读到了"——否则把路径写错时测试照样会通过
##（因为兜底值恰好等于文件里的值）。
static func loaded_from_file() -> bool:
	_ensure_loaded()
	return _loaded_from_file


## 一行摘要，供入口脚本打进日志。
static func describe() -> String:
	_ensure_loaded()
	return "%s:%d（%s）" % [
		_official_host,
		_official_port,
		"来自 %s" % PATH if _loaded_from_file else "来自代码里的兜底值",
	]


# ---------------------------------------------------------------- 内部

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
	var raw = config.get_value("network", "official_port", DEFAULT_OFFICIAL_PORT)
	# ConfigFile 会把纯数字读成 int，但写成 "27015" 这样的带引号形式就是 String。
	# 两种都接受，其余一律回退。
	var port := 0
	if raw is int:
		port = raw
	elif raw is String and (raw as String).is_valid_int():
		port = int(raw)
	else:
		push_error("%s 的 network/official_port 不是整数（%s），改用兜底值 %d" % [PATH, raw, DEFAULT_OFFICIAL_PORT])
		return DEFAULT_OFFICIAL_PORT
	if port < MIN_PORT or port > MAX_PORT:
		push_error("%s 的 network/official_port=%d 超出 %d～%d，改用兜底值 %d" % [
			PATH, port, MIN_PORT, MAX_PORT, DEFAULT_OFFICIAL_PORT,
		])
		return DEFAULT_OFFICIAL_PORT
	return port
