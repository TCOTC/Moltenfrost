extends SceneTree
## RemoteInterpolator 的行为测试。用 `--script` 直接跑，不依赖测试框架：
##
##   godot --headless --path . --script tests/remote_interpolator_test.gd
##
## 退出码 0 表示全部通过。tools/net-smoke.mjs 会先跑这个再跑双实例检查。
##
## 重点是**用户的真实场景**：60 次/秒的流，绝大多数间隔 17 ms，但偶尔出现 100 ms 的空档。
## 用分位数（90 分位 = 17 ms）定延迟会被这种空档击穿，表现为"卡一下再瞬移"；
## 而按最大空档定固定延迟又会让链路正常时白白多等。
## 所以这里断言两件事：_case_occasional_gap_has_no_stall 与 _case_occasional_gap_never_goes_backward。
##
## 单位：断言消息里的距离写作 px（生产里的位置就是像素）。模拟用的速度取 6 px/s 这样一个
## 偏小的值，延续 3D 版的取值，目的是让这里的数字能与历史实测记录直接对照。
## 插值器本身与单位无关，因此这里只在意位移的**比例**，不关心绝对速度是否符合游戏手感。

const Interpolator := preload("res://scripts/net/remote_interpolator.gd")

## 显示帧时长（模拟 120 fps）。
const FRAME := 1.0 / 120.0

var _failures: PackedStringArray = PackedStringArray()
var _checks: int = 0
var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run_all()
	if _failures.is_empty():
		print("插值逻辑测试通过（%d 项断言）。" % _checks)
		quit(0)
	else:
		print("插值逻辑测试失败：")
		for line in _failures:
			print("  -- %s" % line)
		quit(1)
	return true


func _run_all() -> void:
	_case_empty()
	_case_single_state()
	_case_linear_midpoint()
	_case_duplicate_snapshots_are_dropped()
	_case_occasional_gap_has_no_stall()
	_case_occasional_gap_never_goes_backward()
	_case_burst_with_sender_timestamps_has_no_jump()
	_case_burst_with_arrival_timestamps_would_jump()
	_case_sender_frame_hitch_has_no_jump()
	_case_buffer_covers_arrival_gap()
	_case_stall_raises_buffer_then_decays()
	_case_stationary_does_not_raise_stall_penalty()
	_case_rate_stays_within_bounds()
	_case_buffer_adapts_to_link()
	_case_stationary_does_not_inflate_buffer()
	_case_resume_after_stationary_has_no_false_lag()
	_case_resume_after_stationary_has_no_jump()
	_case_resume_does_not_rewind()
	_case_time_rewind()


# ---------------------------------------------------------------- 基本行为

func _case_empty() -> void:
	var interp = Interpolator.new()
	_ok(not interp.has_state(), "空缓冲时 has_state() 应为 false")
	_ok(interp.advance(FRAME) == Vector2.ZERO, "空缓冲时 advance() 应返回原点")


func _case_single_state() -> void:
	var interp = Interpolator.new()
	interp.push(Vector2(3, 0), 10.0)
	_ok(interp.advance(FRAME) == Vector2(3, 0), "只有一个快照时 advance() 应返回该快照")
	_ok(interp.position_at(5.0) == Vector2(3, 0), "只有一个快照时，比它更早的时刻应返回该快照")
	_ok(interp.position_at(20.0) == Vector2(3, 0), "只有一个快照时，比它更晚的时刻应返回该快照")


func _case_linear_midpoint() -> void:
	# 匀速直线：0 秒在原点，1 秒在 x=10。查询 0.3 秒应得 x=3。
	var interp = Interpolator.new()
	interp.push(Vector2.ZERO, 0.0)
	interp.push(Vector2(10, 0), 1.0)
	var sampled: Vector2 = interp.position_at(0.3)
	_ok_close(sampled.x, 3.0, "匀速运动中点的插值结果应为 x=3，实际 %.4f" % sampled.x)


