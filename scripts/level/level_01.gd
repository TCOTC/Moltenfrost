class_name Level01
extends Node3D
## 第一关「双通道」。关卡几何、灯光与环境全部在运行时构建。
##
## 关卡结构（坐标以米为单位，+X 向右、-Z 向前，出生点在 +Z 一侧）：
##
##   z=14  ┌──────────── 北墙 ────────────┐
##         │   出生点 (-5,13)  (5,13)     │
##   z=10  │   ▓ 同元素池 ▓    ▓ 同元素池 ▓ │   ← 自己元素，可以站上去
##   z=6   │   ▣ 熔按钮 ▣      ▣ 霜按钮 ▣   │   ← 各自踩一次，门锁存开启
##   z=2   │   ░ 异元素池 ░    ░ 异元素池 ░ │   ← 对方元素，踩到即复位
##         │          隔墙（x=0）           │
##   z=-6  ├────────── 机 关 门 ───────────┤
##         │                              │
##   z=-12 │     出 口（两人同时到达）      │
##   z=-16 └──────────── 南墙 ────────────┘
##
## 为什么必须两人：主厅被一道高 3.5 米的隔墙从中间分开，而两个按钮分处两侧、
## 且各自只认自己元素的角色。一个角色无法到达另一侧，因此门只能由两人合力打开。
## 这条约束不依赖相克，也不依赖操作技巧，纯粹来自空间与身份。
##
## 关于同元素池与异元素池的摆放：两种池子都放在车道上，而不是只在必经处摆异元素池。
## 同元素池在前（可通行，验证「自己的地形不致命」），异元素池在后（致命，把人送回起点），
## 于是自动检查可以在同一条路线上同时验证两种判定，不需要为测试单独摆地形。

# ---------------------------------------------------------------- 尺寸常量
#
# 全部尺寸只在这里写一次。关卡几何、出生点、自动驾驶路线三者都从这里取值，
# 因此调整房间大小时不会出现「池子悬在空中」或「自动驾驶撞墙」这类不一致。

const ROOM_HALF_WIDTH := 8.0
## 主厅的南北边界。
const HALL_Z := 14.0
## 机关门所在的 z，同时也是主厅与出口厅的交界。
## 两个厅的边界都引用它，因此不会出现「墙在这里、门在那里」的错位。
const GATE_Z := -6.0
const HALL_END_Z := GATE_Z
## 出口厅的南北边界。
const EXIT_HALL_Z := GATE_Z
const EXIT_END_Z := -16.0
const CEILING_HEIGHT := 5.5
const FLOOR_THICKNESS := 0.4

## 两条通道的中心线。出生槽位、池子、按钮都按它对齐。
const CHANNEL_X := 5.0
## 出生点的 z。选在离北墙 1 米处，玩家转身能看见整条通道。
const SPAWN_Z := 13.0
## 同一侧第二个及以后槽位的行距。只有调试时多开实例才会用到后几行。
const SPAWN_ROW_GAP := 2.5
## 通道的通行宽度（以中心线为准的一侧宽度）。池子比它窄一点，留出贴边通过的可能。
const LANE_HALF_WIDTH := 0.9

const DIVIDER_HALF_WIDTH := 0.35
const DIVIDER_HEIGHT := 3.5

## 同元素池与异元素池的 z 中心。
const SAFE_POOL_Z := 11.0
const DEADLY_POOL_Z := 2.25
const POOL_HALF_DEPTH := 1.25
## 池面的高度。几乎与地面齐平，且被一圈槽壁围住。
## 早先把它做成一块抬高的发光平板（面高 0.45 米）时，它看起来像可以踩的台阶，
## 而池子本是液体，必须让人一眼看出「陷下去」或「被围住」。
const POOL_SURFACE_Y := 0.10
## 槽壁高出液面的高度。取值要让槽壁从腰高的平视角度也能被看见，
## 又不能高到挡住池面——遮挡会让玩家看不出里面是液体。
const POOL_WALL_RISE := 0.12
## 液面的可视厚度。它同时决定了液面顶面的高度与槽顶的高度关系（见下）。
const POOL_LIQUID_DEPTH := 0.16
## 槽体深度与槽顶高度。槽顶刻意低于地面 2 厘米，因为地面板的顶面就在 y=0：
## 两者共面会触发深度冲突，池子四周会出现闪烁的暗线。
const POOL_TROUGH_DEPTH := 0.30
const POOL_TROUGH_TOP := -0.02

