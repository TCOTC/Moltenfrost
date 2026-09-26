class_name StepAnalyzer
extends RefCounted
## 检测位移序列里的「回拉」：退一步，随后立刻恢复原来的方向。
##
## 为什么需要它、而不是简单地数"倒退了几次"：
## 转向也是倒退。真正改变运动方向的转向（例如角色掉头）是正常的，
## 而我们要找的是另一种东西——**方向没有变，只是位置上突然往回退了一点，然后继续前进**。
## 后者才是"对方快速往回移一下再继续"的那个现象（通常叫橡皮筋回拉）。
## 简单计数会把掉头一起算进去，于是数字全是噪声，无法判断。
##
## 判据（需要往后看一步，因此在看到再下一步时才判定上一步）：
##   把三步位移记作 a、b、c（a 最早）。若 b 与 a 的方向相反（倒退），
##   且 c 与 a 的方向相同（又回到原方向），则 b 是一次回拉；
##   回拉量取 b 在 -a 方向上的投影（像素）。
## 掉头不满足第二条（c 会继续沿 b 的方向），因此不会被计入。
##
## 长度为 0 的位移（重复快照、或角色停在原地）不参与判定，也不会打断参考方向。
## 状态是 Vector2（2D 版）；判定只用到方向与投影，与维度无关。

## 判定方向是否相反：点积小于该值即视为相反。取负的极小量，避免数值噪声。
const OPPOSITE_EPS := 0.0
## 位移长度小于该值即视为"没有移动"（重复快照或停格），不参与判定。
const ZERO_STEP_EPS := 0.0001

var dips: int = 0
var max_dip: float = 0.0

var _started: bool = false
var _has_first: bool = false
var _last: Vector2 = Vector2.ZERO
var _first: Vector2 = Vector2.ZERO
var _second: Vector2 = Vector2.ZERO


## 送入一个位置采样（按时间顺序）。位置未变时不会影响判定。
func add(position: Vector2) -> void:
	if not _started:
		_last = position
		_started = true
		return
	var step := position - _last
	_last = position
	if step.length() <= ZERO_STEP_EPS:
		return
	if _has_first:
		# 判定更早那一步（_second）是否为回拉，因为要往后看一步才知道是否恢复方向。
		var went_back := _second.dot(_first) < OPPOSITE_EPS
		var came_back := step.dot(_first) > OPPOSITE_EPS
		if went_back and came_back:
			dips += 1
			max_dip = maxf(max_dip, maxf(-_second.dot(_first.normalized()), 0.0))
	_first = _second
	_second = step
	_has_first = true


func take() -> Dictionary:
	var result := {"dips": dips, "max_dip": max_dip}
	dips = 0
	max_dip = 0.0
	return result
