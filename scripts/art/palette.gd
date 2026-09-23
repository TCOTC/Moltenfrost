class_name Palette
extends RefCounted
## 科幻美术的集中定义：颜色、PBR 贴图与材质工厂。
##
## 为什么要有这个文件：同一批材质要用在角色、武器、设施与关卡四处，而它们分属不同的脚本。
## 散着写就会各自调色，几轮之后同一面墙在不同文件里颜色不同，而这种偏差在编辑器里看不出来，
## 只能靠肉眼在游戏里发现。所以颜色与贴图只在这里定义一次，其余地方一律引用。
##
## 美术方向：科幻设施。低饱和冷灰蓝金属为底、大面积暗部；
## 亮部几乎全部来自自发光（灯带、能量场、能量件），而不是场景里的平行光——
## 这是科幻设施与户外场景最主要的区别，也是 glow 后处理能发挥作用的前提。
## 两种元素色是画面里唯一的饱和色，因此玩家一眼就能分辨哪些东西属于谁。
##
## ## 去塑料感的两条前提（2026-09-24 补）
##
## 之前所有表面都是纯色材质，看起来像塑料。根因不是「没贴图」，而是两条：
##
## 1. **金属没有东西可反射**。`metallic` 高的材质几乎不漫反射，它显示的全部是环境反射。
##    当时场景的反射来源只有一个纯色环境色，于是所有金属面反射到同一个颜色——
##    这在物理上与「上了漆的塑料」完全一致。修法是用 HDRI 提供环境（见 build_sky）。
## 2. **表面没有微观起伏**。真实金属有划痕、拉丝、磨损与边缘倒角，这些都在法线与粗糙度贴图里。
##    没有它们，一块平面在任何光照下都是一块平面。修法是用 ambientCG 的 PBR 贴图（见 surface）。
##
## ## 贴图与许可
##
## 贴图来自 ambientCG，环境贴图来自 Poly Haven，两者都是 CC0（可商用、无需署名）。
## 清单与下载脚本见 `tools/fetch-assets.mjs`，已在 `THIRD_PARTY.md` 登记。
##
## 材质是共享资源：StandardMaterial3D 允许被多个 MeshInstance3D 同时引用，
## 引擎会按材质合并绘制批次。因此这里全部缓存复用，不要在调用处 new；
## 需要单独改某个实例（例如按钮按下时改自发光）时必须 `duplicate()`。

# ---------------------------------------------------------------- 颜色
#
# **两组意义完全不同的颜色，不要混用**：
#
# TINT_* 是**染色倍数**，会与贴图相乘（见 surface）。因此取值要按
#「目标明度 ÷ 贴图明度」反推，而不是直接写想要的颜色。
# 实测四张贴图的线性亮度（tools/texture-probe.gd 量出来）：
#   MetalPlates006 0.056（深）、Metal032 0.252、CorrugatedSteel009 0.231、
#   Metal030 0.090（深）、Metal006 0.328；四张都是中性灰，只有 Metal032 略偏蓝。
# METAL_* 是**直接反照率**，用于不带贴图的小构件（见 metal）。它的值就是最终的线性明度，
# 因此比 TINT_* 小得多。一个常见错误是拿 TINT_* 去传给 metal()，结果小构件亮得像灯泡。

## 地板：目标明度约 0.05。
const TINT_FLOOR := Color(0.85, 0.92, 1.00)
## 地板上的亮色构件（池子槽壁、出口台、加强筋）。
const TINT_FLOOR_LIGHT := Color(1.10, 1.18, 1.30)
## 地板上的暗色构件（池子槽底、按钮底座）。
const TINT_FLOOR_DARK := Color(0.52, 0.58, 0.70)

## 墙面：目标明度约 0.09。
const TINT_WALL := Color(0.30, 0.36, 0.46)
## 墙面的亮色构件（隔墙、门框、机关门）。
const TINT_WALL_LIGHT := Color(0.46, 0.54, 0.68)
## 天花板与暗色结构：目标明度约 0.06。
const TINT_CEILING := Color(0.22, 0.25, 0.32)