const BUTTON_Z := 7.25
const BUTTON_HALF_SIZE := 1.1

const GATE_HALF_WIDTH := 2.5
const GATE_HEIGHT := 3.2
const GATE_CENTER_Y := 1.6

const EXIT_Z := -12.0
const EXIT_HALF_SIZE := 1.6


func _ready() -> void:
	_setup_environment()
	_build_shell()
	_build_divider()
	_build_channels()
	_build_gate()
	_build_lights()
	_build_decor()
	_build_exit()


# ---------------------------------------------------------------- 环境

## 环境决定了整体的科幻调性，比几何本身更影响观感，因此参数集中在这里。
## 四条要点：
##   一是背景为近黑纯色。HDRI 只用于反射与间接光，**不显示为背景**——
##   封闭设施里看到室外天空会很突兀，而金属又必须有东西可反射（见 Palette 文件头）。
##   二是雾按距离把远端压向冷色，制造纵深，也让房间看起来比实际更大。
##   三是 glow 的阈值取在中等偏高，只让灯带与能量场溢出，普通金属面不会发亮——
##   阈值一旦调低，整面墙都会发光，设施感立刻变成塑料感。
##   四是 tonemap 用 AgX：它对亮部的处理比 ACES 更能保住色相，
##   而本场景里小面积高亮的灯带很多，这正是最容易溢色的情形。
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.010, 0.014, 0.022)

	# HDRI：反射与间接光的来源。缺贴图时退回纯色环境，而不是让环境为空。
	var sky := Palette.build_sky()
	if sky != null:
		env.sky = sky
		# 转一下天空：让 HDRI 里的窗光不在正前方，而是从前侧斜射，反射层次更丰富。
		env.sky_rotation = Vector3(0.0, deg_to_rad(38.0), 0.0)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
		# 只让一部分间接光来自天空。全用天空时，暗部会被车间的暖色窗光染成褐色，
		# 与「冷色科幻」相背；留一部分给固定颜色，才能把暗部固定在我们想要的蓝调上。
		env.ambient_light_sky_contribution = 0.55
		env.ambient_light_color = Color(0.34, 0.45, 0.66)
		env.ambient_light_energy = 0.60
	else:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.34, 0.45, 0.66)
		env.ambient_light_energy = 0.32

	env.fog_enabled = true
	env.fog_light_color = Color(0.14, 0.21, 0.30)
	env.fog_light_energy = 0.55
	env.fog_density = 0.018
	env.fog_sky_affect = 1.0

	env.glow_enabled = true
	env.glow_intensity = 0.50
	env.glow_bloom = 0.05
	# 阈值取在 1.1 以上：自发光材质的强度大多在 1～3 之间，
	# 阈值过低会让所有自发光的物体一起溢出，池面与灯带糊成一片白。
	env.glow_hdr_threshold = 1.10
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN

	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.tonemap_agx_white = 6.0

	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.6
	# 屏幕空间间接光：它让灯带与亮面把光反弹到附近的地面与墙上。
	# 这一步对「不像塑料」的贡献仅次于 HDRI：纯直接光下的金属看起来很平。
	env.ssil_enabled = true
	env.ssil_intensity = 1.2
	env.ssil_radius = 6.0
	env.ssil_sharpness = 0.98

	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = env
	add_child(world)


# ---------------------------------------------------------------- 外壳