func _case_duplicate_snapshots_are_dropped() -> void:
	# 发送方位置只在物理帧变化（60 Hz），快照按网络帧发送（120 Hz），
	# 因此约一半快照与上一份相同。若把它们当作时间轴上的点，
	# 插值会在它那里停住、在下一份处双倍补上，得到固定节律的走一下停一下。
	var interp = Interpolator.new()
	var physics_step := 1.0 / 60.0
	var clock := 0.0
	var next_physics := 0.0
	var physics_time := 0.0
	var expected := 6.0 * FRAME
	var samples := 0
	var worst := 0.0
	var previous := 0.0
	while clock <= 0.6:
		if clock + 1e-9 >= next_physics:
			physics_time = next_physics
			next_physics += physics_step
		interp.push(Vector2(physics_time * 6.0, 0.0), clock)
		if clock >= 0.2:
			var x: float = interp.advance(FRAME).x
			if samples > 0:
				worst = maxf(worst, absf((x - previous) - expected))
			previous = x
			samples += 1
		clock += FRAME
	_ok(samples > 30, "取样次数应当足够多，实际 %d" % samples)
	# 容差取步长的 25%：时钟调速本身会让每帧位移有最多约 10% 的变化（钟速范围 ±10%），
	# 而"停顿"与"双倍补步"分别对应约 100% 的向下与向上偏差，两者相差一个量级，不会混淆。
	_ok(worst <= expected * 0.25, "丢弃重复快照后每一步位移应大致相同，最大偏差 %.6f（步长 %.6f）" % [worst, expected])


# ---------------------------------------------------------------- 用户的真实场景

## 造一条 60 次/秒的流，每隔 gap_every 个样本插入一次 100 ms 空档。
## 位置始终按 6 px/s 匀速前进，这样任何"走一下停一下"都会表现为取样位移不均匀。
func _drive_bursty(interp: Interpolator, duration: float, gap_every: int, gap_size: float) -> Dictionary:
	var clock := 0.0
	var next_send := 0.0
	var sent := 0
	var samples := 0
	var holds := 0
	var fallbacks := 0
	var previous := 0.0
	var worst_wobble := 0.0
	var first := true
	while clock <= duration:
		while clock + 1e-9 >= next_send:
			# 位置是发送时刻的函数，因此"空档"表现为这段时间没有新位置——与真实情况一致。
			interp.push(Vector2(clock * 6.0, 0.0), clock)
			sent += 1
			var step := 1.0 / 60.0
			if gap_every > 0 and sent % gap_every == 0:
				step += gap_size
			next_send += step
		var x: float = interp.advance(FRAME).x
		# 只统计收敛之后的区间，开局第一秒水位还在学。
		if clock >= 1.0:
			if not first and x < previous:
				fallbacks += 1
			# 位移偏离平均值的程度：停顿会让它偏小，补步会让它偏大。
			if not first:
				worst_wobble = maxf(worst_wobble, absf((x - previous) - 6.0 * FRAME))
			previous = x
			first = false
			samples += 1
		clock += FRAME
	return {
		"sent": sent, "samples": samples, "holds": holds,
		"fallbacks": fallbacks, "worst_wobble": worst_wobble,
	}


## 造一条流：发送间隔固定 1/60 秒、位移按 6 px/s 前进。
## lag_after 起的 lag_count 个样本，到达时刻被推后 extra_lag 秒，
## 也就是那一段时间里接收方收不到任何新数据（与链路多排了一会儿队一致）。
## start_time 是发送方时间戳的起点，传上一次的返回值即可续上时间轴；
## 不续的话会被当成时间倒退，插值器会清空历史。返回本次的最后一个时间戳。
func _drive_stream(interp: Interpolator, duration: float, start_time: float,
		lag_after: int = 0, extra_lag: float = 0.0, lag_count: int = 4) -> float:
	var clock := 0.0
	var next_send := 0.0
	var sender_time := start_time
	var sent := 0
	var pending: Array = []
	while clock <= duration:
		while clock + 1e-9 >= next_send:
			sender_time += 1.0 / 60.0
			sent += 1
			var lag := 0.0
			if lag_after > 0 and sent >= lag_after and sent < lag_after + lag_count:
				lag = extra_lag
			pending.append([clock + lag, sender_time, sender_time * 6.0])
			next_send += 1.0 / 60.0
		while not pending.is_empty() and float(pending[0][0]) <= clock + 1e-9:
			var item: Array = pending.pop_front()
			interp.push(Vector2(float(item[2]), 0.0), float(item[1]), float(item[0]))
		interp.advance(FRAME)
		clock += FRAME
	return sender_time