## 装甲：角色的主体材质，明度约 0.31（贴图亮度 0.328 × 染色 0.95）。
##
## 所有装甲部件都用同一张贴图（Metal006），明暗完全靠染色与粗糙度区分。
## 为什么不用两张贴图（一暗一亮）：实测用暗贴图（Metal030，亮度 0.090）时，
## 腿与躯干在设施里几乎全黑，与亮部件之间出现断崖式的明暗差，看起来像拼装的零件。
##
## 为什么明度取到 0.3 而不再压暗：实测 0.13 时角色在设施里仍是一团暗影，
## 而角色**任何时候都必须能被对方看见**，这是双人协作的前提。
## 环境暗、主体亮，才能分出主次；环境与主体一起暗，两个人都找不到对方。
const TINT_ARMOR := Color(0.92, 1.00, 1.15)
## 装甲的亮色部件（肩甲、胸甲、前臂）：明度相近但更光滑，靠粗糙度分层次而不是靠亮度。
const TINT_ARMOR_BRIGHT := Color(0.80, 0.88, 1.05)
## 装甲的暗色部件（腿部、腰部、背包）：比主体暗一档，但**不能暗到看不见**。
const TINT_ARMOR_DARK := Color(0.45, 0.50, 0.62)

## 无贴图金属（直接反照率，就是最终线性明度）。
const METAL_DARK := Color(0.050, 0.058, 0.072)
const METAL_MID := Color(0.110, 0.130, 0.170)
const METAL_LIGHT := Color(0.240, 0.280, 0.360)

## 中性灯带的颜色：偏青的白。它提供环境层次，但不与两种元素色争夺注意力。
const LAMP := Color(0.62, 0.82, 0.95)

# ---------------------------------------------------------------- 贴图素材

const TEXTURE_ROOT := "res://assets/textures"
## 环境贴图。它只用于反射与间接光，不作为可见背景（背景仍是近黑的纯色）。
const HDRI_PATH := "res://assets/hdri/abandoned_workshop_1k.hdr"
## 环境贴图的亮度倍率。
##
## 这是本文件里最需要小心取值的一个数：它同时决定金属反射的强度与间接光的强度。
## 取 1.0 时，废弃车间那张 HDRI（有窗光与灯管）会把整个设施照成白天，与「暗调科幻」相反；
## 取 0.1 以下则金属又变回没有内容的纯色。
const HDRI_ENERGY := 0.30
## 反射用的辐照度立方体分辨率。默认 256 对大面积金属地板不够：
## 地板占满画面下半部分，反射里的灯带轮廓会糊成一团。
## 注意 radiance_size 收的是 **枚举序号**（实测 4.7.2：32/64/128/256/512/1024/2048 → 0/1/2/3/4/5/6），
## 直接传 512 会被拒绍：「Index p_size = 512 is out of bounds (RADIANCE_SIZE_MAX = 7)」。
const HDRI_RADIANCE_SIZE := Sky.RADIANCE_SIZE_512

## 素材 id。集中在这里是因为它们同时出现在关卡与角色两处，手写字符串迟早会拼错一个字母，
## 而拼错的表现是「材质静默地没有贴图」，不容易发现。
##
## Metal034 与 Metal035 已试过并排除：实测平均色分别是 (0.893, 0.693, 0.030) 与 (0.684, 0.445, 0.226)，
## 前者是黄铜、后者是紫铜，与冷色科幻相背（这两张已从 assets 目录删除）。
const TEX_FLOOR := "MetalPlates006"
const TEX_WALL := "Metal032"
const TEX_CEILING := "CorrugatedSteel009"
## 装甲：亮中性金属（实测亮度 0.328）。角色用它，原因见 TINT_ARMOR。
## 这是唯一的一张角色贴图：明暗靠染色区分，不靠换贴图。
const TEX_ARMOR := "Metal006"

# ---------------------------------------------------------------- 缓存
#
# 键是「用途 + 参数」，值是已建好的材质/贴图。用字符串键而不是多个字典，
# 是因为参数组合不多，而一个字典更容易看出有哪些已经在用。

static var _cache: Dictionary = {}
static var _texture_cache: Dictionary = {}
static var _sky: Sky = null


## 取元素色的统一入口。元素色只在 scripts/element.gd 定义一次，这里只做转接：
## 颜色属于元素的语义，放在那边；本文件负责的是材质。两处各存一份的话，
## 几轮之后必然一处改了另一处没改，而这类偏差只能靠肉眼看出来。
static func element_color(kind: int) -> Color:
	return Element.color(kind)


# ---------------------------------------------------------------- 贴图与环境