func _build_shell() -> void:
	var shell := Node3D.new()
	shell.name = "Shell"
	add_child(shell)

	var floor_mat := Palette.surface(Palette.TEX_FLOOR, Palette.TINT_FLOOR, 2.4, 1.05, 1.0)
	var wall_mat := Palette.panel(Palette.TEX_WALL, Palette.TINT_WALL, 1.8, Palette.LAMP, 1.0)
	var ceil_mat := Palette.surface(Palette.TEX_CEILING, Palette.TINT_CEILING, 1.5, 1.15, 1.0)

	var z_min := EXIT_END_Z
	var z_max := HALL_Z
	var depth := z_max - z_min
	var z_mid := (z_min + z_max) * 0.5
	var width := ROOM_HALF_WIDTH * 2.0

	Facility.slab(shell, "Floor", Vector3(0.0, -FLOOR_THICKNESS * 0.5, z_mid),
		Vector3(width, FLOOR_THICKNESS, depth), floor_mat)
	Facility.slab(shell, "Ceiling", Vector3(0.0, CEILING_HEIGHT, z_mid),
		Vector3(width, FLOOR_THICKNESS, depth), ceil_mat)

	for side in [-1.0, 1.0]:
		Facility.slab(shell, "Wall%s" % _side_label(side),
			Vector3(side * (ROOM_HALF_WIDTH + 0.4), CEILING_HEIGHT * 0.5, z_mid),
			Vector3(0.8, CEILING_HEIGHT, depth), wall_mat)

	Facility.slab(shell, "WallNorth", Vector3(0.0, CEILING_HEIGHT * 0.5, HALL_Z + 0.4),
		Vector3(width + 1.6, CEILING_HEIGHT, 0.8), wall_mat)
	Facility.slab(shell, "WallSouth", Vector3(0.0, CEILING_HEIGHT * 0.5, EXIT_END_Z - 0.4),
		Vector3(width + 1.6, CEILING_HEIGHT, 0.8), wall_mat)

	# 地面网格：给玩家一个尺度参照。空房间里没有它时，很难判断自己走了多远。
	Facility.grid_lines(shell, "Grid", 0.012,
		-ROOM_HALF_WIDTH + 1.0, ROOM_HALF_WIDTH - 1.0, z_min + 1.0, z_max - 1.0,
		2.0, Color(0.20, 0.32, 0.44))


## 主厅的隔墙。它把两条通道分开，是「必须两人」的空间依据，因此不做成可跳过的矮墙。
func _build_divider() -> void:
	var divider := Node3D.new()
	divider.name = "Divider"
	add_child(divider)
	var mat := Palette.panel(Palette.TEX_WALL, Palette.TINT_WALL_LIGHT, 1.6, Palette.LAMP, 1.0)
	var z_mid := (GATE_Z + HALL_Z) * 0.5
	var depth := HALL_Z - GATE_Z
	Facility.slab(divider, "Wall", Vector3(0.0, DIVIDER_HEIGHT * 0.5, z_mid),
		Vector3(DIVIDER_HALF_WIDTH * 2.0, DIVIDER_HEIGHT, depth), mat)
	# 墙顶的灯带：让隔墙在暗处也有一条清晰的上边缘，玩家因此知道它有多高。
	Facility.lamp(divider, "TopStrip", Vector3(0.0, DIVIDER_HEIGHT + 0.03, z_mid),
		Vector3(DIVIDER_HALF_WIDTH * 2.4, 0.06, depth), Palette.LAMP, 2.0)


# ---------------------------------------------------------------- 通道内容

