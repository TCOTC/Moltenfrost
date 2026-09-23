class_name NetCmdline
extends RefCounted
## 联机相关的命令行参数解析。
##
## 单独成一个文件是为了让启动流程与网络层都不必关心参数从哪来：
## scripts/main.gd 只问一次"本机该当主机还是客户端"。
##
## 推荐写法是把自定义参数放在 `--` 之后，交给 OS.get_cmdline_user_args()：
##   godot --headless --path . -- --host --port 27015
## 但直接写在引擎参数里也接受。`--host` 这类名字不与引擎自带参数冲突，
## 而未识别的参数引擎会忽略（官方文档明确写了不会给出任何提示），
## 所以两种写法都扫一遍，后扫到的覆盖先扫到的。


## 读取本进程的命令行，返回形如 {"host": true, "join": "1.2.3.4", "port": 27015} 的字典。
## 没有出现的键即代表没有传该参数。
static func from_process() -> Dictionary:
	var opts := parse(OS.get_cmdline_args())
	opts.merge(parse(OS.get_cmdline_user_args()), true)
	return opts


## 解析一个参数数组。取值缺失或格式不对时报告错误，并跳过该参数。
static func parse(args: PackedStringArray) -> Dictionary:
	var opts := {}
	var i := 0
	while i < args.size():
		match args[i]:
			"--host":
				opts["host"] = true
			"--join":
				var address := _value_at(args, i + 1)
				if address.is_empty():
					push_error("--join 后面需要接一个地址，例如 --join 192.168.1.20")
				else:
					opts["join"] = address
					i += 1
			"--port":
				var raw := _value_at(args, i + 1)
				if not raw.is_valid_int():
					push_error("--port 需要接一个整数端口号，收到：%s" % raw)
				else:
					opts["port"] = int(raw)
					i += 1
			"--net-stats":
				opts["net_stats"] = true
			"--autopilot":
				opts["autopilot"] = true
			"--autopilot-stop":
				opts["autopilot_stop"] = true
			"--interp-buffer":
				var buffer_raw := _value_at(args, i + 1)
				if not buffer_raw.is_valid_float():
					push_error("--interp-buffer 需要接一个秒数，例如 --interp-buffer 0.25，收到：%s" % buffer_raw)
				else:
					opts["interp_buffer"] = float(buffer_raw)
					i += 1
			"--physics-hz":
				var hz_raw := _value_at(args, i + 1)
				if not hz_raw.is_valid_int() or int(hz_raw) < 1:
					push_error("--physics-hz 需要接一个正整数帧率，例如 --physics-hz 120，收到：%s" % hz_raw)
				else:
					opts["physics_hz"] = int(hz_raw)
					i += 1
		i += 1
	return opts


static func _value_at(args: PackedStringArray, index: int) -> String:
	return args[index] if index < args.size() else ""