## 按素材 id 与贴图种类取贴图。找不到时返回 null。
##
## required 决定缺失时要不要报错。只有反照率贴图是必需的：缺了它材质就退回纯色。
## 其余贴图允许缺——ambientCG 对部分素材不提供环境光遮蔽或金属度，
## 那些缺失是正常的，不该在日志里报错（否则日志会被噪音淹掉）。
## 不生成占位贴图：材质侧按 null 决定「不用这张贴图」，这是有意义的降级。
static func texture(material_id: String, map_name: String, required: bool = false) -> Texture2D:
	var key := "%s|%s" % [material_id, map_name]
	if _texture_cache.has(key):
		return _texture_cache[key]
	var found: Texture2D = null
	# 扩展名按 jpg 再 png：下载脚本统一写 jpg，但素材站偶有 png 版的条目。
	for ext in ["jpg", "png"]:
		var path := "%s/%s/%s.%s" % [TEXTURE_ROOT, material_id, map_name, ext]
		if ResourceLoader.exists(path):
			found = load(path) as Texture2D
			break
	if found == null and required:
		push_error("缺少必需的贴图 %s/%s；先执行 node tools/fetch-assets.mjs，再执行一次 --import。" % [
			material_id, map_name])
	_texture_cache[key] = found
	return found


## 建立 HDRI 天空。它只用于「反射」与「间接光」，不作为可见背景——
## 关卡是封闭设施，看到室外天空会很突兀。用法见 level_01.gd 的 _setup_environment：
## background_mode 设成纯色，而 ambient_light_source / reflected_light_source 设成 SKY。
##
## 返回 null 表示贴图缺失（此时调用方应退回纯色环境，而不是让环境为空）。
static func build_sky() -> Sky:
	if _sky != null:
		return _sky
	var panorama := load(HDRI_PATH) as Texture2D
	if panorama == null:
		push_error("缺少环境贴图 %s；先执行 node tools/fetch-assets.mjs，再执行一次 --import。" % HDRI_PATH)
		return null
	var material := PanoramaSkyMaterial.new()
	material.panorama = panorama
	material.energy_multiplier = HDRI_ENERGY
	# 开启过滤：反射按低分辨率采样，不过滤会看到明显的像素块。
	material.filter = true
	_sky = Sky.new()
	_sky.sky_material = material
	_sky.radiance_size = HDRI_RADIANCE_SIZE
	return _sky


# ---------------------------------------------------------------- 结构材质

## 带 PBR 贴图的表面材质。**这是设施、角色与武器的主力材质**。
##
## material_id 决定用哪套贴图；tint 作为乘数叠在反照率贴图上，用来保住美术方向
## （贴图本身是中性金属色，靠 tint 压成冷灰蓝，不必自己改贴图）。
## tile_meters 是贴图在世界里的铺贴尺寸（米）——用法线与粗糙度时这个值必须与实物尺度相称，
## 否则拉丝会粗得像条纹窗帘，或细到看不见。
##
## 缺哪张贴图就跳过哪张：Metal032 这类素材没有环境光遮蔽，缺的时候材质照样成立。
##
## world_triplanar 选择三平面投影的坐标空间：静止的设施用世界坐标（相邻板材之间贴图连续），
## 会移动的角色与武器用局部坐标（贴图跟着物体走，而不是在表面滑动）。
##
## rim 是边缘光强度。它不是自发光，而是在掠射角上叠一层环境色的高光，
## 效果是给物体描一条紧贴轮廓的亮边——这是游戏里让角色在暗处仍可辨的标准做法，
## 比加自发光干净得多（自发光会让整个表面发亮，看起来像塑料玩具）。
static func surface(material_id: String, tint: Color, tile_meters: float,
		roughness: float = 1.0, metallic: float = 1.0,
		emission: Color = Color.BLACK, emission_energy: float = 0.0,
		world_triplanar: bool = true, rim: float = 0.0) -> StandardMaterial3D:
	var key := "surface|%s|%s|%.3f|%.2f|%.2f|%s|%.1f|%s|%.2f" % [
		material_id, tint.to_html(false), tile_meters, roughness, metallic,
		emission.to_html(false), emission_energy, "w" if world_triplanar else "l", rim,
	]
	if _cache.has(key):
		return _cache[key]

	var m := StandardMaterial3D.new()
	var scale := 1.0 / maxf(tile_meters, 0.01)

	# albedo_color 与 albedo_texture 相乘，因此这里给的是「染色倍数」而不是最终颜色。
	var albedo := texture(material_id, "color", true)
	if albedo != null:
		m.albedo_texture = albedo
	m.albedo_color = tint

	var normal := texture(material_id, "normalgl")
	if normal != null:
		# ambientCG 提供的是 OpenGL 约定（绿通道向上）的法线，与 Godot 的默认约定一致，
		# 因此不需要开 normal_map_invert_y。
		m.normal_enabled = true
		m.normal_texture = normal
		m.normal_scale = 1.0

	var rough := texture(material_id, "roughness")
	if rough != null:
		# 贴图与标量相乘：标量用于整体调整这处表面比素材原样更亮还是更哑。
		m.roughness_texture = rough
	m.roughness = clampf(roughness, 0.05, 1.0)

	var metalness := texture(material_id, "metalness")
	if metalness != null:
		m.metallic_texture = metalness
	m.metallic = clampf(metallic, 0.0, 1.0)

	# 环境光遮蔽：Godot 用它压暗缝隙里的间接光。
	var ao := texture(material_id, "ambientocclusion")
	if ao != null:
		m.ao_enabled = true
		m.ao_texture = ao
		# ao_light_affect 控制遮蔽对直接光的影响。0 表示只影响间接光，
		# 这是物理上正确的做法：直接光能照到的地方不该被烘焙的遮蔽压暗。
		m.ao_light_affect = 0.0

	# 三平面投影：本工程的几何都是程序化的长方体，BoxMesh 每个面的 UV 都是 0～1，
	# 因此一张贴图会被拉伸到整块板上（几米宽的地板会把 1K 贴图铺成一层糊）。
	# 三平面投影按坐标取样，铺贴密度只由 uv1_scale 决定，与网格大小无关。
	m.uv1_triplanar = true
	m.uv1_world_triplanar = world_triplanar
	m.uv1_scale = Vector3(scale, scale, scale)
	# 锐度决定三个投影方向之间过渡的硬度。取 1.0 是默认折中：
	# 过高会在 45 度面上出现接缝，过低会把细节抹平。
	m.uv1_triplanar_sharpness = 1.0

	if emission_energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = emission_energy

	if rim > 0.0:
		m.rim_enabled = true
		m.rim = rim
		# rim_tint = 0 时边缘色取自反照率（有色物体的边也是同色），
		# 取 1 时是纯白。取 0.4：既保住物体自身的色相，又比全取反照率更亮。
		m.rim_tint = 0.4

	_cache[key] = m
	return m


