extends SceneTree
## ProductConfig 的取值与回退测试。用 `--script` 直接跑：
##
##   godot --headless --path . --script tests/product_config_test.gd
##
## 覆盖三件事：
##   1. config/product.cfg 真的被读到了（而不是静默回退到代码里的兜底值）
##   2. 那个文件的字段结构正确（键名、类型）
##   3. 取值不合法时回退到兜底值，而不是把非法值放进界面
##
## 第 1 条为什么单独测：文件读不到、或键名拼错时，回退值是**故意与文件内容相同**的，
## 于是不管走哪条路径，界面上看到的地址都一样。这种"看起来完全正常"的失效
## 只能靠断言生效来源（loaded_from_file）与文件结构来发现。
##
## 这层测试在导出产物上同样重要：config/ 下的普通文本不是 Godot 的"资源"，
## 不显式 include 就不会进 pck（实测过）。用 tools/pck-find.mjs 复核产物里有没有它。
##
## 输出里会有几行 `ERROR: ...`，那是**故意的**：非法的配置取值应当被报告出来
##（工程里对命令行参数的非法取值也是 push_error，保持一致）。
## 因此看到 `ERROR` 不代表这个测试失败，判据是最后那行「产品常量测试通过」。

const Config := preload("res://scripts/product_config.gd")

## 解析那一步的等待上限（秒）。DNS 正常时是毫秒级，给宽一点只是防卡。
const RESOLVE_WAIT_LIMIT := 10.0

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _stage := 0
var _stage_elapsed := 0.0


func _process(delta: float) -> bool:
	_stage_elapsed += delta
	match _stage:
		0:
			_run_all()
			# 域名解析是**异步**的（见 product_config.gd 的 Resolve），因此要跨帧跑。
			Config.begin_resolving_for("localhost")
			_stage = 1
			_stage_elapsed = 0.0
		1:
			if not Config.pump_resolving(delta) and _stage_elapsed < RESOLVE_WAIT_LIMIT:
				return false
			_case_resolution()
			_finish()
	return false


func _run_all() -> void:
	_case_file_is_loaded()
	_case_file_schema()
	_case_host_validation()
	_case_port_validation()


# ---------------------------------------------------------------- 实际文件

func _case_file_is_loaded() -> void:
	# 先清掉可能已被别处读过的状态，确保这次真的走一遍读盘。
	Config.load_from_disk()
	_ok(Config.loaded_from_file(),
		"应当从 %s 读到配置（读不到会静默回退到兜底值，而两者取值相同，所以必须单独断言来源）" % Config.PATH)


func _case_file_schema() -> void:
	# 直接打开文件核对字段结构，不经过加载器。
	# 加载器用 get_value(..., 默认值) 取值，**键名拼错时它会安静地用默认值**，
	# 而默认值与文件里的值相同，于是没有任何现象。只有在这里查有没有那个键才拦得住。
	var config := ConfigFile.new()
	var err := config.load(Config.PATH)
	_ok(err == OK, "%s 应当能打开，实际 %s" % [Config.PATH, error_string(err)])
	if err != OK:
		return
	_ok(config.has_section("network"), "配置应当有 [network] 段")
	_ok(config.has_section_key("network", "official_host"), "配置应当有 network/official_host 键（键名拼错会被静默忽略）")
	_ok(config.has_section_key("network", "official_directory_port"), "配置应当有 network/official_directory_port 键（键名拼错会被静默忽略）")

	var host := String(config.get_value("network", "official_host", ""))
	_ok(not host.is_empty(), "配置里的 official_host 不应为空")
	# 与界面侧的属性检查同一套判据：域名或 IP 都含点，且不含空格。
	_ok(host.contains(".") and not host.contains(" "), "配置里的 official_host 应当像个域名或 IP，实际「%s」" % host)


# ---------------------------------------------------------------- 回退路径

func _case_host_validation() -> void:
	var empty := ConfigFile.new()
	empty.set_value("network", "official_host", "   ")
	_ok(Config._read_host(empty) == Config.DEFAULT_OFFICIAL_HOST,
		"主机名为空白时应当回退到兜底值")

	var ok := ConfigFile.new()
	ok.set_value("network", "official_host", "  example.com  ")
	_ok(Config._read_host(ok) == "example.com",
		"主机名应当去掉首尾空白，实际「%s」" % Config._read_host(ok))


