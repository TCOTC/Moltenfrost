class_name WeaponModel
extends RefCounted
## 第一人称武器的造型。两把武器共用布局，只在形状语言与附件上区分。
##
## 形状语言是刻意错开的，好让人不看颜色也能分辨手里拿的是什么：
##   「熔」是方正的——方形机匣、鳍片散热、锥形喷嘴，语言是「切割」；
##   「霜」是圆润的——圆柱机匣、环形冷凝器、管状储罐，语言是「喷注」。
## 颜色之外再给一重区分，是因为两种元素色的明度接近，在强 glow 下容易糊成一片。
##
## 坐标是**相机局部坐标**：前方为 -Z、右为 +X、上为 +Y。
## 因此武器整体位于画面右下角，枪口指向 -Z。
##
## 关于为什么不放到 SubViewport 单独渲染（经典 FPS 防止武器穿墙的做法）：
## 本作的第一人称模型本来就贴着相机，而场景是开阔的室内设施，武器不会贴到墙上；
## 引入第二个 Viewport 会带来额外的绘制开销与光照分离问题（武器将不再被场景光照亮）。
## 若以后出现武器插进墙里的情况，再改成独立渲染层。

## 武器在画面中的基准位置。摆动围绕它进行，因此它是「归零」时的位置。
##
## 距离与高度都是实测算出来的。相机竖直视角 62°（见 player.tscn），
## 因此在距相机 d 处的可见半高为 0.60d、半宽为 1.07d。
##
## 关键是**武器的近端**而不是中心：枪托在基准点之后 0.16 米，
## 所以近端距相机只有 0.56 米；若把基准点放在 0.55 处，近端就只剩 0.39 米，
## 那里的可见半高只有 0.23 米，于是 0.11 米高的机匣占掉画面半高的一半——实测就是这样在画面里变成一大块。
## 现取值：近端 0.68 米、枪口 1.19 米，占据画面右下约四分之一。
const BASE_POSITION := Vector3(0.185, -0.185, -0.84)
## 武器的基础朝向。
##
## 三个轴都有意偏了一点，目的是让镜头看到**三个面**而不是正对一个面：
## 正对镜头的长方体在画面上就是一个矩形，看不出厚度，这就是"像个盒子"的直接来源。
## 绕 Y 轴正转把枪口引向画面中心；绕 X 轴微仰让顶部的导轨与瞄具露出；
## 绕 Z 轴微倾则让枪身与地平线不平行，形体因此更可读。
const BASE_ROTATION := Vector3(2.5, 7.0, -2.0)


## 构建武器并返回它的根节点。后续的摆动、开火特效都作用在这个节点上。
static func build(root: Node3D, kind: int) -> Node3D:
	var accent := Palette.element_color(kind)
	var weapon := Node3D.new()
	weapon.name = "Weapon"
	weapon.position = BASE_POSITION
	weapon.rotation = Vector3(
		deg_to_rad(BASE_ROTATION.x), deg_to_rad(BASE_ROTATION.y), deg_to_rad(BASE_ROTATION.z))
	root.add_child(weapon)

	if kind == Element.Kind.MOLTEN:
		_build_plasma_cutter(weapon, accent)
	else:
		_build_cryo_emitter(weapon, accent)

	# 枪口标记：将来发射特效与命中射线都从这里取位置与方向，
	# 因此它必须与喷嘴的实际位置一致，改喷嘴时要一起改。
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0.0, 0.005, -0.35)
	weapon.add_child(muzzle)
	return weapon


# ---------------------------------------------------------------- 熔：等离子切割器

