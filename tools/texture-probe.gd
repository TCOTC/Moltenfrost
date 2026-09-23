extends SceneTree
## 量出每张反照率贴图的平均色与平均亮度。扫描 assets/textures 下的全部素材目录。
##
## 为什么要量：tint 是**乘数**（albedo_color × albedo_texture），
## 因此「最终看起来是什么颜色」等于贴图色与 tint 的乘积。不知道贴图本身偏什么色，
## 就只能靠猜 tint，而猜错的表现是「装甲变成黄铜」「整体偏亮」这类
## 需要反复截图才发现的问题。量一次比改十次快。
##
## 实测结论（2026-09-24）：Metal034 是黄铜色（0.893, 0.693, 0.030），不可用；
## Metal032 / CorrugatedSteel009 是中性灰；MetalPlates006 是深中性灰。

func _init() -> void:
	var root := "res://assets/textures"
	var dir := DirAccess.open(root)
	if dir == null:
		print("没有 %s；先执行 node tools/fetch-assets.mjs。" % root)
		quit()
		return
	var ids := dir.get_directories()
	ids.sort()
	for id in ids:
		var path := "%s/%s/color.jpg" % [root, id]
		if not ResourceLoader.exists(path):
			print("%-22s 没有 color.jpg" % id)
			continue
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img == null:
			print("%-22s 读取失败" % id)
			continue
		var total := Vector3.ZERO
		var sum := 0.0
		var count := 0
		# 每 8 个像素取一个：1K 图有 100 万像素，全扫没有必要，
		# 而取样步长固定为 2 的幂可以避免因行宽导致的规律性偏差。
		for y in range(0, img.get_height(), 8):
			for x in range(0, img.get_width(), 8):
				var c := img.get_pixel(x, y)
				total += Vector3(c.r, c.g, c.b)
				# sRGB → 线性的近似：渲染时贴图会被转成线性，判断亮度要在线性域比。
				sum += pow((c.r + c.g + c.b) / 3.0, 2.2)
				count += 1
		var avg := total / float(count)
		var linear := sum / float(count)
		# 色相偏差 = R − B：接近 0 是中性灰，明显为正是暖色（黄/红）。
		print("%-22s 平均色=(%.3f, %.3f, %.3f)  线性亮度=%.3f  色相偏差=%+.3f" % [
			id, avg.x, avg.y, avg.z, linear, avg.x - avg.z,
		])
	quit()
