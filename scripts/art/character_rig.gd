class_name CharacterRig
extends RefCounted
## 角色造型：第三人称的整套身体，以及第一人称的双手。
##
## 两套造型分开构建，因为它们服务的目的不同：
##   第三人称那套是**给别人看的**。第一人称下看不到自己的身体，而你看到的是别人的身体，
##   所以它要保证剪影清楚（帽檐、肩甲、背部的能量核心都是为了让轮廓在暗场景里可辨）。
##   第一人称那套是**给自己看的**。它只包含前臂、双手与武器，且必须时刻占据画面右下角，
##   否则「手里拿着东西」这件事就不成立。
##
## 造型方向（科幻）：分块装甲加重型护肩，块与块之间留出缝隙并由内部发光填充——
## 发光只出现在缝隙、面罩与能量核心三处，因此暗色装甲的轮廓由光自己描出来，
## 不需要额外的描边后处理。
##
## 几何全部是 BoxMesh / CylinderMesh / SphereMesh 的组合。用程序化几何而不是模型文件，
## 是因为现阶段美术方案还在变，改一个参数比重新导出模型快；代价是造型细节有限。

# ---------------------------------------------------------------- 比例
#
# 角色总高约 1.75 m，与 player.tscn 的胶囊体一致。所有尺寸按这个身高推导，
# 因此改动身高时要一起调，否则会出现脚陷进地面或头露出碰撞体。
#
# **宽度是最容易做错的一项**：初版把肩与手臂放在离中心 0.36 米处，加上各自的宽度之后
# 肩宽接近一米，于是角色在画面上是一叠箱子而不是一个人（截图核实过）。
# 人体肩宽约 0.45 米，加装甲取 0.55～0.60 米；下面各项都按这个上限反推。

const LEG_HEIGHT := 0.92
const LEG_SIZE := Vector3(0.155, LEG_HEIGHT, 0.20)
const LEG_OFFSET_X := 0.105

## 骨盆：连接两腿与躯干，宽度略大于两腿间距，避免出现镂空。
const HIP_SIZE := Vector3(0.32, 0.16, 0.24)
const HIP_Y := 1.00

## 腰：比胸窄，形成收腰。人体轮廓的辨识度主要来自这一收一放。
const WAIST_SIZE := Vector3(0.28, 0.12, 0.22)
const WAIST_Y := 1.13

const TORSO_SIZE := Vector3(0.40, 0.30, 0.27)
const TORSO_CENTER_Y := 1.34

## 胸甲：比躯干略宽略薄，贴在正面。
const CHEST_SIZE := Vector3(0.44, 0.22, 0.08)
const SHOULDER_SIZE := Vector3(0.16, 0.14, 0.24)
const SHOULDER_OFFSET_X := 0.225
const SHOULDER_Y := 1.44

const HEAD_SIZE := Vector3(0.24, 0.26, 0.27)
## 与 player.tscn 里 Head 节点的 y 一致：相机在头里面，造型的头也必须在这个高度，
## 否则别人看你时头的位置与你的视线高度会对不上。
const HEAD_CENTER_Y := 1.62
const NECK_SIZE := Vector3(0.11, 0.08, 0.11)
const NECK_Y := 1.50

const ARM_SIZE := Vector3(0.115, 0.44, 0.14)
const ARM_OFFSET_X := 0.215
const ARM_Y := 1.18

## 背包与能量核心。
const CORE_RADIUS := 0.075
const CORE_Y := 1.26
const CORE_Z := 0.235


# ---------------------------------------------------------------- 第三人称全身

