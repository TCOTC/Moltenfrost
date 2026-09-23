class_name ElementGate
extends StaticBody3D
## 机关门：受一组按钮控制。两种语义由 latched 选择，对应不同的关卡结构。
##
## 为什么锁存是默认值：两个按钮分处两条被隔墙分开的通道，而**两人都在按钮上时
## 没有人能去门口**——门若随松手关闭，这个机关就永远无法通过。所以默认只在
## 「每个按钮都曾被踩过」的那一刻开启一次，此后保持。
##
## 非锁存模式（latched = false）留给「一人按住、另一人先过」这类结构：
## 那时门必须随松手关闭，否则按住的那一方就没有存在的意义。
##
## 判定在服务端（理由见 element_button.gd），门的状态用可靠传输广播：
## 门的开合是有语义的事件，丢一次就会让某个玩家看到的门与其他端不一致，而它决定能否通过。
##
## 门开启时沉降到地面以下，同时关闭碰撞。**必须关碰撞**：本节点是 StaticBody3D，
## 若只把网格移走而碰撞留在原地，玩家会被看不见的东西挡住。

## 与本门联动的按钮。路径相对本节点。
@export var buttons: Array[NodePath] = []
## 门开启时的本地偏移量。默认沿 Y 轴下沉到地面以下。
@export var open_offset: Vector3 = Vector3(0.0, -3.6, 0.0)
## 锁存：true = 每个按钮都曾被踩过即开启并保持；false = 只在全部按钮当前被踩住时开启。
@export var latched: bool = true

@onready var _collision: CollisionShape3D = $Collision

var is_open: bool = false
## 关闭状态下的位置，由它加偏移得到开启位置。
var _closed_position: Vector3
## 锁存模式下记录的「曾被踩过」。键是按钮路径的字符串形式——
## 用路径而不是节点引用做键，是因为这门本来就用路径定位按钮，两者口径一致。
var _ever_pressed: Dictionary = {}


func _ready() -> void:
	_closed_position = position
	# 这里直接应用状态而不调 rpc：本节点先于 main.gd 的 _ready 就绪，
	# 此刻 multiplayer peer 还没有建立，rpc 会失败并留下引擎错误。
	_apply_local(false)
	if buttons.is_empty():
		push_error("机关门 %s 没有指定按钮，它永远不会开启。" % name)


func _physics_process(_delta: float) -> void:
	# 理由同 element_button.gd：不能在 _ready 里用 Net.is_server() 一次性决定。
	if not Net.is_server():
		return
	if latched:
		# 锁存模式只关心「开启」，不需要在开启后继续检查。
		if not is_open and _all_ever_pressed():
			_apply_state.rpc(true)
		return
	var open := _all_pressed()
	if open != is_open:
		_apply_state.rpc(open)


@rpc("authority", "call_local", "reliable")
func _apply_state(open: bool) -> void:
	_apply_local(open)


func _apply_local(open: bool) -> void:
	is_open = open
	position = _closed_position + (open_offset if open else Vector3.ZERO)
	_collision.disabled = open
	print("[gate] 门%s" % ("已打开" if open else "已关闭"))


func _all_pressed() -> bool:
	for path in buttons:
		var node := get_node_or_null(path) as ElementButton
		if node == null:
			# 场景里连错节点比"门不响应"更难查，所以直接报出来。
			push_error("机关门 %s 的按钮路径无效：%s" % [name, path])
			return false
		if not node.is_pressed:
			return false
	return not buttons.is_empty()


## 锁存模式的判据：每个按钮**曾经**被踩过。
## 历史在这里顺手更新，因此不需要按钮另外发信号：每次检查读到 is_pressed 为真就记下，
## 而检查频率是物理帧，远高于人踩下按钮的时长，不会漏。
func _all_ever_pressed() -> bool:
	for path in buttons:
		var key := String(path)
		var node := get_node_or_null(path) as ElementButton
		if node == null:
			push_error("机关门 %s 的按钮路径无效：%s" % [name, path])
			return false
		if node.is_pressed:
			_ever_pressed[key] = true
		if not bool(_ever_pressed.get(key, false)):
			return false
	return not buttons.is_empty()