func _case_occasional_gap_has_no_stall() -> void:
	# 这是本轮要解决的场景：100 ms 空档每 20 次发送出现一次。
	# 旧做法（按 90 分位定延迟）会在这里出现大量停顿；按时钟调速应当几乎没有。
	var interp = Interpolator.new()
	var result := _drive_bursty(interp, 4.0, 20, 0.1)
	var stats := interp.sample_stats()
	var hold_ratio := float(stats["hold_ratio"])
	_ok(int(result["samples"]) > 300, "取样次数应当足够多，实际 %d" % result["samples"])
	_ok(hold_ratio <= 0.02,
		"偶尔 100 ms 空档时不应出现停顿，实际停顿比例 %.1f%%" % (hold_ratio * 100.0))
	# 位移的抖动应当很小：停顿会让某帧位移接近 0，补步会让它接近两倍。
	_ok(float(result["worst_wobble"]) <= 6.0 * FRAME * 0.6,
		"每帧位移应大致均匀，最大偏差 %.4f px（步长 %.4f px）" % [result["worst_wobble"], 6.0 * FRAME])


func _case_occasional_gap_never_goes_backward() -> void:
	# 用户描述的另一种形态是"快速往回一点再继续"。按时钟调速时显示时刻永远单调前进，
	# 因此位置不可能倒退（外推已移除，它才是过去出现回拉的原因）。
	var interp = Interpolator.new()
	var result := _drive_bursty(interp, 4.0, 20, 0.1)
	_ok(int(result["fallbacks"]) == 0,
		"显示不应出现任何倒退，实际 %d 帧倒退" % result["fallbacks"])


func _case_burst_with_sender_timestamps_has_no_jump() -> void:
	# 这一条对应真机上最后一个、也是最难看的现象："平稳一下、突然跳一下"。
	#
	# 无线链路把若干包成簇投递（实测成簇间隔约 100 ms）。一簇里含好几份**不同**的位置，
	# 若接收方按"到达时刻"给它们打时间戳，它们就全落在同一时刻上，
	# 于是显示在一帧内从簇内第一份跳到簇内最后一份，把 100 ms 的运动量一次走完。
	#
	# 这里模拟真实情况：一簇的 6 份位置在同一个显示帧到达，
	# 但各自携带**正确的发送时刻**（相隔 1/60 秒）。
	# 断言显示每帧位移保持均匀，即那一簇的运动被摊到 100 ms 的显示时间里。
	var interp = Interpolator.new()
	var physics_step := 1.0 / 60.0
	var frame_step := 1.0 / 120.0
	var worst := 0.0
	var samples := 0
	var previous := 0.0
	var clock := 0.0
	var sender_time := 0.0
	var next_burst := 0.0
	while clock <= 3.0:
		if clock + 1e-9 >= next_burst:
			# 一簇：连续 6 份位置，发送时刻彼此相隔一个物理帧，但同一帧内送达。
			for i in 6:
				sender_time += physics_step
				interp.push(Vector2(sender_time * 6.0, 0.0), sender_time)
			next_burst += 0.1
		var x: float = interp.advance(frame_step).x
		# 从 0.5 秒起开始统计，避开开局锚定。
		if clock >= 0.5:
			if samples > 0:
				worst = maxf(worst, absf((x - previous) - 6.0 * frame_step))
			previous = x
			samples += 1
		clock += frame_step
	var expected := 6.0 * frame_step
	_ok(samples > 200, "取样次数应当足够多，实际 %d" % samples)
	# 容差取步长的 1 倍：钟速 ±10% 会带来约 0.1 倍的变化，
	# 而"一帧内走完一簇"会产生约 6 倍步长的偏差，两者相差一个量级，不会混淆。
	_ok(worst <= expected * 1.0,
		"成簇到达下每帧位移应保持均匀，最大偏差 %.4f px（步长 %.4f px）" % [worst, expected])