## 两条通道上的池子与按钮。两侧结构相同、元素相反，因此用同一个循环生成。
## 这样「熔的一侧与霜的一侧完全对称」不是靠手工保证，而是结构上就不可能不对称。
func _build_channels() -> void:
	var channels := Node3D.new()
	channels.name = "Channels"
	add_child(channels)
	for side in [-1.0, 1.0]:
		var kind := Element.Kind.MOLTEN if side < 0.0 else Element.Kind.FROST
		var label := Element.label(kind)
		# 显式标注类型：for 循环变量是 Variant，用它参与的算术无法被推断出来。
		var x: float = side * CHANNEL_X
		# 同元素池：自己元素，可通行。
		_build_pool(channels, "SafePool%s" % _side_label(side),
			Vector3(x, 0.0, SAFE_POOL_Z), kind, "%s 池" % label)
		# 异元素池：对方元素，致命。取另一种元素的名称来命名它。
		var other: int = Element.Kind.FROST if kind == Element.Kind.MOLTEN else Element.Kind.MOLTEN
		_build_pool(channels, "DeadlyPool%s" % _side_label(side),
			Vector3(x, 0.0, DEADLY_POOL_Z), other, "%s 池" % Element.label(other))
		_build_button(channels, "Button%s" % _side_label(side), Vector3(x, 0.0, BUTTON_Z), kind)


## 元素池：一个下沉的金属槽，槽里是发光能量场，槽口有一条更亮的边。
## 三种几何合起来让池子从任意角度都能被认出来——俯视看表面、平视看边沿、远看靠发光。
##
## 构建顺序很重要：子节点全部建好之后才设脚本、才加入场景树。
## 原因是脚本的 _ready 在 add_child 的那一刻立即执行，而 _ready 里要访问这些子节点，
## 先加节点再补子节点会以「Node not found: Mesh」的形式失败。
func _build_pool(parent: Node3D, node_name: String, base: Vector3, kind: int,
		display_name: String) -> void:
	var area := Area3D.new()
	area.name = node_name
	area.position = base

	var accent := Palette.element_color(kind)
	var size := Vector3(LANE_HALF_WIDTH * 2.0, POOL_LIQUID_DEPTH, POOL_HALF_DEPTH * 2.0)

	# 槽：液面下面的一坑深色金属。**槽顶必须低于液面**：两者的顶面一旦共面，
	# 深度冲突会让半透明的液面被深色槽面遮住，表现是池子看起来是黑的（实测踩过）。
	CharacterRig.box(area, "Trough", Vector3(size.x + 0.20, POOL_TROUGH_DEPTH, size.z + 0.20),
		Vector3(0.0, POOL_TROUGH_TOP - POOL_TROUGH_DEPTH * 0.5, 0.0),
		Palette.surface(Palette.TEX_FLOOR, Palette.TINT_FLOOR_DARK, 1.0, 1.2, 1.0))
	# 名为 Mesh 的这个节点由 hazard_zone.gd 自己上材质，这里只建几何。
	# 它的中心在液面之下、底部伸进槽里，因此从侧面看是「一池液体」而不是一块悬浮的板。
	CharacterRig.box(area, "Mesh", size, Vector3(0.0, POOL_SURFACE_Y - POOL_LIQUID_DEPTH * 0.5, 0.0),
		Palette.energy_field(accent))
	# 槽壁：四边各一片，高出液面 POOL_WALL_RISE。片要薄（ 0.12 米），
	# 厚壁会让池子看起来像家具，而它应该是容器。
	var wall_top := POOL_SURFACE_Y + POOL_WALL_RISE
	var wall_height := wall_top
	for side in [-1.0, 1.0]:
		CharacterRig.box(area, "WallX%s" % _side_label(side),
			Vector3(0.12, wall_height, size.z + 0.44),
			Vector3(side * (size.x * 0.5 + 0.16), wall_height * 0.5, 0.0),
			Palette.surface(Palette.TEX_FLOOR, Palette.TINT_FLOOR_LIGHT, 1.0, 0.9, 1.0))
		CharacterRig.box(area, "WallZ%s" % _side_label(side),
			Vector3(size.x + 0.44, wall_height, 0.12),
			Vector3(0.0, wall_height * 0.5, side * (size.z * 0.5 + 0.16)),
			Palette.surface(Palette.TEX_FLOOR, Palette.TINT_FLOOR_LIGHT, 1.0, 0.9, 1.0))
	# 唇口灯：贴在槽壁内侧上沿的一条细灯带，标出危险边界。
	for side in [-1.0, 1.0]:
		CharacterRig.box(area, "LipX%s" % _side_label(side),
			Vector3(0.03, 0.05, size.z + 0.40),
			Vector3(side * (size.x * 0.5 + 0.095), wall_top - 0.02, 0.0),
			Palette.energy_wall(accent))
		CharacterRig.box(area, "LipZ%s" % _side_label(side),
			Vector3(size.x + 0.40, 0.05, 0.03),
			Vector3(0.0, wall_top - 0.02, side * (size.z * 0.5 + 0.095)),
			Palette.energy_wall(accent))

	var collision := CollisionShape3D.new()
	collision.name = "Shape"
	var shape := BoxShape3D.new()
	# 检测体比可见水面略高：角色只要踩到池子上方就算进入，
	# 否则贴边走过时会因为胶囊底部高于水面而漏判。
	shape.size = Vector3(size.x, POOL_SURFACE_Y + 0.9, size.z)
	collision.shape = shape
	collision.position = Vector3(0.0, POOL_SURFACE_Y * 0.5 + 0.25, 0.0)
	area.add_child(collision)

	area.set_script(load("res://scripts/level/hazard_zone.gd"))
	area.set("element", kind)
	area.set("display_name", display_name)
	parent.add_child(area)


