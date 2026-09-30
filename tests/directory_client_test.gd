extends SceneTree
## 目录客户端的接线测试，重点是**认领不能被丢掉**。
##
## 真机上踩到过：点「创建房间」之后界面永久停在「正在向官方服务器要一间房…」，
## 而服务器日志里**根本没有那次请求**。原因是 `claim_room()` 在 `_mode != ""` 时
## 直接 return，于是在飞的那个请求（界面每 3 秒拉一次列表）会把认领吞掉，
## 界面那边却已经把自己锁住了。
##
## 这条只有对着**真目录**才测得出来：要断言的是"请求真的发出去了、回信真的到了"，
## 而替身（tests/menu_test.gd 里那个）恰好把这两件事都跳过了。
##
## 由 tools/directory-client-check.mjs 起一个真目录并把基址传进来：
##   godot --headless --path . --script tests/directory_client_test.gd -- \
##         --base http://127.0.0.1:27123 --expect-port 40231
##
## **也可以直接对着真服务器跑**，两种方式：
##   ... -- --from-config                    # 用 config/product.cfg 里的域名（含解析成 IP 这一步）
##   ... -- --base http://106.52.118.93:27017
## 前者会额外验"域名解析 → 用 IP 发 HTTP"这条链（就是腾讯云拦截的那个坑，见 product.cfg）。
##
## 退出码 0 表示全部通过。

const Config := preload("res://scripts/product_config.gd")

const DirectoryClientScript := preload("res://scripts/net/directory_client.gd")

## 每一步的等待上限（秒）。认领最坏情况要等目录那边补一间，给它宽一点。
const STEP_TIMEOUT := 20.0
## 拿到 `waiting`（目录暂时没有空房）之后重试的上限与间隔。
##
## 需要它是因为**池刚重启时前几秒确实没有备用房**（对账 2 秒 + 房间启动一两秒），
## 而目录回答的 `waiting` 是 HTTP 200，不是错误。界面也是这么重试的
## （scripts/menu.gd 的 CLAIM_RETRY_INTERVAL / CLAIM_RETRY_LIMIT）。
const CLAIM_RETRIES := 15
const CLAIM_RETRY_INTERVAL := 2.0

var _base := ""
var _expect_port := 0
## 用配置里的域名（而不是 --base）。见文件头。
var _from_config := false
## 解析那一步的等待上限（秒）。DNS 正常时是毫秒级。
const CONFIG_RESOLVE_LIMIT := 12.0

var _checks := 0
var _failures := PackedStringArray()

## 故意不写类型：`claim_finished` / `fetch_rooms` 都是脚本上的方法，
## 而这一层要验的就是"这些方法按约定的方式被调用"，不必要额外的类型约束。
var _client = null
var _probe = null

var _claims: Array = []
var _listed: Array = []
## 探针**收到了响应**（哪怕是个空列表）。不能拿 `_listed.is_empty()` 当"收到了"：
## 空列表是一个完全合法的响应（目录里现在真没人公开房间），把两者混为一谈
## 会让这一步白等到超时——而且看起来像功能坏了。
var _listed_any := false
var _claim_retries := CLAIM_RETRIES
var _retry_elapsed := 0.0
var _config_resolve_started := false
var _claim_port := 0
var _stage := 0
var _stage_elapsed := 0.0
var _finished := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	# 打出来：这个驱动靠 `--` 之后的参数决定跑哪条路，而参数没传到时
	# 现象是"它去跑另一条路了"，从断言上完全看不出原因。
	print("[drive] 用户参数：%s" % [args])
	for i in args.size():
		if args[i] == "--base" and i + 1 < args.size():
			_base = String(args[i + 1])
		elif args[i] == "--expect-port" and i + 1 < args.size():
			_expect_port = int(args[i + 1])
		elif args[i] == "--from-config":
			_from_config = true