## 构建整套身体，挂在 root 下。root 是 Player 的 Body 节点，坐标为角色脚底。
##
## 形体思路：把身体当成「几个宽窄不同、互相重叠的块」而不是「一堆独立部件」。
## 两块之间**必须有重叠**（例如胸压在腰上、腰压在骨盆上），
## 否则从侧面看会出现缝隙，而人眼立刻会把它读成「拼起来的玩具」。
static func build(root: Node3D, kind: int) -> void:
	var accent := Palette.element_color(kind)
	var armor := Palette.armor(accent)
	var plate := Palette.armor(accent, true)
	var dark := Palette.armor_dark(accent)
	# 发光件只有四处：面罩、胸前指示带、背部能量核心、腕环。
	# 面积都很小——大面积发光会把角色变成一团彩色光，而不是金属装甲。
	var seam := Palette.glow(accent, 1.6)

	# 腿与骨盆。腿部用暗色贴图，让下半身退后一层，视觉重心落在胸前。
	for side in [-1.0, 1.0]:
		box(root, "Leg%s" % _side_name(side), LEG_SIZE,
			Vector3(side * LEG_OFFSET_X, LEG_HEIGHT * 0.5, 0.0), dark)
		# 膝甲：贴在腿的上段外侧。有了这一块，腿就不是一根方柱。
		box(root, "Knee%s" % _side_name(side), Vector3(LEG_SIZE.x + 0.03, 0.14, LEG_SIZE.z + 0.03),
			Vector3(side * LEG_OFFSET_X, LEG_HEIGHT * 0.55, 0.0), armor)
	box(root, "Hip", HIP_SIZE, Vector3(0.0, HIP_Y, 0.0), armor)
	box(root, "Waist", WAIST_SIZE, Vector3(0.0, WAIST_Y, 0.0), dark)

	# 躯干：胸比腰宽。胸甲再压在躯干正面，形成第二层。
	box(root, "Torso", TORSO_SIZE, Vector3(0.0, TORSO_CENTER_Y, 0.0), armor)
	box(root, "ChestPlate", CHEST_SIZE,
		Vector3(0.0, TORSO_CENTER_Y + 0.02, TORSO_SIZE.z * 0.5), plate)
	# 胸前的元素指示带：玩家在远处判断同伴元素的最主要依据，因此它比环境灯带亮。
	box(root, "ChestGlow", Vector3(CHEST_SIZE.x * 0.55, 0.028, 0.02),
		Vector3(0.0, TORSO_CENTER_Y + 0.10, TORSO_SIZE.z * 0.5 + CHEST_SIZE.z * 0.5), seam)

	# 颈部：填住胸与头之间的空档。没有它时头和身体之间会有一条缝。
	box(root, "Neck", NECK_SIZE, Vector3(0.0, NECK_Y, 0.0), dark)

	# 背包与能量核心。核心在背后，只有从侧面与背面才看得到，
	# 这让「绕到对方背后看一眼」这种交流方式成立。
	box(root, "Backpack", Vector3(0.28, 0.34, 0.12),
		Vector3(0.0, TORSO_CENTER_Y + 0.02, -TORSO_SIZE.z * 0.5 - 0.04), dark)
	sphere(root, "Core", CORE_RADIUS, Vector3(0.0, CORE_Y, -CORE_Z), seam)

	for side in [-1.0, 1.0]:
		var label := _side_name(side)
		# 肩甲压在躯干上沿，与躯干重叠——留缝会让它看起来像粘上去的。
		box(root, "Shoulder%s" % label, SHOULDER_SIZE,
			Vector3(side * SHOULDER_OFFSET_X, SHOULDER_Y, 0.0), plate)
		box(root, "Arm%s" % label, ARM_SIZE,
			Vector3(side * ARM_OFFSET_X, ARM_Y, 0.0), armor)
		# 腕环：手腕位置的发光环，挥手时对方能看到一个亮点。
		box(root, "Wrist%s" % label, Vector3(ARM_SIZE.x + 0.015, 0.022, ARM_SIZE.z + 0.015),
			Vector3(side * ARM_OFFSET_X, ARM_Y - ARM_SIZE.y * 0.5 + 0.05, 0.0), seam)

	# 头盔。面罩朝前（-Z），略凸出：它是角色「看哪里」的唯一线索，
	# 因此必须比周围亮，否则第一人称下无法判断同伴在看什么。
	box(root, "Helmet", HEAD_SIZE, Vector3(0.0, HEAD_CENTER_Y, 0.0), armor)
	box(root, "Visor", Vector3(0.17, 0.085, 0.02),
		Vector3(0.0, HEAD_CENTER_Y + 0.01, -HEAD_SIZE.z * 0.5 - 0.01), seam)
	# 头盔顶脊：一个薄片，用来在逆光时保住头部轮廓。
	box(root, "Crest", Vector3(0.045, 0.028, HEAD_SIZE.z + 0.08),
		Vector3(0.0, HEAD_CENTER_Y + HEAD_SIZE.y * 0.5 + 0.014, 0.0), dark)

	# 右手的世界模型：别人看到你手持武器。
	build_weapon_world(root, kind)


