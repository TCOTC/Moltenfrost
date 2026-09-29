class_name GameTheme
extends RefCounted
## 界面主题。在代码里构建，不存成 .tres。
##
## 理由与项目对 project.godot 的态度一致（AGENTS.md）：.tres 由编辑器保存时整份重写，
## 注释必丢；而主题里几乎每个取值都需要一句说明——为什么这个内边距、为什么这个色阶。
## 写在代码里它们能留住，写在 .tres 里第二天就没了。
## 代价是编辑器里看不到预览，只有运行时才生效；对一个还没有美术资源的原型来说这个代价可以接受。
##
## 配色只有一件事要注意：**暖色属于熔、冷色属于霜**，界面上的强调色因此也分两族。
## 这不是装饰——玩家在界面里学到的"橙=火、蓝=冰"，进入关卡后要能直接接上。

const BG_DEEP := Color(0.043, 0.051, 0.071)
const PANEL_BG := Color(0.075, 0.086, 0.114, 0.92)
const PANEL_BORDER := Color(0.18, 0.21, 0.28)
const FIELD_BG := Color(0.035, 0.043, 0.059)
const ACCENT := Color(0.96, 0.52, 0.16)
const ACCENT_COOL := Color(0.36, 0.78, 0.98)
const TEXT := Color(0.90, 0.93, 0.97)
const TEXT_DIM := Color(0.58, 0.64, 0.74)
const DISABLED := Color(0.24, 0.27, 0.33)

const FONT_BODY := 18
const FONT_LABEL := 16
const FONT_BUTTON := 19


static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = FONT_BODY
	theme.set_color("font_color", "Label", TEXT)

	_build_panels(theme)
	_build_buttons(theme)
	_build_fields(theme)
	_build_lists(theme)
	_build_misc(theme)
	return theme


## 面板：一层半透明底 + 一圈描边。
## 半透明是必须的：初始界面之后就是一张真正的关卡，让人隐约看见后面的地形与岩浆，
## 比铺一块纯色更像"游戏里的菜单"，而不是调试窗口。
static func _build_panels(theme: Theme) -> void:
	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL_BG
	panel.border_color = PANEL_BORDER
	panel.set_border_width_all(2)
	panel.set_corner_radius_all(12)
	panel.set_content_margin_all(0.0)
	theme.set_stylebox("panel", "PanelContainer", panel)

	var tip := StyleBoxFlat.new()
	tip.bg_color = Color(0.05, 0.06, 0.08, 0.86)
	tip.border_color = PANEL_BORDER
	tip.set_border_width_all(2)
	tip.set_corner_radius_all(10)
	tip.set_content_margin_all(14.0)
	theme.set_stylebox("panel", "TooltipPanel", tip)


## 按钮只做一套"次按钮"外观（描边 + 深底）。主按钮（暖色实心）不在这里做，
## 而是由 GameTheme.apply_primary() 单独贴上去。
## 不走 Theme 的 type variation，是因为那条路要求"类型本身先注册过"，
## 而注册 API 在不同 Godot 小版本上并不一致；只有一两个按钮需要这种外观，
## 直接贴样式更省事，也不会因为引擎升级而静默失效（静默失效的表现是
## "主按钮悄悄变成了次按钮"，不报任何错）。
static func _build_buttons(theme: Theme) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.13, 0.15, 0.20)
	normal.border_color = PANEL_BORDER.lightened(0.18)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(8)
	normal.content_margin_left = 18.0
	normal.content_margin_right = 18.0
	normal.content_margin_top = 9.0
	normal.content_margin_bottom = 9.0
	theme.set_stylebox("normal", "Button", normal)
	var hover := normal.duplicate()
	hover.bg_color = Color(0.20, 0.23, 0.30)
	hover.border_color = ACCENT_COOL.darkened(0.25)
	theme.set_stylebox("hover", "Button", hover)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.10, 0.12, 0.16)
	theme.set_stylebox("pressed", "Button", pressed)
	var focus := normal.duplicate()
	focus.border_color = ACCENT_COOL
	theme.set_stylebox("focus", "Button", focus)
	var disabled := normal.duplicate()
	disabled.bg_color = Color(0.09, 0.10, 0.13)
	disabled.border_color = Color(0.14, 0.16, 0.20)
	theme.set_stylebox("disabled", "Button", disabled)
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", ACCENT_COOL)
	theme.set_color("font_disabled_color", "Button", Color(0.40, 0.44, 0.50))
	theme.set_font_size("font_size", "Button", FONT_BUTTON)