## 元素按钮：一块嵌进地面的踏板，按下时下沉并发亮。
func _build_button(parent: Node3D, node_name: String, base: Vector3, kind: int) -> void:
	var area := Area3D.new()
	area.name = node_name
	area.position = base + Vector3(0.0, 0.35, 0.0)

	var size := Vector3(BUTTON_HALF_SIZE * 2.0, 0.16, BUTTON_HALF_SIZE * 2.0)
	# 底座：固定不动，让下沉的踏板有参照。
	CharacterRig.box(area, "Base", Vector3(size.x + 0.36, 0.10, size.z + 0.36),
		Vector3(0.0, -0.24, 0.0),
		Palette.surface(Palette.TEX_FLOOR, Palette.TINT_FLOOR_DARK, 0.8, 1.1, 1.0))
	# Mesh 是 element_button.gd 用来下沉与变色的节点，名字必须一致。
	CharacterRig.box(area, "Mesh", size, Vector3(0.0, -0.125, 0.0),
		Palette.metal(Palette.METAL_MID, 0.40, 0.85))

	var collision := CollisionShape3D.new()
	collision.name = "Shape"
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, 0.5, size.z)
	collision.shape = shape
	area.add_child(collision)

	area.set_script(load("res://scripts/level/element_button.gd"))
	area.set("element", kind)
	parent.add_child(area)


# ---------------------------------------------------------------- 机关门

