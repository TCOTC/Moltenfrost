class_name MenuBackdrop
extends Control
## 菜单与大厅的共用背景。挂在两个场景里名为 Backdrop 的节点上。
##
## 材质在代码里建，不写进 .tscn：与 scripts/ui/game_theme.gd 同一个理由——
## .tscn 由编辑器保存时整份重写，写进去的说明留不住，而这里每个 uniform 都需要一句
## "为什么是这个值"。代价是编辑器里看不到效果，只有运行时才生效。
##
## 它把材质贴在一张铺满屏幕的贴图上，而不是自己画：着色器里的 UV 需要来自一个
## 有贴图的矩形，直接用 SCREEN_UV 去猜屏幕位置在窗口缩放时会错位。
## 场景里已经有这张贴图（menu.tscn 的 Tint）时就用它，没有时自己建一张（lobby.tscn）。
##
## 场景里保留的 Base（深色 ColorRect）垫在底下：着色器万一编译失败，
## 界面至少还是深底而不是一片白，不至于连字都看不清。

const BACKDROP_SHADER := preload("res://scripts/ui/backdrop.gdshader")

## 色温是否缓慢漂移。做成开关是为了截图对照：
## 漂移会让两张截图逐像素不同，比较改动时反而看不出差别。
@export var drift: bool = true


func _ready() -> void:
	var material := ShaderMaterial.new()
	material.shader = BACKDROP_SHADER
	material.set_shader_parameter("drift", 1.0 if drift else 0.0)
	_tint().material = material


## 用于承载着色器的整屏贴图。优先用场景里已有的 Tint，没有就建一张 4x4 的白色贴图——
## 着色器不使用贴图内容，需要的只是"这个矩形的 UV 从 0 到 1"。
func _tint() -> TextureRect:
	var existing := get_node_or_null("Tint")
	if existing is TextureRect:
		return existing as TextureRect
	var created := TextureRect.new()
	created.name = "Tint"
	created.set_anchors_preset(Control.PRESET_FULL_RECT)
	created.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gradient := Gradient.new()
	gradient.set_color(0, Color.WHITE)
	gradient.set_color(1, Color.WHITE)
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 4
	texture.height = 4
	created.texture = texture
	created.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	created.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(created)
	return created

