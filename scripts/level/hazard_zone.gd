class_name HazardZone
extends Area3D
## 元素地形：对元素不同的角色致命（火怕水、水怕岩浆）。
##
## **判定放在本机**，与玩家位置的权威归属一致：角色位置由它自己那台机器模拟
##（见 player.gd 文件头），所以"我是否站在池子里"这个问题由本机回答最直接，
## 复位也由本机执行，随后经位置同步传播给其余端。
## 机关（按钮与门）的判定反过来放在服务端，两处的依据是同一个：
## 谁持有事实，谁做判定——位置的事实属于角色自己的机器，而"所有人都到位了没有"属于服务端。
##
## 各端的 Area3D 都会对每个角色触发 body_entered，因为远端角色的位置在本地同样被更新。
## 因此处理前必须筛掉非本机角色，否则每一端都会去复位别人的角色。
##
## 命名注意：地形名跟着自己的元素走。「霜池」是冰水，对熔致命；「熔岩池」是岩浆，对霜致命。

## 本池的元素。与之相同元素的角色可以安全通行，不同元素的角色会被复位。
@export var element: Element.Kind = Element.Kind.MOLTEN
## 日志里用的名字，例如「熔岩池」。留空时按元素生成一个。
@export var display_name: String = ""

@onready var _mesh: MeshInstance3D = $Mesh


func _ready() -> void:
	_apply_color()
	body_entered.connect(_on_body_entered)


## 池子的颜色由元素决定，不写进关卡文件，这样元素与外观不会各自被改一次而失配。
## 材质走 Palette 的缓存：关卡那边只建几何、不碰材质，避免同一个池子的外观写两遍。
func _apply_color() -> void:
	_mesh.material_override = Palette.energy_field(Element.color(element))


func _on_body_entered(body: Node3D) -> void:
	if not (body is Player):
		return
	var player := body as Player
	# 远端角色的位置在这里也被更新，但只有它自己那台机器有权把它复位。
	if not player.is_local():
		return
	if player.element == element:
		# 同元素的地形是安全的，这也是本关唯一可以通行的路。
		return
	player.die(display_name if not display_name.is_empty() else "%s 地形" % Element.label(element))
