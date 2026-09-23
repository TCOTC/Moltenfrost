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
## 第二遍（自定义参数）打开未知参数告警：引擎自己的参数有几十个，我们不熟悉、也不能假设拿全了，
## 而 `--` 之后的参数全部是本工程自己的，认不出来就意味着写错或新参数忘了在这里登记。
static func from_process() -> Dictionary:
	var opts := parse(OS.get_cmdline_args())
	opts.merge(parse(OS.get_cmdline_user_args(), true), true)
	return opts


## 解析一个参数数组。取值缺失或格式不对时报告错误，并跳过该参数。
## warn_unknown 为真时，对以 `-` 开头但不在下面的分派表里的参数给出警告。
## 为什么要这个开关：这里与引擎有一个共同的坑——认不出来的参数被静默忽略。
## 一旦忘了登记新参数，程序会「正常」启动但行为与预期不同，
## 而启动日志里看不出任何异常（实测：`--capture` 漏登记导致截图工具永远不启动）。
static func parse(args: PackedStringArray, warn_unknown: bool = false) -> Dictionary:
	var opts := {}
	var i := 0
	while i < args.size():
		var arg := args[i]
		match arg:
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
			"--capture":
				# 开发期截图（见 scripts/dev/capture_rig.gd）。
				opts["capture"] = true
			"--capture-focus":
				# 截图取景目标：world（预设机位）或 remote（对准另一个玩家的角色）。
				# 后者必须跑在有对端角色的会话里，否则等不到取景对象（见 capture_rig.gd）。
				var focus_raw := _value_at(args, i + 1)
				if focus_raw != "world" and focus_raw != "remote":
					push_error("--capture-focus 只接受 world 或 remote，收到：%s" % focus_raw)
				else:
					opts["capture_focus"] = focus_raw
					i += 1
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
			_:
				if warn_unknown and arg.begins_with("-"):
					push_warning("无法识别的参数「%s」被忽略；若这是新加的参数，记得登记到 net_cmdline.gd 的分派表里。" % arg)
		i += 1
	return opts


static func _value_at(args: PackedStringArray, index: int) -> String:
	return args[index] if index < args.size() else ""