func _process(delta: float) -> bool:
	if _finished:
		return true
	_stage_elapsed += delta
	if _stage_elapsed > _stage_timeout():
		_fail("第 %d 步等了 %.0f 秒没有结果" % [_stage, _stage_timeout()])
		_finish()
		return true
	match _stage:
		# 用配置里的域名时，先等域名解析完（异步，因此要跳帧）；否则直接开始。
		# **注意这个 match 里每个编号只能出现一次**：重复时 GDScript 取第一个，
		# 后面那个就成了死代码，而现象是"参数传了却没生效"。
		0:
			_wait_config_resolve(delta)
		# 认领的结果必须到（这一步就是真机上的那个 bug）
		1:
			_wait_claim()
		# 用另一个客户端拉一次列表，确认服务器那边**确实**收到了这次认领
		2:
			_probe_list()
		3:
			_wait_list()
		# 认领排队在**认领**后面（不只是排在列表后面）
		4:
			_queue_two_claims()
		5:
			_wait_two_claims()
		_:
			_finish()
	return false


# ---------------------------------------------------------------- 步骤

## 每一步的等待上限。认领那一步要额外装下重试预算（池刚重启时要等它补上一间），
## 其余步骤就用 STEP_TIMEOUT——坏掉的时候要尽快报出来，而不是干等一分钟。
func _stage_timeout() -> float:
	if _stage == 0:
		return CONFIG_RESOLVE_LIMIT + STEP_TIMEOUT
	if _stage == 1:
		return STEP_TIMEOUT + CLAIM_RETRIES * CLAIM_RETRY_INTERVAL
	return STEP_TIMEOUT


## 用配置里的域名时，先把它解析成 IP（与客户端启动时做的事完全一样）。
##
## **这一步就是腾讯云拦截那个坑的回归守卫**：配置里存的是域名，而 HTTP 必须用 IP 发，
## 否则拿到的是 DNSPod 的封禁页（于是"列表永远拉不到"）。
func _wait_config_resolve(delta: float) -> void:
	if not _from_config:
		_setup()
		return
	if _stage_elapsed >= CONFIG_RESOLVE_LIMIT:
		_fail("配置里的域名在 %.0f 秒内没有解析出结果" % CONFIG_RESOLVE_LIMIT)
		_finish()
		return
	if _config_resolve_started and not Config.pump_resolving(delta):
		return
	if not _config_resolve_started:
		Config.load_from_disk()
		Config.begin_resolving()
		_config_resolve_started = true
		print("[drive] 配置：%s" % Config.describe())
		return
	# 解析有结果了（成功、失败或超时）。
	_ok(Config.resolve_state() == Config.Resolve.DONE,
		"配置里的域名应当能解析成 IP（实际状态 %d）" % Config.resolve_state())
	_ok(Config.resolved_address().is_valid_ip_address(),
		"解析结果应当是个 IP，实际「%s」" % Config.resolved_address())
	_base = Config.official_directory_url()
	# **地址里必须是 IP 而不是域名**：Host 头是它，而拦截看的就是 Host。
	_ok(_base.contains(Config.resolved_address()) and not _base.contains(Config.official_host()),
		"目录地址应当用解析出的 IP（%s，域名是 %s，得到「%s」）" % [
			Config.resolved_address(), Config.official_host(), _base,
		])
	_setup()


func _setup() -> void:
	if _base.is_empty():
		_fail("没有拿到 --base 或 --from-config，检查调用方式（见文件头）")
		_finish()
		return
	_client = DirectoryClientScript.new()
	root.add_child(_client)
	_client.claim_finished.connect(_on_claim_finished)
	# **起一个列表请求，紧接着就认领**——这正是真机上的那一刻：
	# 界面的定期刷新还在飞，玩家点了「创建房间」。
	_client.fetch_rooms(_base)
	_client.claim_room(_base)
	_next_stage()


