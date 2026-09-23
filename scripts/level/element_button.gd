class_name ElementButton
extends Area3D
## 元素按钮：只有对应元素的角色站在上面，它才处于按下状态。
##
## **判定放在服务端**，这是本工程第一处替别人做判定的地方（设计文档 4.5：
## 机关判定服务端权威）。依据是服务端持有所有人的位置——它们经同步到达——
## 而客户端只接收按钮状态用于显示，不做预测。代价是客户端踩下按钮到画面反馈
## 晚一个往返，原型期接受：换来的是各端看到同一个事实，将来推箱与旋转平台也要走这条路。
##
## 与 HazardZone 相反的那一半理由见 hazard_zone.gd：位置的事实属于角色自己的机器，
## 所以地形致死由本机判定；而"两个人是否同时到位"这个事实只有服务端看得到。

## 按钮状态变化时发出。服务端与客户端都会收到（服务端发出后本地也应用一次）。
signal pressed_changed(pressed: bool)

@export var element: Element.Kind = Element.Kind.MOLTEN
## 按下时按钮下沉的距离（米），用来让人看出它被踩住了。
const PRESS_DEPTH := 0.09
## 按下与未按下的自发光强度。两个值都取在「亮而不刺眼」的范围内：
## 按钮是解谜的反馈装置，它必须比周围环境显眼，但不应该抢过能量场。
const PRESS_ENERGY := 1.6
const IDLE_ENERGY := 0.5

@onready var _mesh: MeshInstance3D = $Mesh

var is_pressed: bool = false
## 按钮板的静止位置，由按下状态加一个偏移得到。
var _rest_position: Vector3


func _ready() -> void:
	_rest_position = _mesh.position
	_apply_color()
	_update_visual()


func _physics_process(_delta: float) -> void:
	# 这里不用 set_physics_process 在 _ready 里一次决定：本节点先于 main.gd 的 _ready 就绪，
	# 那时会话尚未开始，Net.is_server() 在客户端上也会返回 true（离线同样被当作服务端）。
	if not Net.is_server():
		return
	var pressed := _is_held()
	if pressed == is_pressed:
		return
	_apply_pressed.rpc(pressed)


## 由服务端广播的状态。可靠传输：一次丢失就会让某一端看见的按钮与其他端不一致，
## 而它决定门开不开。
@rpc("authority", "call_local", "reliable")
func _apply_pressed(pressed: bool) -> void:
	is_pressed = pressed
	_update_visual()
	pressed_changed.emit(pressed)
	print("[button] %s 按钮%s" % [Element.label(element), "被踩下" if pressed else "已抬起"])


## 是否有本元素的一个角色正站在按钮范围内。
func _is_held() -> bool:
	for body in get_overlapping_bodies():
		if not (body is Player):
			continue
		if (body as Player).element == element:
			return true
	return false


func _apply_color() -> void:
	# duplicate() 是必需的：Palette 的材质按「用途 + 颜色 + 参数」缓存并共享，
	# 而按钮要在按下时改自己的自发光强度；直接改缓存会把同色的其它对象一并改亮
	#（另一个同色按钮、以及同色的池子边缘）。
	var tint := Element.color(element)
	_mesh.material_override = Palette.panel(Palette.TEX_FLOOR, tint, 0.5, tint, IDLE_ENERGY).duplicate()


func _update_visual() -> void:
	_mesh.position = _rest_position + (Vector3.DOWN * PRESS_DEPTH if is_pressed else Vector3.ZERO)
	var material := _mesh.material_override as StandardMaterial3D
	if material != null:
		material.emission_energy_multiplier = PRESS_ENERGY if is_pressed else IDLE_ENERGY