func _case_burst_with_arrival_timestamps_would_jump() -> void:
	# 反向用例：证明"用到达时刻打时间戳"确实会产生跳。
	# 它守住的是这个修复本身——若以后有人把时间戳改回本地接收时刻，这条会失败。
	# 同一簇的 6 份位置全部以同一个时刻推入。
	var interp = Interpolator.new()
	var physics_step := 1.0 / 60.0
	var frame_step := 1.0 / 120.0
	var worst := 0.0
	var previous := 0.0
	var clock := 0.0
	var sender_time := 0.0
	var next_burst := 0.0
	var samples := 0
	while clock <= 3.0:
		if clock + 1e-9 >= next_burst:
			for i in 6:
				sender_time += physics_step
				# 关键差别：所有 6 份都用"到达时刻" clock。
				interp.push(Vector2(sender_time * 6.0, 0.0), clock)
			next_burst += 0.1
		var x: float = interp.advance(frame_step).x
		if clock >= 0.5:
			if samples > 0:
				worst = maxf(worst, absf((x - previous) - 6.0 * frame_step))
			previous = x
			samples += 1
		clock += frame_step
	var expected := 6.0 * frame_step
	_ok(worst > expected * 1.5,
		"用到达时刻打时间戳时应当出现明显的单帧跳跃（这正是已修好的那个现象），实际最大偏差 %.4f px" % worst)


func _case_sender_frame_hitch_has_no_jump() -> void:
	# 发送方的物理帧偶尔会掉步：某一帧渲染卡住数百毫秒时，引擎补跑的物理步数
	# 受 max_physics_steps_per_frame 限制，于是**墙钟（也就是时间戳）前进得比位置多**。
	# 真机证据：Windows 侧本机"位置更新"的最大间隔测到 483 ms 与 650 ms，
	# 而同期远端显示的最大单帧位移是 0.17～0.75 m（3D 版实测值，正常应为 0.05 m）。
	# 这里的构造正是那件事：时间戳前进 650 ms，位置只前进 8 个物理步（0.8 px）。
	# 关键是这一段位移**不能按一个物理步去摊**——位移是多步的量，压进一帧就是跳跃。
	var interp = Interpolator.new()
	var physics_step := 1.0 / 60.0
	var frame_step := 1.0 / 120.0
	var speed := 6.0
	var clock := 0.0
	var sender_time := 0.0
	var position := 0.0
	var next_arrive := 0.0
	var since_hitch := 0.0
	var worst := 0.0
	var samples := 0
	var previous := 0.0
	while clock <= 5.0:
		while clock + 1e-9 >= next_arrive:
			var stamp_step := physics_step
			var move_step := speed * physics_step
			since_hitch += physics_step
			if since_hitch >= 1.5:
				since_hitch = 0.0
				# 掉步：墙钟走了 650 ms，物理只补得起 8 步。
				stamp_step = 0.65
				move_step = speed * 8.0 * physics_step
			sender_time += stamp_step
			position += move_step
			# 发送方卡住的这段时间里没有包发出，所以到达间隔与时间戳步长一致。
			interp.push(Vector2(position, 0.0), sender_time, clock)
			next_arrive += stamp_step
		var x: float = interp.advance(frame_step).x
		# 从 1 秒起统计，避开开局锚定；卡顿期间的停顿不计入（只看最大值）。
		if clock >= 1.0:
			if samples > 0:
				worst = maxf(worst, absf(x - previous))
			previous = x
			samples += 1
		clock += frame_step
	_ok(samples > 300, "取样次数应当足够多，实际 %d" % samples)
	# 容差取 2 倍步长：显示要以 1.1 倍钟速追赶，单帧位移最多比正常大 10%；
	# 而把 0.8 px 压进一帧会产生 16 倍步长的偏差，两者相差一个量级。
	var expected := speed * frame_step
	_ok(worst <= expected * 2.0,
		"发送方掉步时不应出现跳跃，最大单帧位移 %.4f px（正常 %.4f px）" % [worst, expected])