func _build_gate() -> void:
	var gate := StaticBody3D.new()
	gate.name = "Gate"
	gate.position = Vector3(0.0, GATE_CENTER_Y, GATE_Z)

	var size := Vector3(GATE_HALF_WIDTH * 2.0, GATE_HEIGHT, 0.6)
	# 门面用带贴图的金属：它是「一块挡路的钢板」，不是灯。
	# 早先用带自发光的材质时它正对镜头，亮成了一块灯箱，玩家反而看不出那是门。
	CharacterRig.box(gate, "Mesh", size, Vector3.ZERO,
		Palette.surface(Palette.TEX_WALL, Palette.TINT_WALL_LIGHT, 1.2, 0.85, 1.0))
	# 门面上的横向加强筋：门是一整块移动的物体，需要几条线让它的运动看得出来。
	for i in 3:
		CharacterRig.box(gate, "Rib%d" % i, Vector3(size.x + 0.08, 0.06, 0.04),
			Vector3(0.0, -0.9 + float(i) * 0.9, -0.33),
			Palette.surface(Palette.TEX_FLOOR, Palette.TINT_FLOOR_LIGHT, 0.6, 0.6, 1.0))
	# 竖向的发光边：门需要一条自己的灯，才能在暗处被看见；但它只占宽度的一小段。
	CharacterRig.box(gate, "EdgeGlow", Vector3(0.07, size.y - 0.3, 0.02),
		Vector3(0.0, 0.0, -0.31), Palette.glow(Palette.LAMP, 2.0))

	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	gate.add_child(collision)

	# 按钮路径在加入场景树之前设好：路径是相对本节点的，不需要树已完成，
	# 而 gate._ready 会在 add_child 时立即执行并检查按钮是否为空。
	var buttons: Array[NodePath] = []
	for side in [-1.0, 1.0]:
		buttons.append(NodePath("../Channels/Button%s" % _side_label(side)))
	gate.set_script(load("res://scripts/level/element_gate.gd"))
	gate.set("buttons", buttons)
	gate.set("latched", true)
	add_child(gate)

	# 门框不属于门：它必须固定不动，因此加在本节点下而不是 gate 下。
	var frame_mat := Palette.panel(Palette.TEX_WALL, Palette.TINT_WALL, 2.0, Palette.LAMP, 1.0)
	var frame_width := ROOM_HALF_WIDTH - GATE_HALF_WIDTH
	var frame_center_x := (ROOM_HALF_WIDTH + GATE_HALF_WIDTH) * 0.5
	for side in [-1.0, 1.0]:
		# 门的左右两侧必须封死：门只占中间 5 米，而房间宽 16 米，
		# 不封堵就能绕过门直接走到出口，机关的存亡就失去了意义。
		Facility.slab(self, "GateSide%s" % _side_label(side),
			Vector3(side * frame_center_x, GATE_CENTER_Y, GATE_Z),
			Vector3(frame_width, GATE_HEIGHT, 0.7), frame_mat)
		# 门框：紧邻门的一小段柱，比封堵墙略深，让门的边界更清楚。
		Facility.slab(self, "GateFrame%s" % _side_label(side),
			Vector3(side * (GATE_HALF_WIDTH + 0.6), GATE_CENTER_Y, GATE_Z),
			Vector3(1.2, GATE_HEIGHT, 1.0), frame_mat)


# ---------------------------------------------------------------- 灯光与装饰

