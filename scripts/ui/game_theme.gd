class_name GameTheme
extends RefCounted
## 界面主题。在代码里构建，不存成 .tres。
##
## 理由与项目对 project.godot 的态度一致（AGENTS.md）：.tres 由编辑器保存时整份重写，
## 注释必丢；而主题里几乎每个取值都需要一句说明——为什么这个内边距、为什么这个色阶。
## 写在代码里它们能留住，写在 .tres 里第二天就没了。
## 代价是编辑器里看不到预览，只有运行时才生效；对一个还没有美术资源的原型来说这个代价可以接受。
##
## ## 形状：切角石板
##
## 版面上的控件都是**切角**的（PlateStyle），不是圆角。圆角读起来太软，
## 而熔岩与冰霜都是晶体，斜切才配得上关卡里那些棱角分明的方块。
## 形状也因此成了这套界面的识别特征：换掉颜色它还是它，换掉切角就不是了。
##
## ## 颜色：暖属熔、冷属霜，不是装饰
##
## 界面上的"橙 = 熔、蓝 = 霜"必须能直接接到关卡里。玩家在大厅里学到的色彩语言，
## 进入关卡后要毫无断层。所以强调色分两族，而且**用在哪一边是有规矩的**：
##
##   熔（暖）—— 主动作：创建、开始、加入。这些是"把局面推进下去"的动作
##   霜（冷）—— 选中、聚焦、可交互的边界。这些是"现在轮到哪"的提示
##
## 两类不混用，因此看一眼颜色就知道那个东西是"要按的"还是"已经在的"。

const BG_DEEP := Color(0.043, 0.051, 0.071)
const PANEL_BG := Color(0.075, 0.086, 0.114, 0.92)
const PANEL_BORDER := Color(0.18, 0.21, 0.28)
const FIELD_BG := Color(0.035, 0.043, 0.059)
const ACCENT := Color(0.96, 0.52, 0.16)
const ACCENT_COOL := Color(0.36, 0.78, 0.98)
const TEXT := Color(0.90, 0.93, 0.97)
const TEXT_DIM := Color(0.58, 0.64, 0.74)
const DISABLED := Color(0.24, 0.27, 0.33)

## 切角边长。分成三档而不是一个值，因为同样的像素数在大面板上几乎看不出来，
## 在小按钮上却会把按钮削成菱形。
const CUT_PANEL := 14.0
const CUT_BUTTON := 7.0
const CUT_FIELD := 5.0

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


## 面板：一块切角石板。半透明是必须的：菜单与大厅背后就是一张真正的关卡，
## 让人隐约看见后面的地形与岩浆，比铺一块纯色更像"游戏里的菜单"，而不是调试窗口。
static func _build_panels(theme: Theme) -> void:
	var panel := PlateStyle.plate(PANEL_BG, CUT_PANEL, Color(1.0, 1.0, 1.0, 0.06))
	panel.edge = PANEL_BORDER
	panel.with_padding(0.0, 0.0)
	theme.set_stylebox("panel", "PanelContainer", panel)

	var tip := PlateStyle.plate(Color(0.05, 0.06, 0.08, 0.94), 10.0, Color(1.0, 1.0, 1.0, 0.06))
	tip.edge = PANEL_BORDER
	tip.with_padding(14.0, 12.0)
	theme.set_stylebox("panel", "TooltipPanel", tip)