func _case_port_validation() -> void:
	# 合法取值：写入时是 int
	var ok_int := ConfigFile.new()
	ok_int.set_value("network", "official_directory_port", 27017)
	_ok(Config._read_port(ok_int) == 27017, "整数端口应当被接受")

	# 合法取值：写成带引号的字符串（人手编辑时很容易这样写）
	var ok_str := ConfigFile.new()
	ok_str.set_value("network", "official_directory_port", "27017")
	_ok(Config._read_port(ok_str) == 27017, "写成字符串的整数端口也应当被接受")

	# 非法取值：**每个分支取一个代表就够，不按值穷举**。
	# 理由是穷举只会重复触发同一条分支，而每次都会 push_error 打一段堆栈，
	# 把测试输出淹掉——那种噪声会让人开始忽略错误行，代价比覆盖面更大。
	# 下面两个各对应一条分支：类型不对、以及数值越界。
	var bad_type := ConfigFile.new()
	bad_type.set_value("network", "official_directory_port", "abc")
	_ok(Config._read_port(bad_type) == Config.DEFAULT_OFFICIAL_DIRECTORY_PORT,
		"端口不是整数时应当回退到兜底值 %d，实际 %d" % [Config.DEFAULT_OFFICIAL_DIRECTORY_PORT, Config._read_port(bad_type)])

	var bad_range := ConfigFile.new()
	bad_range.set_value("network", "official_directory_port", 70000)
	_ok(Config._read_port(bad_range) == Config.DEFAULT_OFFICIAL_DIRECTORY_PORT,
		"端口越界时应当回退到兜底值 %d，实际 %d" % [Config.DEFAULT_OFFICIAL_DIRECTORY_PORT, Config._read_port(bad_range)])

	# 键不存在时也应当回退（配置文件是旧版本、或那一行被删掉）。
	var missing := ConfigFile.new()
	missing.set_value("network", "other_key", 1234)
	_ok(Config._read_port(missing) == Config.DEFAULT_OFFICIAL_DIRECTORY_PORT,
		"端口键不存在时应当回退到兜底值")

	# 目录的端口**不应等于**游戏端口。它以前就是游戏端口（那时官方是一个固定房间），
	# 路线 A 之后它是一个 HTTP 目录的端口，两者相同反而说明配置没跟着改。
	_ok(Config.DEFAULT_OFFICIAL_DIRECTORY_PORT != Net.DEFAULT_PORT,
		"目录端口不应当等于游戏端口（%d），否则说明配置还停在旧结构上" % Net.DEFAULT_PORT)


# ---------------------------------------------------------------- 域名解析

## 域名能解析成 IP，而且**用的是解析出来的那一个**。
##
## 为什么必须验这一层：客户端拉列表与创建房间走的都是 HTTP，而腾讯云会拦发往
## 未备案域名的 HTTP（302 到 DNSPod 的封禁页，见 config/product.cfg）。
## 修法是"配置里存域名，连接时用解析出的 IP"，而**这条链路一旦断掉，
## 现象就是"列表永远拉不到"**，与"服务坏了"长得一模一样。
##
## 用 localhost 而不是真实域名：它由操作系统的 hosts 文件处理，
## 因此这个自检不依赖外网，也不会因为 DNS 抽风而失败。
func _case_resolution() -> void:
	_ok(Config.resolve_state() == Config.Resolve.DONE,
		"localhost 应当能解析成功（实际状态 %d，结果「%s」）" % [Config.resolve_state(), Config.resolved_address()])
	_ok(Config.resolved_address().is_valid_ip_address(),
		"解析结果应当是个 IP，实际「%s」" % Config.resolved_address())
	_ok(Config.directory_ready(), "解析完成后应当报告「可以发请求」")
	# **结果只能用在它自己的主机名上。** `_resolved_for` 这个记录就是为这一条存在的：
	# 测试刚把 localhost 解析了，而配置里的主机名不是它，因此目录地址不该被改掉——
	# 否则一个测试就会把别的用途的地址污染掉（而那种错很难看出来）。
	_ok(Config.directory_host() == Config.official_host(),
		"为别的主机名解析的结果不应影响目录地址（得到「%s」，应当是「%s」）" % [Config.directory_host(), Config.official_host()])
	# 配置里本来就是 IP 时不应当去查 DNS（备案之后有人直接写 IP 也应当能用）。
	Config.begin_resolving_for("127.0.0.1")
	_ok(Config.resolve_state() == Config.Resolve.DONE and Config.resolved_address() == "127.0.0.1",
		"主机名已经是 IP 时应当直接算完成，实际 %d / 「%s」" % [Config.resolve_state(), Config.resolved_address()])


# ---------------------------------------------------------------- 收尾

func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("产品常量测试通过（%d 项断言）。" % _checks)
		quit(0)
	else:
		print("产品常量测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		quit(1)