func _wait_claim() -> void:
	if _claims.is_empty():
		return
	var result: Dictionary = _claims[_claims.size() - 1]
	# **这一步的回归断言是"回信到了"，不是"回信说 ok"。**
	# 真机上坏掉的是请求根本没发出去（界面那边于是永远等下去），
	# 而 `waiting` 是一个完全正常的回答：池刚重启那几秒就是没有备用房。
	if not bool(result.get("ok", false)) and bool(result.get("waiting", false)) and _claim_retries > 0:
		_claim_retries -= 1
		_retry_elapsed += 1.0
		if _retry_elapsed >= CLAIM_RETRY_INTERVAL:
			_retry_elapsed = 0.0
			# 与界面同一条路：再发一次认领（客户端会排队，不会丢）。
			_client.claim_room(_base)
		return
	_ok(_claims.size() > 0, "认领收到了回信（共 %d 次，最后一次 %s）" % [_claims.size(), result])
	_ok(bool(result.get("ok", false)), "最终拿到了房间（实际 %s）" % result)
	_claim_port = int(result.get("port", 0))
	if _expect_port > 0:
		_ok(_claim_port == _expect_port, "拿到的应当是目录里那一间（期望 %d，实际 %d）" % [_expect_port, _claim_port])
	else:
		# 对着真服务器跑时不知道哪一间空着（池里那几间是算出来的），只查"拿到了一个端口"。
		_ok(_claim_port > 0, "认领应当给出一个端口（实际 %d）" % _claim_port)
	# 这一步的等待上限要按重试预算放宽（池刚重启时要等它补上一间）。
	_next_stage()


func _probe_list() -> void:
	_probe = DirectoryClientScript.new()
	root.add_child(_probe)
	_probe.rooms_fetched.connect(_on_rooms_fetched)
	_probe.fetch_rooms(_base)
	_next_stage()


func _wait_list() -> void:
	if not _listed_any:
		return
	var ports: Array = []
	for item in _listed:
		if item is Dictionary:
			ports.append(int((item as Dictionary).get("port", 0)))
	# 被认领的房间**必须出现在公开列表里**：这条同时证明了三件事——
	# 请求确实发到了服务器、目录把它算作"非空闲"、别人因此才看得到它。
	_ok(ports.has(_claim_port),
		"被认领的房间应当出现在公开列表里（列表里是 %s，认领到的是 %d）" % [ports, _claim_port])
	_next_stage()


func _queue_two_claims() -> void:
	# 连着两次认领：第二次一定在第一次的结果之前发生（第一次还在飞），
	# 因此它必须被排队而不是被吞掉。
	_client.claim_room(_base)
	_client.claim_room(_base)
	_next_stage()


func _wait_two_claims() -> void:
	# 1 次（前面那次）+ 2 次 = 3 次结果。此时那间房已被认领并保留着，
	# 所以后两次回答 `waiting` 是正常的——这里要断言的只是**回信到了**。
	if _claims.size() < 3:
		return
	_ok(true, "连着两次认领都收到了回信（收到 %d 次结果）" % _claims.size())
	_finish()


func _on_claim_finished(result: Dictionary) -> void:
	_claims.append(result)


func _on_rooms_fetched(rooms: Array) -> void:
	_listed = rooms
	_listed_any = true
	print("[drive] 列表到手：%d 项 %s" % [rooms.size(), rooms])


# ---------------------------------------------------------------- 断言与收尾

func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  ok  %s" % message)
	else:
		print("  --  %s" % message)
		_failures.append(message)


func _fail(message: String) -> void:
	_checks += 1
	print("  --  %s" % message)
	_failures.append(message)


func _next_stage() -> void:
	_stage += 1
	_stage_elapsed = 0.0


func _finish() -> void:
	if _finished:
		return
	_finished = true
	if _failures.is_empty():
		print("目录客户端接线测试通过（%d 项断言）。" % _checks)
		quit(0)
	else:
		print("目录客户端接线测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		quit(1)