## 把某个按钮改成主按钮（暖色实心）。贴的是节点级覆盖，优先于主题。
static func apply_primary(button: Button) -> void:
	var base := StyleBoxFlat.new()
	base.bg_color = ACCENT
	base.set_corner_radius_all(8)
	base.content_margin_left = 26.0
	base.content_margin_right = 26.0
	base.content_margin_top = 12.0
	base.content_margin_bottom = 12.0
	var hover := base.duplicate()
	hover.bg_color = ACCENT.lightened(0.14)
	var pressed := base.duplicate()
	pressed.bg_color = ACCENT.darkened(0.18)
	var disabled := base.duplicate()
	disabled.bg_color = DISABLED
	button.add_theme_stylebox_override("normal", base)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", hover)
	button.add_theme_stylebox_override("disabled", disabled)
	var ink := Color(0.13, 0.09, 0.04)
	button.add_theme_color_override("font_color", ink)
	button.add_theme_color_override("font_hover_color", ink)
	button.add_theme_color_override("font_pressed_color", ink)
	button.add_theme_color_override("font_focus_color", ink)
	button.add_theme_color_override("font_disabled_color", Color(0.42, 0.45, 0.52))


## 输入框：比面板更深，做出"凹进去"的感觉——界面上唯一需要人打字的地方，
## 视觉上要能与只读的控件分开。
static func _build_fields(theme: Theme) -> void:
	var field := StyleBoxFlat.new()
	field.bg_color = FIELD_BG
	field.border_color = PANEL_BORDER
	field.set_border_width_all(2)
	field.set_corner_radius_all(6)
	field.content_margin_left = 14.0
	field.content_margin_right = 14.0
	field.content_margin_top = 8.0
	field.content_margin_bottom = 8.0
	theme.set_stylebox("normal", "LineEdit", field)
	var focus := field.duplicate()
	focus.border_color = ACCENT_COOL
	theme.set_stylebox("focus", "LineEdit", focus)
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", Color(0.42, 0.47, 0.56))
	theme.set_color("caret_color", "LineEdit", ACCENT_COOL)
	theme.set_color("selection_color", "LineEdit", Color(0.36, 0.78, 0.98, 0.35))
	theme.set_font_size("font_size", "LineEdit", FONT_BODY)


static func _build_lists(theme: Theme) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = FIELD_BG
	bg.border_color = PANEL_BORDER
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(8)
	bg.set_content_margin_all(6.0)
	theme.set_stylebox("panel", "ItemList", bg)
	var selected := StyleBoxFlat.new()
	selected.bg_color = Color(0.16, 0.30, 0.40)
	selected.set_corner_radius_all(6)
	theme.set_stylebox("selected", "ItemList", selected)
	var selected_focus := selected.duplicate()
	selected_focus.bg_color = Color(0.20, 0.38, 0.50)
	theme.set_stylebox("selected_focus", "ItemList", selected_focus)
	theme.set_color("font_color", "ItemList", TEXT)
	theme.set_color("font_selected_color", "ItemList", Color.WHITE)
	theme.set_font_size("font_size", "ItemList", FONT_BODY)
	# 列表项之间的空隙。默认挤在一起，读起来像一行行日志。
	theme.set_constant("v_separation", "ItemList", 6)


static func _build_misc(theme: Theme) -> void:
	var line := StyleBoxLine.new()
	line.color = PANEL_BORDER
	line.thickness = 1
	theme.set_stylebox("separator", "HSeparator", line)
	theme.set_constant("separation", "VBoxContainer", 10)
	theme.set_constant("separation", "HBoxContainer", 10)
	theme.set_font_size("font_size", "Label", FONT_LABEL)
