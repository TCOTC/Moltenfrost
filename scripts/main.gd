extends Node3D
## 工程骨架的入口。
##
## 只做两件事：确认窗口模式符合当前生效的项目设置，并把实际分辨率打到控制台。
## 打印这一行是为了让"是否真的用满屏幕"可核对——无头跑一次就能看到，
## 不用靠肉眼盯着全屏画面猜。
##
## 关于开发期窗口化：project.godot 里写了 window/size/mode=3（全屏）与
## window/size/mode.editor=0（窗口）。后者是特性标签覆盖，只在用编辑器程序跑的时候
## 生效——编辑器的「游戏嵌入」需要窗口模式，而导出产物的二进制不带 editor 特性，
## 取到的仍是全屏。所以下面用 get_setting_with_override 取值，让实际窗口状态跟上它。
## 注意：project.godot 里的注释在编辑器保存工程时会被删掉，说明写在这里。

const MODE_SETTING := "display/window/size/mode"


func _ready() -> void:
	_ensure_window_mode()
	_report_display()


func _ensure_window_mode() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var wanted := int(ProjectSettings.get_setting_with_override(MODE_SETTING))
	if DisplayServer.window_get_mode() != wanted:
		DisplayServer.window_set_mode(wanted as DisplayServer.WindowMode)


func _report_display() -> void:
	var screen := DisplayServer.screen_get_size()
	var window := DisplayServer.window_get_size()
	var viewport := get_viewport().get_visible_rect().size
	print("[display] 后端=%s 生效模式=%s 导出后=%s 屏幕=%dx%d 窗口=%dx%d 视口=%dx%d" % [
		DisplayServer.get_name(),
		_mode_name(int(ProjectSettings.get_setting_with_override(MODE_SETTING))),
		_mode_name(int(ProjectSettings.get_setting(MODE_SETTING))),
		screen.x, screen.y,
		window.x, window.y,
		int(viewport.x), int(viewport.y),
	])


func _mode_name(mode: int) -> String:
	match mode:
		DisplayServer.WINDOW_MODE_WINDOWED:
			return "窗口"
		DisplayServer.WINDOW_MODE_MINIMIZED:
			return "最小化"
		DisplayServer.WINDOW_MODE_MAXIMIZED:
			return "最大化"
		DisplayServer.WINDOW_MODE_FULLSCREEN:
			return "全屏"
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			return "独占全屏"
	return str(mode)