## 按钮只有"次按钮"这一套外观（深底 + 切角描边），主按钮由 apply_primary() 单独贴。
## 不走 Theme 的 type variation，是因为那条路要求"类型本身先注册过"，
## 而注册 API 在不同 Godot 小版本上并不一致；只有一两个按钮需要这种外观，直接贴更省事，
## 也不会因为引擎升级而静默失效（静默失效的表现是"主按钮悄悄变成了次按钮"，不报任何错）。
static func _build_buttons(theme: Theme) -> void:
	theme.set_stylebox("normal", "Button", _side_button(Color(0.13, 0.15, 0.20), Color(1.0, 1.0, 1.0, 0.07)))
	# 悬停时描边转冷。冷色在这套语言里表示"现在轮到哪"，
	# 恰好就是鼠标指到的东西；而按钮本身要做的事仍然由它是否为暖色实心决定。
	theme.set_stylebox("hover", "Button", _side_button(Color(0.17, 0.20, 0.26), Color(0.36, 0.78, 0.98, 0.34)))
	# 按下时更暗：视觉上"按进去"了。次按钮不加发光，那是主按钮的专属信号。
	theme.set_stylebox("pressed", "Button", _side_button(Color(0.10, 0.12, 0.16), Color(0.36, 0.78, 0.98, 0.22)))
	# 键盘焦点：一圈完整的冷色边，与 hover 区分开——用键盘选和用鼠标指是两种状态，
	# 画成一样会让人以为鼠标没松开。
	var focus := _side_button(Color(0.13, 0.15, 0.20), ACCENT_COOL)
	focus.edge = ACCENT_COOL
	focus.edge_width = 2.0
	theme.set_stylebox("focus", "Button", focus)
	var disabled := _side_button(Color(0.09, 0.10, 0.13), Color(1.0, 1.0, 1.0, 0.03))
	disabled.edge = Color(0.13, 0.15, 0.19)
	theme.set_stylebox("disabled", "Button", disabled)
	# 鼠标悬停时按下的那一档。不设的话它会落回引擎默认主题——
	# 而默认主题是浅色的，在深色界面上表现为"按下去的一瞬间闪一下白"。
	theme.set_stylebox("hover_pressed", "Button", _side_button(Color(0.15, 0.17, 0.22), ACCENT_COOL))
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", ACCENT_COOL)
	theme.set_color("font_focus_color", "Button", Color.WHITE)
	theme.set_color("font_disabled_color", "Button", Color(0.40, 0.44, 0.50))
	theme.set_font_size("font_size", "Button", FONT_BUTTON)


static func _side_button(fill: Color, lit: Color) -> PlateStyle:
	var style := PlateStyle.plate(fill, CUT_BUTTON, lit)
	style.edge = PANEL_BORDER.lightened(0.10)
	style.with_padding(18.0, 9.0)
	return style


## 把某个按钮改成主按钮（熔岩色实心 + 外发光）。贴的是节点级覆盖，优先于主题。
## 发光是它唯一的专属特征，因此**只给主动作用**：界面上同时出现三个发光按钮，
## 就等于没有重点。
static func apply_primary(button: Button) -> void:
	var base := PlateStyle.glowing(ACCENT, CUT_BUTTON, ACCENT)
	base.with_padding(26.0, 12.0)
	button.add_theme_stylebox_override("normal", base)
	button.add_theme_stylebox_override("hover", base.recolored(ACCENT.lightened(0.14)))
	button.add_theme_stylebox_override("pressed", base.recolored(ACCENT.darkened(0.18)))
	button.add_theme_stylebox_override("focus", base.recolored(ACCENT.lightened(0.14)))
	# 不可用时把发光一并去掉：一个"变灰但还在发光"的按钮会让人以为它能点。
	var off := PlateStyle.plate(DISABLED, CUT_BUTTON, Color(1.0, 1.0, 1.0, 0.05))
	off.with_padding(26.0, 12.0)
	button.add_theme_stylebox_override("disabled", off)
	# 字色用近黑：压在亮橙实心上，浅色字会糊掉。
	var ink := Color(0.13, 0.09, 0.04)
	button.add_theme_color_override("font_color", ink)
	button.add_theme_color_override("font_hover_color", ink)
	button.add_theme_color_override("font_pressed_color", ink)
	button.add_theme_color_override("font_focus_color", ink)
	button.add_theme_color_override("font_disabled_color", Color(0.42, 0.45, 0.52))