## 实际照明由点光源提供：自发光材质只负责「看起来亮」，不会照亮周围。
## 数量刻意压得很低（每盏灯都有逐像素开销），靠灯带的形状补足视觉上的亮度分布。
func _build_lights() -> void:
	var lights := Node3D.new()
	lights.name = "Lights"
	add_child(lights)

	# 极弱的方向光：给所有物体一个统一的上方来向，否则纯点光源会让墙面朝上的部分全黑。
	var sun := DirectionalLight3D.new()
	sun.name = "Fill"
	sun.rotation = Vector3(deg_to_rad(-58.0), deg_to_rad(24.0), 0.0)
	sun.light_color = Color(0.72, 0.82, 1.0)
	sun.light_energy = 0.22
	sun.shadow_enabled = false
	lights.add_child(sun)

	for z in [10.0, 3.0]:
		for side in [-1.0, 1.0]:
			var lamp := OmniLight3D.new()
			lamp.name = "Hall%d%s" % [int(z), _side_label(side)]
			lamp.position = Vector3(side * 3.0, 4.6, z)
			lamp.light_color = Color(0.66, 0.82, 0.98)
			lamp.light_energy = 2.4
			lamp.omni_range = 12.0
			# 关闭阴影：室内多点光源开阴影会把性能吃光，而本关的层次主要靠雾与发光。
			lamp.shadow_enabled = false
			lights.add_child(lamp)

	# 门槛处的踏板灯：为门前后各照一段，玩家进门时视线有落点。
	var exit_lamp := OmniLight3D.new()
	exit_lamp.name = "ExitLamp"
	exit_lamp.position = Vector3(0.0, 4.2, EXIT_Z + 2.0)
	exit_lamp.light_color = Color(0.72, 0.86, 1.0)
	exit_lamp.light_energy = 2.2
	exit_lamp.omni_range = 14.0
	exit_lamp.shadow_enabled = false
	lights.add_child(exit_lamp)

	# 门头灯：门本身是一片金属，而它附近原本没有任何光源，
	# 导致从通道里看过去门面是全黑的，只有门后的绿光透出来。
	# 门是关卡里最关键的一个物体，它必须比周围更亮，而不是更暗。
	var gate_lamp := OmniLight3D.new()
	gate_lamp.name = "GateLamp"
	gate_lamp.position = Vector3(0.0, 3.6, GATE_Z + 1.6)
	gate_lamp.light_color = Color(0.70, 0.84, 1.0)
	gate_lamp.light_energy = 2.8
	gate_lamp.omni_range = 11.0
	gate_lamp.shadow_enabled = false
	lights.add_child(gate_lamp)

	# 元素池上方的补光：让池子的颜色投射到周围地面与角色身上，
	# 这样玩家即使背对池子，也能从地面的反光判断身后是什么。
	# 强度刻意压低：池面本身已经发光，补光过强会把池子附近的地板染成一块纯色。
	for side in [-1.0, 1.0]:
		var kind := Element.Kind.MOLTEN if side < 0.0 else Element.Kind.FROST
		var accent := Palette.element_color(kind)
		for z in [SAFE_POOL_Z, DEADLY_POOL_Z]:
			var pool_light := OmniLight3D.new()
			pool_light.name = "Pool%d%s" % [int(z), _side_label(side)]
			pool_light.position = Vector3(side * CHANNEL_X, 0.9, z)
			pool_light.light_color = accent
			pool_light.light_energy = 0.55
			pool_light.omni_range = 5.0
			pool_light.shadow_enabled = false
			lights.add_child(pool_light)


## 装饰：灯带、管道、立柱。它们不参与玩法，作用是让空间有层次——
## 一个只有墙和地板的房间无论打光多好都会显得空。
func _build_decor() -> void:
	var decor := Node3D.new()
	decor.name = "Decor"
	add_child(decor)
	var trim := Palette.surface(Palette.TEX_FLOOR, Palette.TINT_FLOOR_LIGHT, 0.9, 0.55, 1.0)

	# 两侧墙面的连续灯带：从上到下三道，是画面里最主要的光源形状。
	for side in [-1.0, 1.0]:
		for i in 3:
			var y := 1.4 + float(i) * 1.6
			Facility.lamp(decor, "WallStrip%d%s" % [i, _side_label(side)],
				Vector3(side * (ROOM_HALF_WIDTH - 0.04), y, 4.0),
				Vector3(0.05, 0.07, 20.0), Palette.LAMP, 1.8)

	# 天花板的纵向灯槽：与墙面灯带垂直，让顶部不至于是一块黑。
	for side in [-1.0, 1.0]:
		Facility.lamp(decor, "CeilStrip%s" % _side_label(side),
			Vector3(side * 3.0, CEILING_HEIGHT - 0.06, 4.0),
			Vector3(0.16, 0.05, 20.0), Palette.LAMP, 1.6)

	# 立柱：沿两侧墙各三根，同时给墙面灯带提供遮挡与节奏。
	for side in [-1.0, 1.0]:
		for i in 3:
			var z := 11.0 - float(i) * 7.0
			Facility.column(decor, "Column%d%s" % [i, _side_label(side)],
				Vector3(side * (ROOM_HALF_WIDTH - 0.7), 0.0, z), 0.45, CEILING_HEIGHT,
				Palette.surface(Palette.TEX_WALL, Palette.TINT_WALL, 1.4, 0.9, 1.0))

	# 沿隔墙顶部的短灯带：强调那条把两人分开的墙。
	Facility.lamp(decor, "DividerStrip", Vector3(0.0, 0.6, HALL_Z - 0.6),
		Vector3(DIVIDER_HALF_WIDTH * 2.2, 0.05, 0.05), Palette.LAMP, 1.6)

	# 门头灯槽：与门头灯配合，让「光从哪来」有来源。灯槽跨度取门宽加两侧门框。
	Facility.lamp(decor, "GateHeadLamp", Vector3(0.0, GATE_HEIGHT + 0.55, GATE_Z + 0.2),
		Vector3(GATE_HALF_WIDTH * 2.0 + 2.4, 0.10, 0.24), Palette.LAMP, 2.2)

	# 墙面与地面的细边框：让大面积的贴图面上有硬边可参考，否则贴图铺满一整面墙时
	# 玩家看不出墙有多宽。位置贴着通道内沿。
	for side in [-1.0, 1.0]:
		# 显式标注类型：for 循环变量是 Variant，用它参与的算术无法被推断。
		var x: float = side * CHANNEL_X
		for edge in [-1.0, 1.0]:
			Facility.visual(decor, "ChTrim%s%s" % [_side_label(side), _side_label(edge)],
				Vector3(x + edge * (LANE_HALF_WIDTH + 0.35), 0.06, (HALL_Z + DEADLY_POOL_Z) * 0.5),
				Vector3(0.12, 0.10, HALL_Z - DEADLY_POOL_Z - 1.0),
				Palette.metal(Palette.METAL_DARK, 0.5, 1.0))