## 不带贴图的金属。用于细小的构件（螺钉、边框、栏杆），
## 它们在世界里只占几个像素，贴上带法线的贴图只是噪声，反而让边缘看起来脏。
## 不自发光：暗处自发光的物体会整体偏向元素色，看起来像塑料玩具（实测过）。
static func metal(base: Color, roughness: float = 0.42, metallic: float = 0.85) -> StandardMaterial3D:
	var key := "metal|%s|%.2f|%.2f" % [base.to_html(false), roughness, metallic]
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = base
	m.metallic = metallic
	m.roughness = roughness
	# 结构件不发光。画面里的亮部只应来自灯带与能量场，否则 glow 会把整面墙洗白。
	m.emission_enabled = false
	_cache[key] = m
	return m


## 灯带、屏幕、指示灯一类的自发光面。
## energy 取 1～4：超过 4 之后 glow 的溢出已经饱和，看不出区别，只多耗性能。
static func glow(color: Color, energy: float = 2.2) -> StandardMaterial3D:
	var key := "glow|%s|%.1f" % [color.to_html(false), energy]
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color.darkened(0.55)
	m.metallic = 0.0
	m.roughness = 0.6
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	# 双面显示：灯带往往是薄片，从背面看也必须亮，否则从另一侧走过去会发现灯灭了。
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cache[key] = m
	return m


## 面板：用贴图加微弱自发光。结构件的默认外观。
## 自发光只用于让面板在暗处仍能认出轮廓，强度压在 0.2 以下——
## 实测 0.35 时正对镜头的大块墙板会亮成一块灯箱，而面板本身不应该是灯。
static func panel(material_id: String, tint: Color, tile_meters: float,
		glow_color: Color, energy: float = 1.0) -> StandardMaterial3D:
	return surface(material_id, tint, tile_meters, 1.0, 1.0, glow_color, energy * 0.16, true)

# ---------------------------------------------------------------- 元素能量场