## 别人看到的那把武器：挂在右手位置。
## 它比第一人称那套粗糙，因为距离远、细节看不出来，而多一个高面数的部件会翻倍绘制批次。
static func build_weapon_world(root: Node3D, kind: int) -> void:
	var accent := Palette.element_color(kind)
	var body := Palette.weapon_body(accent)
	var muzzle := Palette.glow(accent, 2.6)
	var anchor := Node3D.new()
	anchor.name = "WeaponAnchor"
	# 右手位置：与 ARM_OFFSET_X / ARM_Y 对齐，因此枪正好在手腕外侧。
	anchor.position = Vector3(ARM_OFFSET_X + 0.05, ARM_Y - 0.16, -0.16)
	root.add_child(anchor)

	box(anchor, "Receiver", Vector3(0.075, 0.095, 0.34), Vector3.ZERO, body)
	box(anchor, "Barrel", Vector3(0.045, 0.045, 0.16), Vector3(0.0, 0.012, -0.24), body)
	box(anchor, "Muzzle", Vector3(0.05, 0.05, 0.05), Vector3(0.0, 0.012, -0.33), muzzle)
	box(anchor, "Stock", Vector3(0.055, 0.08, 0.13), Vector3(0.0, -0.02, 0.23), body)
	box(anchor, "Grip", Vector3(0.055, 0.11, 0.06), Vector3(0.0, -0.09, 0.06), body)


# ---------------------------------------------------------------- 第一人称双手与武器

## 构建第一人称的前臂、双手与武器，挂在 ViewModel 下（它是相机的子节点）。
##
## 坐标是**相机局部坐标**：前方为 -Z，右为 +X，上为 +Y。
## 因此正数 x 表示画面右侧，负数 y 表示画面下方。
##
## 距离相机约半米。这个距离是实测出来的：最初把手臂放在 0.16～0.28 米处，
## 结果 8.5 厘米粗的前臂在画面上占掉了右下角四分之一，看起来像贴着镜头的一块盒子。
## 视角只看到最近的几厘米，而人眼对「一臂之遥」的判断恰好依赖那几十厘米的距离感。
##
## 武器放在右下角并略向左内倾，这是 FPS 的通用构图：枪口指向画面中心偏下，
## 既不挡住准星附近的目标，又能让玩家一眼看到武器指向哪里。
## 两只手的位置由武器的握把与前置握把反推，而不是各自手调：
## 只要武器移动，手的位置应当跟着变，否则会看到手悬在枪外。
static func build_hands(root: Node3D, kind: int) -> void:
	var accent := Palette.element_color(kind)
	var sleeve := Palette.armor(accent, true)
	# 手套用深色金属：只手部用亮色会让两条前臂看起来像同一块塑料。
	var glove := Palette.armor(accent)

	# 后手握把与前手托点的相机坐标，由 WeaponModel 的布局推出。
	# 两者必须一起改：手的位置是从枪身反推出来的，各自调整会让手悬在枪外。
	# 推导：握把在武器局部 (0, -0.092, 0.070)，武器基准点 (0.185, -0.185, -0.84)。
	var rear_grip := Vector3(0.190, -0.277, -0.770)
	# 前握把在武器局部 (0, -0.072, -0.155)。
	var front_grip := Vector3(0.183, -0.257, -0.995)

	# 肘部放到画面外：右手在右下方之外，左手从正下方伸入。
	# 为什么肘部要出画：第一人称看不到自己的上臂，只看到前臂从画面边缘伸进来；
	# 把整个前臂都放进画面会显得手臂特别长。
	limb(root, "ForearmR", Vector3(0.62, -0.62, -0.66), rear_grip + Vector3(0.02, -0.02, 0.03),
		0.075, sleeve)
	box(root, "HandR", Vector3(0.072, 0.095, 0.105), rear_grip, glove)

	limb(root, "ForearmL", Vector3(0.03, -0.70, -0.72), front_grip + Vector3(-0.01, -0.03, 0.03),
		0.068, sleeve)
	box(root, "HandL", Vector3(0.068, 0.085, 0.100), front_grip, glove)