func _case_buffer_covers_arrival_gap() -> void:
	# 水位要盖住的是"接收方多久没有新数据"，而无线链路会把若干份攒到一次投递。
	# 那种空档在发送方时间戳里看不出来——它们的时间戳仍然是连续的 1/60 秒，
	# 只有本地到达间隔能反映它。若水位只按发送方间隔定，它会停在下限，
	# 于是每个簇之间都停顿（真机实测停顿 5%～20%，而水位停在 108 ms、空档约 120 ms）。
	var interp = Interpolator.new()
	var physics_step := 1.0 / 60.0
	var sender_time := 0.0
	var position := 0.0
	var wall := 0.0
	var sent := 0
	for i in 40:
		# 一簇：6 份满足"物理帧间隔"的位置，但同一时刻送达。
		for j in 6:
			sender_time += physics_step
			position += 6.0 * physics_step
			interp.push(Vector2(position, 0.0), sender_time, wall)
			sent += 1
		wall += 0.12
	_ok(sent == 240, "应当推入 240 份快照，实际 %d" % sent)
	var expected := clampf(0.12 * Interpolator.BUFFER_HEADROOM,
		Interpolator.MIN_BUFFER, Interpolator.MAX_BUFFER)
	_ok_close(interp.buffer_seconds(), expected,
		"水位应覆盖链路的到达空档（期望 %.0f ms，实际 %.0f ms）" % [
			expected * 1000.0, interp.buffer_seconds() * 1000.0])


func _case_stall_raises_buffer_then_decays() -> void:
	# 链路基准取“已经见过的最坏间隔”，因此它总是事后才知道，
	# 偶尔仍会被更长的一次空档击穿（真机实测每两秒约一次、每次约 100 ms）。
	# 这一条验证第二层反馈：卡顿之后补偿抬高水位，随后按半衰期衰减回基准。
	var interp = Interpolator.new()
	var t := _drive_stream(interp, 3.0, 0.0)
	_ok_close(interp.buffer_seconds(), Interpolator.MIN_BUFFER,
		"没有卡顿时水位应停在基准下限 %.0f ms，实际 %.0f ms" % [
			Interpolator.MIN_BUFFER * 1000.0, interp.buffer_seconds() * 1000.0])
	_ok_close(interp.stall_penalty_seconds(), 0.0,
		"没有卡顿时补偿应为 0，实际 %.0f ms" % (interp.stall_penalty_seconds() * 1000.0))
	# 插一次远超已见空档的到达延迟：这一次必然卡顿。
	# lag_after 从本次的发送计数算起，1.2 秒里能发出 72 份，足够到第 40 份。
	t = _drive_stream(interp, 1.2, t, 40, 0.15)
	var penalty := interp.stall_penalty_seconds()
	_ok(penalty > 0.0,
		"发生卡顿后补偿应当大于 0，实际 %.0f ms" % (penalty * 1000.0))
	_ok(penalty <= Interpolator.STALL_PENALTY_MAX + 0.0001,
		"补偿不得超过上限 %.0f ms，实际 %.0f ms" % [
			Interpolator.STALL_PENALTY_MAX * 1000.0, penalty * 1000.0])
	_ok_close(interp.buffer_seconds(),
		clampf(interp.link_floor_seconds() + penalty, Interpolator.MIN_BUFFER, Interpolator.MAX_BUFFER),
		"水位应等于链路基准加补偿，实际 %.0f ms" % (interp.buffer_seconds() * 1000.0))
	# 链路恢复正常之后，补偿必须表减掉，否则等于永久多等。
	# 半衰期 8 秒，取 64 秒即 8 个半衰期，足以衰减到零。
	_drive_stream(interp, 64.0, t)
	_ok(interp.stall_penalty_seconds() < 0.01,
		"链路正常 64 秒后补偿应衰减到接近 0，实际 %.0f ms" % (interp.stall_penalty_seconds() * 1000.0))
	_ok_close(interp.buffer_seconds(), Interpolator.MIN_BUFFER,
		"补偿表减后水位应回到基准下限，实际 %.0f ms" % (interp.buffer_seconds() * 1000.0))