## 输入框：比面板更深，做出"凹进去"的感觉——界面上唯一需要人打字的地方，
## 视觉上要能与只读的控件分开。切角比按钮更小：它是个小控件，切多了像标签。
static func _build_fields(theme: Theme) -> void:
	var field := PlateStyle.plate(FIELD_BG, CUT_FIELD, Color(1.0, 1.0, 1.0, 0.05))
	field.edge = PANEL_BORDER
	field.with_padding(14.0, 8.0)
	theme.set_stylebox("normal", "LineEdit", field)
	var focus := PlateStyle.plate(FIELD_BG, CUT_FIELD, ACCENT_COOL)
	focus.edge = ACCENT_COOL
	focus.with_padding(14.0, 8.0)
	theme.set_stylebox("focus", "LineEdit", focus)
	# 只读状态的输入框。不显式给一个的话，落回默认主题时它会在获得焦点时变成白底。
	theme.set_stylebox("read_only", "LineEdit", field)
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", Color(0.42, 0.47, 0.56))
	theme.set_color("caret_color", "LineEdit", ACCENT_COOL)
	theme.set_color("selection_color", "LineEdit", Color(0.36, 0.78, 0.98, 0.35))
	theme.set_font_size("font_size", "LineEdit", FONT_BODY)


static func _build_lists(theme: Theme) -> void:
	# 列表底比输入框略透：它经常是一大片空的（没探测到房间时），
	# 完全不透明的一块黑在那时会看着像一个洞。
	var bg := PlateStyle.plate(Color(FIELD_BG.r, FIELD_BG.g, FIELD_BG.b, 0.62), 10.0, Color(1.0, 1.0, 1.0, 0.04))
	bg.edge = PANEL_BORDER
	bg.with_padding(6.0, 6.0)
	theme.set_stylebox("panel", "ItemList", bg)
	# 选中项用冷色：冷色在这套界面里表示"现在轮到哪"，与"要按的按钮"的暖色分开。
	# 不做整行高亮而只提亮一档，是为了让列表看起来还是一片连续的、可比较的房间，
	# 而不是一列各自独立的按钮。
	var selected := PlateStyle.plate(Color(0.14, 0.28, 0.38, 0.95), 7.0, ACCENT_COOL)
	selected.edge = Color(0.20, 0.42, 0.56)
	selected.with_padding(10.0, 4.0)
	theme.set_stylebox("selected", "ItemList", selected)
	theme.set_stylebox("selected_focus", "ItemList", selected.recolored(Color(0.18, 0.36, 0.48, 0.95)))
	theme.set_color("font_color", "ItemList", TEXT)
	theme.set_color("font_selected_color", "ItemList", Color.WHITE)
	theme.set_font_size("font_size", "ItemList", FONT_BODY)
	# 列表项之间的空隙。默认挤在一起，读起来像一行行日志。
	theme.set_constant("v_separation", "ItemList", 8)
	# **这几个必须显式给空值。** Theme.new() 建出来的主题里没有的项会落回**引擎默认主题**，
	# 而默认主题是为浅色界面做的：它给 ItemList 自带一个浅灰的 hovered / cursor 方块，
	# 在深色列表里表现为"某一行莫名其妙地亮着一块"（那正是当前鼠标所在的那一行）。
	# 这类问题的麻烦之处在于它不是报错，只是看起来脏，很容易被当成"设计就是那样"。
	theme.set_stylebox("cursor", "ItemList", StyleBoxEmpty.new())
	theme.set_stylebox("cursor_unfocused", "ItemList", StyleBoxEmpty.new())
	theme.set_stylebox("hovered", "ItemList", _hover_row())
	theme.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())


static func _build_misc(theme: Theme) -> void:
	# 分隔线用暖色而不是灰：它是"两件事之间的界"，而界在这套语言里由暖色承担。
	# alpha 压得很低，因此它只是"一条隐约的线"，不会变成第二根描边。
	var line := StyleBoxLine.new()
	line.color = Color(0.96, 0.52, 0.16, 0.22)
	line.thickness = 2
	theme.set_stylebox("separator", "HSeparator", line)
	theme.set_constant("separation", "VBoxContainer", 10)
	theme.set_constant("separation", "HBoxContainer", 10)
	theme.set_font_size("font_size", "Label", FONT_LABEL)


## 鼠标所在那一行。比选中项淡得多：两者同时出现时（鼠标停在一行上、而选中的是另一行），
## 必须一眼分得出哪个是"要按的那一个"。
static func _hover_row() -> PlateStyle:
	var style := PlateStyle.plate(Color(0.16, 0.19, 0.25, 0.55), 7.0, Color(1.0, 1.0, 1.0, 0.05))
	style.edge = Color(0.0, 0.0, 0.0, 0.0)
	style.with_padding(10.0, 4.0)
	return style