## 元素池的液体表面。半透明加自发光：既让人看出它是致命的，又不会挡住池底的几何。
## 发光强度刻意压在 1.0：池子是画面里面积最大的发光面，强度一高就会把整块地板洗白，
## 而它本来的作用是「标出哪里不能走」，不是照明。实测 1.8 时池面会在 glow 后饱和成白色。
static func energy_field(color: Color) -> StandardMaterial3D:
	var key := "field|%s" % color.to_html(false)
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, 0.78)
	m.metallic = 0.0
	m.roughness = 0.25
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 1.0
	# 半透明加深度预通道会互相冲突（预通道会写深度从而遮住后面的物体），
	# 所以显式关掉预通道并让引擎按深度排序绘制。
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 双击式折射会让池子看起来像水，但也会让池底的网格扭曲到看不清刻度，
	# 而我们将来要靠刻度判断水位，所以只保留一点边缘的菲涅尔增强。
	m.rim_enabled = true
	m.rim = 0.5
	_cache[key] = m
	return m


## 能量场的边沿：池子的发光唇口。它是薄薄一圈，不是一整面墙——
## 早先做成竖直发光面时，从远处看它比池面本身更亮，池子因此看起来像悬空的光板。
static func energy_wall(color: Color) -> StandardMaterial3D:
	var key := "energywall|%s" % color.to_html(false)
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, 0.30)
	m.metallic = 0.0
	m.roughness = 0.15
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 1.1
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 加色混合：它在视觉上应当是「光」而不是「物体」，
	# 因此不与背后的东西做不透明混合，而是把亮度叠加上去。
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# 加色混合不能参与深度写入，否则后面的东西会被它挡住。
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_cache[key] = m
	return m


# ---------------------------------------------------------------- 角色与武器

## 装甲：角色的主体材质。bright 为真时更亮一档，用于肩甲、胸甲、前臂。
##
## 不自发光（元素色只出现在专门的发光件上，由调用方另外建几何）。
## 早先给装甲加过 0.25 的元素色自发光，结果整个角色在暗处像一块发光的彩色塑料：
## 自发光是在没有光照时也存在的颜色，深色底上单一通道的发光会远超其他两通道。
##
## 金属度 0.55 而不是 1.0：全金属几乎没有漫反射，颜色全靠环境反射，
## 于是角色站在没被灯照到的位置时就是一因黑；而角色必须在任何位置都可辨。
## 留一半漫反射之后，它会跟着场景的间接光一起亮起来。
static func armor(_accent: Color, bright: bool = false) -> StandardMaterial3D:
	# 贴图铺贴尺寸 0.13 米。这个值需要**明显小于部件尺寸**：
	# 实测取 0.30 米时，一块 0.4 米的装甲正好只铺到一片贴图，于是整块面上是同一个斑块纹样，
	# 看起来像一块石头而不是金属（贴图的斑块尺度变成了物体的尺度）。
	# 铺贴密到一片贴图远小于部件时，它才重新变成表面的微观纹理。
	# 局部坐标三平面：装甲会跟着角色移动，用世界坐标会让贴图在身体上滑动。
	#
	# 金属度 0.55 而不是 1.0：全金属几乎没有漫反射，颜色全靠环境反射，
	# 于是角色站在没被灯照到的位置时就是一因黑；而角色必须在任何位置都可辨。
	# 留一半漫反射之后，它会跟着场景的间接光一起亮起来。
	return surface(TEX_ARMOR, TINT_ARMOR_BRIGHT if bright else TINT_ARMOR,
		0.13, 0.48 if bright else 0.86, 0.85 if bright else 0.55,
		Color.BLACK, 0.0, false, 0.35)


## 装甲的暗色部件：腿部、腰部、背包。与主体用同一张贴图，只把明度压下一档。
static func armor_dark(_accent: Color) -> StandardMaterial3D:
	return surface(TEX_ARMOR, TINT_ARMOR_DARK, 0.12, 0.90, 0.60, Color.BLACK, 0.0, false, 0.25)


## 武器枪体：与装甲同一套贴图，但铺贴更密、金属度更低。
##
## **金属度必须低于 1**：全金属意味着几乎没有漫反射，颜色全部来自环境反射，
## 而本场景的环境光（HDRI + 屏幕空间间接光）来自远处的灯与窗，于是枪身会比周围环境亮出一大截，
## 看起来像飘在画面上的另一个光照体系里的东西（实测就是这样）。
## 降到 0.75 以后它还有一部分漫反射，会跟着所在位置的环境暗下去。
static func weapon_body(_accent: Color) -> StandardMaterial3D:
	return surface(TEX_ARMOR, Color(0.62, 0.70, 0.86), 0.09, 0.72, 0.70,
		Color.BLACK, 0.0, false, 0.30)