# ---------------------------------------------------------------- 出口

func _build_exit() -> void:
	var exit_node := Area3D.new()
	exit_node.name = "Exit"
	exit_node.position = Vector3(0.0, 0.6, EXIT_Z)

	var size := Vector3(EXIT_HALF_SIZE * 2.0, 0.25, EXIT_HALF_SIZE * 2.0)
	# 出口平台：略微抬高，从远处看是一个明确的落点。
	CharacterRig.box(exit_node, "Pad", size, Vector3(0.0, -0.55, 0.0),
		Palette.surface(Palette.TEX_FLOOR, Palette.TINT_FLOOR_LIGHT, 1.2, 0.7, 1.0))
	CharacterRig.box(exit_node, "Mesh", Vector3(size.x - 0.3, 0.06, size.z - 0.3),
		Vector3(0.0, -0.42, 0.0), Palette.glow(Color(0.55, 0.95, 0.72), 2.6))
	# 出口的光柱：四根竖起的发光条，玩家从主厅透过门就能看到它在哪。
	for corner in [Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(-1.0, 1.0), Vector2(1.0, 1.0)]:
		CharacterRig.box(exit_node, "Beam", Vector3(0.10, 3.4, 0.10),
			Vector3(corner.x * (EXIT_HALF_SIZE - 0.2), 1.2, corner.y * (EXIT_HALF_SIZE - 0.2)),
			Palette.glow(Color(0.55, 0.95, 0.72), 2.0))

	var collision := CollisionShape3D.new()
	collision.name = "Shape"
	var shape := BoxShape3D.new()
	# 判定体比可见平台高：站上平台即算到达，不需要精确踩中中心。
	shape.size = Vector3(size.x, 2.4, size.z)
	collision.shape = shape
	exit_node.add_child(collision)

	var exit_light := OmniLight3D.new()
	exit_light.name = "ExitGlow"
	exit_light.position = Vector3(0.0, 2.0, 0.0)
	exit_light.light_color = Color(0.55, 0.95, 0.72)
	exit_light.light_energy = 2.6
	exit_light.omni_range = 10.0
	exit_light.shadow_enabled = false
	exit_node.add_child(exit_light)

	exit_node.set_script(load("res://scripts/level/exit_portal.gd"))
	add_child(exit_node)


# ---------------------------------------------------------------- 辅助

static func _side_label(side: float) -> String:
	return "R" if side > 0.0 else "L"
