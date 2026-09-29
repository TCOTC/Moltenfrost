class_name Fx
extends Node2D
## 纯表现层的短命特效：技能预告圈、技能生效、死亡与落水的波纹。
##
## 它不进任何判定，也不参与同步——两端各自按同一份参数画同一件事，
## 因此不需要为它增加网络包。参数（半径、时长）都来自 Game 的常量，
## 而 RPC 只负责说"谁在什么时候在哪个点放了技能"，剩下的是纯函数。
##
## 三个模式对应三种"要让人读出什么"：
##   CHARGE —— 从范围外缘向内收拢的环，让人读出"还有多久生效"（延迟生效是核心机制）
##   BURST  —— 由内向外炸开的环，让人读出"刚刚生效了"
##   RIPPLE —— 单圈扩散，用于死亡这类只需提示"某处发生了事"的场合
##
## 无头运行时直接不生成：服务端没有人看，生成了只是白跑 _process。

enum Mode { CHARGE, BURST, RIPPLE }

var mode: int = Mode.BURST
var color: Color = Color.WHITE
var radius: float = 64.0
var duration: float = 0.4

var _age: float = 0.0


## 建一个特效节点。**不加进树**，由调用方 add_child：
## 加进树是调用方的事（它知道该挂在哪个节点下），这里只负责构造。
static func create(p_mode: int, at: Vector2, p_color: Color, p_radius: float, p_duration: float) -> Fx:
	var fx := Fx.new()
	fx.mode = p_mode
	fx.position = at
	fx.color = p_color
	fx.radius = p_radius
	fx.duration = p_duration
	fx.z_index = 5
	return fx


## 技能预告。半径取技能的作用半径，因此它同时是"这个技能能打到多远"的说明书。
static func telegraph(parent: Node, at: Vector2, kind: int, p_radius: float, p_duration: float) -> void:
	if parent == null or DisplayServer.get_name() == "headless":
		return
	parent.add_child(create(Mode.CHARGE, at, Element.kind_color(kind), p_radius, p_duration))


## 技能生效。
static func burst(parent: Node, at: Vector2, kind: int, p_radius: float) -> void:
	if parent == null or DisplayServer.get_name() == "headless":
		return
	parent.add_child(create(Mode.BURST, at, Element.kind_color(kind), p_radius, 0.35))


## 一次性波纹，用于死亡与落水。
static func ripple(parent: Node, at: Vector2, p_color: Color, p_radius: float) -> void:
	if parent == null or DisplayServer.get_name() == "headless":
		return
	parent.add_child(create(Mode.RIPPLE, at, p_color, p_radius, 0.5))


func _process(delta: float) -> void:
	_age += delta
	if _age >= duration:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var t := clampf(_age / maxf(duration, 0.001), 0.0, 1.0)
	match mode:
		Mode.CHARGE:
			var edge := Color(color.r, color.g, color.b, 0.35)
			draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, edge, 3.0)
			var fill := radius * t
			draw_circle(Vector2.ZERO, fill, Color(color.r, color.g, color.b, 0.10))
			draw_arc(Vector2.ZERO, fill, 0.0, TAU, 64, Color(color.r, color.g, color.b, 0.9), 3.0)
		Mode.BURST:
			var r := radius * (0.45 + 0.55 * t)
			draw_circle(Vector2.ZERO, r, Color(color.r, color.g, color.b, 0.26 * (1.0 - t)))
			draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, Color(color.r, color.g, color.b, 1.0 - t), 4.0)
		Mode.RIPPLE:
			var r := radius * t
			draw_arc(Vector2.ZERO, r, 0.0, TAU, 64, Color(color.r, color.g, color.b, 0.85 * (1.0 - t)), 3.0)