func _case_stationary_does_not_raise_stall_penalty() -> void:
	# 对端静止时显示必然一直保持（没有新位置可显示），那种保持不是水位不足。
	# 若把它计入，补偿会长期停在上限，等于永久多等——这正是第四轮踩过的坑。
	# 挡住它的手段是时长范围：一次几秒的静止超过 STALL_MAX，不会被当成卡顿。
	var interp = Interpolator.new()
	var t := _drive_stream(interp, 3.0, 0.0)
	var frozen := Vector2(t * 6.0, 0.0)
	var clock := 0.0
	while clock <= 3.0:
		t += 1.0 / 60.0
		interp.push(frozen, t, clock)
		interp.advance(FRAME)
		clock += FRAME
	_ok_close(interp.stall_penalty_seconds(), 0.0,
		"静止不得抬高补偿，实际 %.0f ms" % (interp.stall_penalty_seconds() * 1000.0))


func _case_rate_stays_within_bounds() -> void:
	# 钟速必须在设定范围内：超出范围会让角色看起来明显比实际走得慢或快。
	var interp = Interpolator.new()
	_drive_bursty(interp, 3.0, 20, 0.1)
	var rate := interp.rate()
	_ok(rate >= Interpolator.RATE_MIN - 0.0001 and rate <= Interpolator.RATE_MAX + 0.0001,
		"钟速应在 %.2f～%.2f 之间，实际 %.4f" % [Interpolator.RATE_MIN, Interpolator.RATE_MAX, rate])
	# 水位按实测间隔自适应，但必须守在上下限之内，且与实测的最大连续间隔一致。
	# 上下限各有明确理由：太小会被空档击穿（出现停顿），太大就是白添延迟。
	var buffer := interp.buffer_seconds()
	_ok(buffer >= Interpolator.MIN_BUFFER - 0.0001 and buffer <= Interpolator.MAX_BUFFER + 0.0001,
		"水位应落在 %.0f～%.0f ms 之间，实际 %.0f ms" % [
			Interpolator.MIN_BUFFER * 1000.0, Interpolator.MAX_BUFFER * 1000.0, buffer * 1000.0])
	var expected := clampf(interp.link_floor_seconds() + interp.stall_penalty_seconds(),
		Interpolator.MIN_BUFFER, Interpolator.MAX_BUFFER)
	_ok_close(buffer, expected,
		"水位应等于链路基准（最大连续间隔 × %.1f）加卡顿补偿，期望 %.0f ms 实际 %.0f ms" % [
			Interpolator.BUFFER_HEADROOM, expected * 1000.0, buffer * 1000.0])


func _case_buffer_adapts_to_link() -> void:
	# 水位按实测的**最大连续间隔**自动定，因此链路变好时滞后会自动降下来。
	# 这是"延迟还能优化吗"的主要答案：把链路修好（有线 / 5 GHz / 关省电），
	# 空档从 100 ms 降到十几毫秒，水位就从 150 ms 降到下限 50 ms，白赚 100 ms。
	var fast = Interpolator.new()
	_drive_bursty(fast, 3.0, 0, 0.0)
	_ok_close(fast.buffer_seconds(), Interpolator.MIN_BUFFER,
		"链路好（无空档）时水位应降到下限 %.0f ms，实际 %.0f ms" % [Interpolator.MIN_BUFFER * 1000.0, fast.buffer_seconds() * 1000.0])

	var bursty = Interpolator.new()
	_drive_bursty(bursty, 3.0, 20, 0.1)
	_ok(bursty.buffer_seconds() >= 0.1 * Interpolator.BUFFER_HEADROOM * 0.95,
		"链路有 100 ms 空档时水位应覆盖它并留余量，实际 %.0f ms" % (bursty.buffer_seconds() * 1000.0))
	_ok(bursty.buffer_seconds() > fast.buffer_seconds(),
		"空档大的链路水位应高于无空档的链路")