static func _build_plasma_cutter(root: Node3D, accent: Color) -> void:
	var body := Palette.weapon_body(accent)
	var hot := Palette.glow(accent, 3.0)
	var trim := Palette.metal(Palette.METAL_LIGHT, 0.30, 0.70)

	CharacterRig.box(root, "Receiver", Vector3(0.095, 0.10, 0.24), Vector3.ZERO, body)
	# 顶部瞄具轨道：一条窄而长的凸起。它的作用是给枪身一条可读的长轴，
	# 没有它时从背后看这把枪只是一个方块，看不出指向。
	CharacterRig.box(root, "Rail", Vector3(0.040, 0.018, 0.20), Vector3(0.0, 0.058, 0.01), trim)
	CharacterRig.box(root, "Sight", Vector3(0.045, 0.040, 0.018), Vector3(0.0, 0.085, -0.07), hot)
	# 枪托：向后下方伸出一段，与枪管形成一条斜线，剪影因此能看出前后。
	CharacterRig.box(root, "Stock", Vector3(0.062, 0.075, 0.14), Vector3(0.0, -0.040, 0.185), trim)
	# 导流罩比机匣细，形成向前的收窄，视觉上把注意力引向枪口。
	CharacterRig.box(root, "Shroud", Vector3(0.075, 0.075, 0.14),
		Vector3(0.0, 0.004, -0.18), trim)
	CharacterRig.box(root, "Nozzle", Vector3(0.040, 0.040, 0.075),
		Vector3(0.0, 0.004, -0.28), hot)
	# 两侧散热鳍片：三片一组，这是「切割器」最直观的造型线索。
	for side in [-1.0, 1.0]:
		for i in 3:
			CharacterRig.box(root, "Fin%d%s" % [i, CharacterRig._side_name(side)],
				Vector3(0.010, 0.055, 0.026),
				Vector3(side * 0.050, 0.016, 0.02 - float(i) * 0.042), trim)
	# 能量瓶横置于机匣下方，发光。它是画面上除枪口之外唯一的暖色块。
	CharacterRig.cylinder(root, "Cell", 0.026, 0.12, Vector3(0.0, -0.056, 0.03),
		hot, Vector3.FORWARD, 12)
	CharacterRig.box(root, "Grip", Vector3(0.052, 0.12, 0.065), Vector3(0.0, -0.092, 0.070), body)
	CharacterRig.box(root, "ForeGrip", Vector3(0.046, 0.088, 0.055),
		Vector3(0.0, -0.072, -0.155), body)


# ---------------------------------------------------------------- 霜：低温发射器

static func _build_cryo_emitter(root: Node3D, accent: Color) -> void:
	var body := Palette.weapon_body(accent)
	var cold := Palette.glow(accent, 2.8)
	var trim := Palette.metal(Palette.METAL_LIGHT, 0.30, 0.70)

	CharacterRig.cylinder(root, "Housing", 0.052, 0.28, Vector3.ZERO, body, Vector3.FORWARD, 20)
	# 顶部瞄具轨道，与切割器一致：两把枪共用布局，只在形状语言上区分。
	CharacterRig.box(root, "Rail", Vector3(0.040, 0.018, 0.20), Vector3(0.0, 0.061, 0.01), trim)
	CharacterRig.box(root, "Sight", Vector3(0.045, 0.040, 0.018), Vector3(0.0, 0.088, -0.07), cold)
	CharacterRig.box(root, "Stock", Vector3(0.062, 0.075, 0.14), Vector3(0.0, -0.040, 0.185), trim)
	# 三个冷凝环：环与环之间露出机匣，形成节律，也是「低温」的形状语言。
	for i in 3:
		CharacterRig.cylinder(root, "Ring%d" % i, 0.065, 0.020,
			Vector3(0.0, 0.0, -0.015 - float(i) * 0.066), trim, Vector3.FORWARD, 20)
	CharacterRig.cylinder(root, "Emitter", 0.034, 0.060, Vector3(0.0, 0.0, -0.180),
		cold, Vector3.FORWARD, 16)
	# 顶部储罐：粗而短，与细长的冷凝管形成对比。
	CharacterRig.cylinder(root, "Tank", 0.030, 0.16, Vector3(0.0, 0.066, 0.01),
		cold, Vector3.FORWARD, 16)
	CharacterRig.box(root, "Grip", Vector3(0.052, 0.12, 0.065), Vector3(0.0, -0.092, 0.070), body)
	CharacterRig.box(root, "ForeGrip", Vector3(0.046, 0.088, 0.055),
		Vector3(0.0, -0.072, -0.120), body)
