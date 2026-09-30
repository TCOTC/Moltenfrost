class_name GameHud
extends CanvasLayer
## 对局中的抬头显示：关卡名、积分、双方元素、按键提示、短暂提示与结算遮罩。
##
## **由 Game 单向推数据进来**，HUD 自己不反查 Game。
## 这样分开的原因是 HUD 要显示的东西（谁死了、谁是什么元素、多少分）全都是
## Game 的权威状态；反过来让 HUD 每帧去翻玩家节点，等于把"谁能改状态"这件事
## 变成两边都可以，日后加一个显示项就会加一处耦合。
## 所有 set_* 都在值没变时直接返回，因此 Game 可以每帧无脑推。
##
## 会话层的提示（"已连接到主机""按 Esc 返回初始界面"）不在这里，它们由入口脚本
## 写在 Root/Status 上——那是连接状态，与对局规则无关。

## 元素未知（例如单人游玩时没有队友）。
const NONE := -1

var _you_kind: int = NONE
var _mate_kind: int = NONE
var _you_alive: bool = true
var _mate_alive: bool = true
var _score_value: int = -1
var _level_text: String = ""

var _toast_left: float = 0.0

@onready var _level_name: Label = $Root/LevelName
@onready var _score: Label = $Root/Score
@onready var _you: Label = $Root/Elements/You
@onready var _mate: Label = $Root/Elements/Mate
@onready var _hint: Label = $Root/Hint
@onready var _toast: Label = $Root/Toast
@onready var _overlay: Control = $Root/Overlay
@onready var _overlay_title: Label = $Root/Overlay/Title
@onready var _overlay_body: Label = $Root/Overlay/Body


func _ready() -> void:
	$Root.theme = GameTheme.build()
	_toast.text = ""
	_toast.modulate.a = 0.0
	_overlay.visible = false
	# 常驻的按键提示。写在这里而不是场景里，是因为它随输入映射变化——
	# 输入重绑定做完之后这一行必须跟着改，放在一起才不会漏。
	_hint.text = "A / D 移动   空格 跳跃   E 技能   Q 交换角色   R 本关重来   Esc 回到等待房间"
	_level_name.text = ""
	_score.text = ""


func _process(delta: float) -> void:
	if _toast_left <= 0.0:
		return
	_toast_left = maxf(_toast_left - delta, 0.0)
	# 最后 0.5 秒淡出。用 modulate 而不是清空 text：清空会让文字突然消失，
	# 而短暂提示本来就是"看一眼就够"的东西，淡出更符合那个节奏。
	_toast.modulate.a = minf(1.0, _toast_left / 0.5)


# ---------------------------------------------------------------- 由 Game 推入

func set_level_name(text: String) -> void:
	if _level_text == text:
		return
	_level_text = text
	_level_name.text = text


func set_score(value: int) -> void:
	if _score_value == value:
		return
	_score_value = value
	_score.text = "积分 %d" % value


func set_elements(you: int, mate: int) -> void:
	if _you_kind == you and _mate_kind == mate:
		return
	_you_kind = you
	_mate_kind = mate
	_refresh_players()


func set_you_alive(alive: bool) -> void:
	if _you_alive == alive:
		return
	_you_alive = alive
	_refresh_players()


func set_mate_alive(alive: bool) -> void:
	if _mate_alive == alive:
		return
	_mate_alive = alive
	_refresh_players()


## 短暂提示（死亡、得分、造冰失败……）。重复调用会把上一条顶掉，
## 因此连按技能不会在屏幕上堆一摞字。
func toast(text: String, seconds: float = 1.6) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	_toast_left = maxf(seconds, 0.1)


func show_overlay(title: String, body: String) -> void:
	_overlay_title.text = title
	_overlay_body.text = body
	_overlay.visible = true


func hide_overlay() -> void:
	_overlay.visible = false


# ---------------------------------------------------------------- 内部

func _refresh_players() -> void:
	_set_chip(_you, "你 · ", _you_kind, _you_alive)
	# 单人游玩时场上有第二个角色这件事不成立，因此队友那一格直接隐藏，
	# 而不是显示成"队友 · ?"——那会让人去找一个不存在的队友。
	_mate.visible = _mate_kind != NONE
	_set_chip(_mate, "队友 · ", _mate_kind, _mate_alive)


func _set_chip(label: Label, prefix: String, kind: int, alive: bool) -> void:
	if kind == NONE:
		label.text = ""
		return
	var suffix := "" if alive else "（阵亡）"
	label.text = "%s%s%s" % [prefix, Element.kind_name(kind), suffix]
	var color := Element.kind_color(kind)
	label.add_theme_color_override("font_color", color if alive else color.darkened(0.55))