# ---------------------------------------------------------------- 几何辅助

## 建一个长方体。名字用于在场景树里辨认，调试时不必靠位置猜。
static func box(parent: Node3D, node_name: String, size: Vector3, pos: Vector3,
		material: Material) -> MeshInstance3D:
	return _instance(parent, node_name, box_mesh(size), pos, material)


## 建一段肢体：从 from 到 to 的一根方柱。
## 用它而不是手写欧拉角，是因为手臂是斜的，用眼睛调旋转极难对准，
## 而「给出两个端点」是精确的，改姿势时也只改端点。
## 推导：Basis.looking_at(dir, up) 把节点的 -Z 轴转到 dir，而盒子的长边本来就是 Z，
## 因此直接把它放到中点即可。
static func limb(parent: Node3D, node_name: String, from: Vector3, to: Vector3,
		thickness: float, material: Material) -> MeshInstance3D:
	var span := to - from
	var length := span.length()
	var node := _instance(parent, node_name, box_mesh(Vector3(thickness, thickness, length)),
		(from + to) * 0.5, material)
	# 方向与世界上方向平行时 looking_at 会退化（叉积为零），此时不旋转。
	if length > 0.001 and absf((span / length).dot(Vector3.UP)) < 0.999:
		node.basis = Basis.looking_at(span / length, Vector3.UP)
	return node


## 盒体网格。所有方块共用一份构造逻辑，避免有的地方忘了关细分。
static func box_mesh(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	# 显式关掉细分：这些面没有光照细节需要顶点承载，细分只会增加顶点数。
	mesh.subdivide_width = 0
	mesh.subdivide_height = 0
	mesh.subdivide_depth = 0
	return mesh


## 建一个圆柱体。默认沿 Y 轴；axis 只支持三个主轴方向。
## 这里用手写旋转而不是 look_at：look_at 系列用的是**全局**坐标，
## 而这些几何都是别的节点下的子节点，用全局坐标会把相对位置当成世界位置，
## 得到的偏移在 root 不在原点时直接错位。三个主轴对应的欧拉角写死即可。
static func cylinder(parent: Node3D, node_name: String, radius: float, height: float,
		pos: Vector3, material: Material, axis: Vector3 = Vector3.UP,
		sides: int = 16) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = sides
	mesh.rings = 1
	var node := _instance(parent, node_name, mesh, pos, material)
	# 推导：绕 X 轴 -90° 使圆柱的 +Y 轴对齐 -Z（前方）；绕 Z 轴 -90° 使其对齐 +X（右侧）。
	if axis.is_equal_approx(Vector3.FORWARD):
		node.rotation.x = -PI * 0.5
	elif axis.is_equal_approx(Vector3.BACK):
		node.rotation.x = PI * 0.5
	elif axis.is_equal_approx(Vector3.RIGHT):
		node.rotation.z = -PI * 0.5
	elif axis.is_equal_approx(Vector3.LEFT):
		node.rotation.z = PI * 0.5
	return node


static func sphere(parent: Node3D, node_name: String, radius: float, pos: Vector3,
		material: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 20
	mesh.rings = 10
	return _instance(parent, node_name, mesh, pos, material)


static func _instance(parent: Node3D, node_name: String, mesh: Mesh, pos: Vector3,
		material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.position = pos
	node.material_override = material
	parent.add_child(node)
	return node


## look_at 需要第二个参考向量，它不能与视线方向平行。沿 Y 轴瞄准时要换用 Z 轴。
static func _any_up(axis: Vector3) -> Vector3:
	return Vector3.FORWARD if absf(axis.normalized().y) > 0.9 else Vector3.UP


static func _side_name(side: float) -> String:
	return "R" if side > 0.0 else "L"