func _case_stationary_does_not_inflate_buffer() -> void:
	# 静止时长本身就是一次极大的"空档"（可达几秒）。
	# 若把它计入估算，水位会被推到上限，于是对端每停一次、永久滞后就增加一次。
	# 这是上一轮实测踩到的坑，现在必须由这条用例守住。
	var interp = Interpolator.new()
	_drive_bursty(interp, 2.0, 20, 0.1)
	var learned := interp.buffer_seconds()
	# 位置完全不变地推 3 秒（与真人松手时一样）。
	var clock := 2.0
	var frozen_position := Vector2(12.0, 0.0)
	while clock <= 5.0:
		interp.push(frozen_position, clock)
		interp.advance(FRAME)
		clock += FRAME
	_ok_close(interp.buffer_seconds(), learned,
		"静止时长不得抬高水位，实际 %.0f ms（原 %.0f ms）" % [interp.buffer_seconds() * 1000.0, learned * 1000.0])
	# 而且实测用的最大连续间隔也不应包含那段静止。
	_ok(interp.worst_gap() < 0.5,
		"最大连续间隔不应把 3 秒静止算进去，实际 %.0f ms" % (interp.worst_gap() * 1000.0))


func _case_resume_after_stationary_has_no_false_lag() -> void:
	# 这是真机上报出的最大问题：对端静止一段时间后重新移动时，
	# 那整段静止时长曾被当成"显示落后"累积下来（实测达 1421 ms），
	# 于是远端角色长时间几乎不动、然后才慢慢动起来（用户描述为
	#"对方已经走了一段距离了本机才显示对方开始移动"）。
	#
	# 机理：对端静止时位置一直不变、快照全被丢掉，最新快照的时刻不再前移；
	# 显示时钟追到前沿停下。等对端重新移动，最新快照的时刻一次性前移整段静止时长。
	var interp = Interpolator.new()
	var step := 1.0 / 60.0
	var clock := 0.0
	var x := 0.0
	var next_send := 0.0
	# 第一阶段：匀速运动 2 秒，让水位学到。
	while clock <= 2.0:
		if clock + 1e-9 >= next_send:
			next_send += step
			x = clock * 6.0
		interp.push(Vector2(x, 0.0), clock)
		interp.advance(FRAME)
		clock += FRAME
	# 第二阶段：静止 2 秒（位置一直不变，但仍照常推进快照）。
	var still_position := x
	while clock <= 4.0:
		interp.push(Vector2(still_position, 0.0), clock)
		interp.advance(FRAME)
		clock += FRAME
	# 第三阶段：重新移动 0.5 秒，记录滞后与显示是否真的动起来。
	var first_displayed: float = 0.0
	var last_displayed: float = 0.0
	var last_displayed_set := false
	var lag_after_resume := 0.0
	var first_frame := true
	while clock <= 4.5:
		if clock + 1e-9 >= next_send:
			next_send += step
			x += 0.1
		interp.push(Vector2(x, 0.0), clock)
		var displayed: float = interp.advance(FRAME).x
		if first_frame:
			# 恢复后第一帧的滞后：不应把 2 秒静止时长算进去。
			lag_after_resume = interp.fill_seconds()
			first_displayed = displayed
			first_frame = false
		last_displayed = displayed
		last_displayed_set = true
		clock += FRAME
	var buffer: float = interp.buffer_seconds()
	_ok(lag_after_resume <= buffer * 1.5 + 0.02,
		"恢复后滞后不应包含静止时长，应为水位量级（%.0f ms），实际 %.0f ms" % [buffer * 1000.0, lag_after_resume * 1000.0])
	# 恢复后显示必须真的动起来。它整体落后一个水位，所以前 150 ms 仍在显示静止位置，
	# 这是滞后的正常表现；这里只要求它在整个窗口内确实前进了一段明显的距离。
	var displayed_moved := last_displayed - first_displayed
	_ok(last_displayed_set and displayed_moved >= 2.0,
		"恢复后显示应随对端移动，实际只前进了 %.2f px" % displayed_moved)


