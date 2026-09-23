class_name Facility
extends RefCounted
## 科幻设施的构件库：板、灯带、柱、栏杆、地面网格。
##
## 关卡的几何全部由代码生成，而不是画在 .tscn 里，理由有两条：
##   一是这些构件反复出现（一面墙出现十几次），写进场景文件时每个都要三份节点
##   （StaticBody3D + MeshInstance3D + CollisionShape3D），改一次尺寸要改十几处；
##   二是美术参数还在调整期，参数化生成可以直接按「第几段」循环出来，改一个常量就全部生效。
##
## 造型语言（与角色保持一致）：大块的哑光金属 + 细的发光缝。
## 发光只出现在缝隙、灯带与边缘，因此暗部的面积远大于亮部——这是设施感的主要来源，
## 也是 glow 后处理不会把画面洗白的前提。

## 灯带的默认发光强度。超过 4 之后 glow 已经饱和，看不出区别。
const LAMP_ENERGY := 2.4
## 地面网格线的宽度与发光强度。线要细、要暗，它是尺度参照而不是装饰：
## 早先给 1.1 的能量时，线在 glow 后接近纯白，地面看起来像一张发光纸。
const GRID_LINE_WIDTH := 0.035
const GRID_ENERGY := 0.5


# ---------------------------------------------------------------- 结构件

## 有碰撞的长方体：地板、墙、天花板、台阶都用它。返回 StaticBody3D。
static func slab(root: Node3D, node_name: String, center: Vector3, size: Vector3,
		material: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = center
	root.add_child(body)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = _box(size)
	mesh.material_override = material
	body.add_child(mesh)

	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	return body


## 无碰撞的长方体：装饰、灯带、面板边条。
## 单独一个函数而不是在 slab 上加参数，是为了让「这东西会不会挡住玩家」在调用处一眼可辨。
static func visual(root: Node3D, node_name: String, center: Vector3, size: Vector3,
		material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.position = center
	node.mesh = _box(size)
	node.material_override = material
	root.add_child(node)
	return node


## 灯带：贴面的发光薄板。size 里厚度取 0.02～0.05 即可，再厚就会看出发光体本身而不是光。
static func lamp(root: Node3D, node_name: String, center: Vector3, size: Vector3,
		color: Color, energy: float = LAMP_ENERGY) -> MeshInstance3D:
	return visual(root, node_name, center, size, Palette.glow(color, energy))


## 立柱。圆截面在方盒构成的空间里能提供对比，也方便玩家绕柱走位。
static func column(root: Node3D, node_name: String, base: Vector3, radius: float,
		height: float, material: Material) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	# base 是柱底中心，圆柱的网格以中心为原点，因此整体抬高一半。
	body.position = base + Vector3.UP * height * 0.5
	root.add_child(body)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 20
	cyl.rings = 1
	mesh.mesh = cyl
	mesh.material_override = material
	body.add_child(mesh)

	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	collision.shape = shape
	body.add_child(collision)
	return body


## 栏杆：沿一条水平线布置的立柱加一根横杆。用于平台边缘，同时提示「这里会掉下去」。
static func rail(root: Node3D, node_name: String, from: Vector3, to: Vector3,
		height: float, material: Material) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	root.add_child(node)

	var span := to - from
	var length := span.length()
	if length < 0.01:
		return node
	var dir := span / length
	# 立柱按固定间距排，数量按长度算，避免间距随长度变化而不统一。
	var count := maxi(2, int(round(length / 1.6)) + 1)
	for i in count:
		var t := float(i) / float(count - 1)
		var post := Vector3(from.lerp(to, t).x, from.y + height * 0.5, from.lerp(to, t).z)
		visual(node, "Post%d" % i, post, Vector3(0.06, height, 0.06), material)
	# 横杆：水平方向长度取 length，另两个方向是截面。
	var mid := (from + to) * 0.5 + Vector3.UP * height
	var bar_size := Vector3(absf(dir.x) * length + 0.07, 0.06, absf(dir.z) * length + 0.07)
	visual(node, "Bar", mid, bar_size, material)
	return node


## 地面网格线：沿 X 与 Z 两个方向铺细线。它给玩家一个尺度参照，
## 在空房间里这比任何贴图都更能让人判断自己移动了多远。无碰撞。
static func grid_lines(root: Node3D, node_name: String, y: float,
		x_min: float, x_max: float, z_min: float, z_max: float,
		step: float, color: Color) -> Node3D:
	var node := Node3D.new()
	node.name = node_name
	root.add_child(node)
	var material := Palette.glow(color, GRID_ENERGY)

	var z := z_min
	while z <= z_max + 0.001:
		visual(node, "LX%0.1f" % z, Vector3((x_min + x_max) * 0.5, y, z),
			Vector3(x_max - x_min, 0.012, GRID_LINE_WIDTH), material)
		z += step
	var x := x_min
	while x <= x_max + 0.001:
		visual(node, "LZ%0.1f" % x, Vector3(x, y, (z_min + z_max) * 0.5),
			Vector3(GRID_LINE_WIDTH, 0.012, z_max - z_min), material)
		x += step
	return node


# ---------------------------------------------------------------- 内部

static func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	# 显式关掉细分：默认值会让每个面多出顶点，而这些面没有光照细节需要顶点承载。
	mesh.subdivide_width = 0
	mesh.subdivide_height = 0
	mesh.subdivide_depth = 0
	return mesh
