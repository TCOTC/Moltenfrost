extends Node
## 临时脚本：跑起来截一张图，供人在没有显示器的情况下核对界面外观。
## 用法（需要真实窗口，不能加 --headless）：
##   godot --path . res://tests/shot.tscn -- --host --port 27315 --shot=game
##   godot --path . res://tests/shot.tscn -- --port 27316 --shot=menu
## `--shot=` 决定截图前停在哪个画面：menu（初始界面）或 game（对局）。
## `--at=<x>` 只在 game 模式下有意义：把本机角色挪到指定的 x，用于看一眼关卡中段。
## 它**不进自动检查**，只供人工看一眼。

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _target: String = "menu"
var _at_x: float = INF


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_target = arg.substr(7)
		elif arg.begins_with("--at="):
			_at_x = float(arg.substr(5))
	var main := MAIN_SCENE.instantiate()
	add_child(main)
	# 等画面稳定：地形、角色、特效都要至少经过一次绘制。
	await get_tree().create_timer(2.0).timeout
	_move_local_player(main)
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := OS.get_user_data_dir().path_join("shot_%s.png" % _target)
	var err := image.save_png(path)
	print("[shot] %s -> %s" % [error_string(err), path])
	get_tree().quit(0 if err == OK else 1)


## 把本机角色挪到指定的 x（脚踩地面），用于看关卡的另一段。
func _move_local_player(main: Node) -> void:
	if is_inf(_at_x):
		return
	for child in main.get_node("Players").get_children():
		var player := child as Player
		if player != null and player.is_local():
			player.global_position = Vector2(_at_x, -Player.HALF_HEIGHT)
			player.velocity = Vector2.ZERO