func _case_resume_after_stationary_has_no_jump() -> void:
	# 真机上报出的现象：对端静止一段后开始移动时，那一瞬间总会卡一下。
	# 机理两条，都在"静止→移动"这个转换上：
	#   1. 插值把整段静止时长当成"从此处匀速走到彼处"，于是目标时刻取在新数据之前一个水位时，
		#      已经跳过了大部分距离 → 一帧内走了很远。
	#   2. 重新锚定把显示时刻往回移（静止时长小于水位时），画面出现倒退。
	# 修法是补一个保持点 + 锚定只允许向前。这里断言每帧位移不再有尖峰。
	var interp = Interpolator.new()
	var step := 1.0 / 60.0
	var frame_step := 1.0 / 120.0
	var clock := 0.0
	var x := 0.0
	var next_send := 0.0
	var worst := 0.0
	var previous := 0.0
	var samples := 0
	var moving := true
	var phase_end := 1.0
	while clock <= 3.0:
		# 交替：匀速运动 1 秒 → 静止 1 秒 → 再运动。
		if moving:
			if clock + 1e-9 >= next_send:
				next_send += step
				x += 6.0 * step
			interp.push(Vector2(x, 0.0), clock)
		else:
			# 静止期间不产生新位置（与真实情况一致：位置不变，快照会被当作重复丢掉）。
			pass
		if clock >= phase_end:
			moving = not moving
			phase_end += 1.0
			# 重新开始移动时重新建立发送节奏。
			next_send = clock
		var displayed: float = interp.advance(frame_step).x
		# 从 0.8 秒起统计，跳过开局锚定。
		if clock >= 0.8:
			if samples > 0:
				worst = maxf(worst, absf(displayed - previous))
			previous = displayed
			samples += 1
		clock += frame_step
	var expected := 6.0 * frame_step
	# 3 秒按 120 帧取样共 360 帧，去掉开头 0.8 秒的锚定期，约 264 帧。
	_ok(samples > 200, "取样次数应当足够多，实际 %d" % samples)
	# 正常单帧位移是 0.05 px。容忍到 4 倍（0.2 px）以容纳钟速与保持点的近似，
	# 而修复前的尖峰是这个值的十几倍。
	_ok(worst <= expected * 4.0,
		"静止后重新移动时不应出现单帧大位移，最大 %.3f px（正常 %.3f px）" % [worst, expected])


func _case_resume_does_not_rewind() -> void:
	# 反向用例：断言显示时刻永远不会因重新锚定而倒流。
	# 曾经的缺陷就是在静止时长小于水位时把显示时刻往回移，导致画面倒退。
	var interp = Interpolator.new()
	var step := 1.0 / 60.0
	var frame_step := 1.0 / 120.0
	var clock := 0.0
	var x := 0.0
	var next_send := 0.0
	var rewind := 0.0
	var previous := 0.0
	var moving := true
	var phase_end := 0.5
	while clock <= 2.0:
		if moving and clock + 1e-9 >= next_send:
			next_send += step
			x += 6.0 * step
			interp.push(Vector2(x, 0.0), clock)
		if clock >= phase_end:
			moving = not moving
			phase_end += 0.5
			next_send = clock
		var displayed: float = interp.advance(frame_step).x
		if clock > 0.3:
			# 只统计倒退（位移反向），正向跳不管。
			rewind = minf(rewind, displayed - previous)
		previous = displayed
		clock += frame_step
	_ok(rewind >= -0.02, "不应出现倒退，最大倒退 %.3f px" % (-rewind))


func _case_time_rewind() -> void:
	# 时间倒退说明计时源换了，应当丢弃历史，而不是拿错位的两个快照去插值。
	# 用位置断言覆盖同一件事：若历史没被丢掉，取样会落在两个错位的快照之间。
	var interp = Interpolator.new()
	interp.push(Vector2(1, 0), 1.0)
	interp.push(Vector2(2, 0), 2.0)
	interp.push(Vector2(3, 0), 1.5)
	_ok(interp.advance(FRAME) == Vector2(3, 0), "时间倒退后 advance() 应使用新快照")
	_ok(interp.position_at(1.5) == Vector2(3, 0), "时间倒退后不应保留旧快照参与插值")


# ---------------------------------------------------------------- 断言

func _ok(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _ok_close(actual: float, expected: float, message: String) -> void:
	_ok(absf(actual - expected) <= 0.0001, message)
