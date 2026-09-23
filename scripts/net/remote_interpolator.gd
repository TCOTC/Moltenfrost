class_name RemoteInterpolator
extends RefCounted
## 远端物体的位置平滑：把按帧到达的位置快照排成沿显示帧连续、且不会跳变的轨迹。
##
## 四层原因叠在一起，前两层修完仍不够，后两层是在两台真机上试出来的：
##
## 1. 引擎不做插值。SceneReplicationInterface 收到同步包时直接把位置赋给节点
##    （on_sync_receive → MultiplayerSynchronizer::set_state），中间没有任何插值，
##    所以任何不连续都会直接表现在画面上。
## 2. 快照里夹着重复位置。发送方的位置只在物理帧变化，而快照按网络帧发送，
##    120 帧显示、60 Hz 物理时约一半快照与上一份相同。把重复快照当成时间轴上的一个点，
##    插值会在它那里停住、在下一份处双倍补上，得到固定节律的"走一下停一下"。
##    所以这里丢弃位置未变的快照。
## 3. 显示必须留一段缓冲。快照的到达并不均匀——真机实测 60 次/秒的流里
##    绝大多数间隔是 17 ms，但偶尔出现 100 ms 的空档（100 ms 恰好是无线网络的
##    beacon/DTIM 周期，终端省电时数据由接入点缓冲后按该周期成簇投递）。
##    显示时刻若贴到最新快照上，遇到这种空档就没有可插值的区间，只能保持，
##    到货后再跳过去。所以要留一段缓冲把空档盖住。
## 4. **对端静止时不得把静止时长算成滞后。** 对端不动则位置一直不变、快照全被当作
##    重复丢掉，最新快照的时刻不再前移；显示时钟追到前沿停下（此时"停顿"是正常的，
##    本来就没有数据可插值）。等对端重新移动，最新快照的时刻会一次性前移整段静止时长，
##    若把它当成落后量，显示就要用很久去"追"那段从未发生过的运动——实测滞后曾达 1421 ms，
##    表现为远端角色长时间几乎不动、然后才慢慢动起来。
##    修法：这种时刻把显示时刻**重新锚定**到新数据之前一个水位处。
##    因为显示当时就停在对端静止的位置上，而新数据也从那里开始，所以重新锚定不会造成跳变。
##
## 缓冲是**固定值**而不是按实测空档自动定。曾经试过按空档自适应，但那条路有正反馈陷阱：
## 静止时长本身就是一次极大的"空档"，它会反过来把水位推向上限，于是对端每停一次，
## 永久滞后就增加一次（实测 2 秒静止即把水位推到 400 ms 上限）。
## 而真正想覆盖的只是链路抖动（十几到一百多毫秒），与静止时长差一个数量级以上，
## 无法用同一个统计量区分。所以取固定值，把"链路多久来一次包"交给诊断输出观察。
##
## 显示时钟按可变钟速前进，而不是用固定延迟查询：
##   - 缓冲偏少（快要被追平）→ 钟速 0.9 倍，让新快照追上来；
##   - 缓冲偏多（滞后太大）→ 钟速 1.1 倍，把多余滞后消耗掉。
## **调整只改变钟速，显示时刻永远单调前进，因此任何调整都不会造成位置跳变。**
## 固定延迟做不到这一点——改延迟等于把显示时刻往回挪，就会看到倒退。
#### 最近一批修完仍不够，第五轮才定位到最后一个、也是最关键的一层：
##
## 5. **时间戳必须来自发送方，不能用接收时刻。** 无线链路会把若干包成簇投递
##    （实测成簇间隔约 100 ms）。一簇里往往含 5～6 份不同的位置，
##    如果按"到达时刻"给它们打时间戳，它们就全落在同一个时刻上，
##    而插值在这样一条时间轴上会：平稳走到簇内第一份，然后一帧内跳到簇内最后一份
##    （因为中间那些样本的时刻几乎相同），之后等下一簇。表现就是"平稳 → 跳一下 → 停一下"。
##    **这个跳与水位大小无关**，因为它是数据在时间轴上的摆放方式造成的，不是缓冲不足，
##    所以前几轮调水位、改延迟都不可能修好它。
##    修法：发送方随每次同步发出自己的时刻（见 player.gd 的 sync_time），
##    接收方用它给快照排序。这样一簇里 100 ms 的运动量会被摊到 100 ms 的显示时间里，
##    而不是挤进一帧。
##
## 因此本类的时间参数语义是**发送方时刻（秒）**，而不是本地时刻。
## 因为只用到"最新快照时刻减去显示时刻"这类差值，而发送方时刻与本地时间同一速率，
## 所以不需要估计两端的时钟偏移。
#### 代价两条：远端角色整体晚一个缓冲（默认 150 ms）；
## 显示的运动速度与实际最多差一成（钟速 0.9～1.1）。两者都只作用于"别人看到的我"，
## 不影响本机操作，也不参与判定——权威节点上的位置始终用收到的原始值（见 player.gd）。
##
## 这个类不接触场景树，时间由调用方传入，因此可以单独测试，见 tests/remote_interpolator_test.gd。

## 默认缓冲水位（秒）。实际值由实测的连续运动间隔推出，见 _update_buffer。
## 水位既是盖住链路抖动的余量，也是"别人看到的我"的额外滞后，所以两个方向都要顾：
##   太小 → 空档击穿，出现停顿；
##   太大 → 白添延迟。
## 早先把它定为固定 150 ms，那是按实测的无线空档（约 100 ms）定的；
## 但如果链路很好（有线、5 GHz、省电关闭），空档只有十几毫秒，
## 再用 150 ms 就是白等 100 ms。所以改成按实测自适应。
const DEFAULT_BUFFER := 0.15
## 水位下限。即使链路很快也留一点余量吸收到达抖动，同时也是钟速机制的工作空间。
const MIN_BUFFER := 0.05
## 水位上限。再大就会让远端角色明显滞后，宁可偶尔卡一下也不接受这种手感。
const MAX_BUFFER := 0.35
## 水位相对实测最大连续间隔的倍数。大于 1 是为了留余量：下一次空档总可能比已见过的长。
const BUFFER_HEADROOM := 1.3
## 单帧时长上限。系统卡顿或资源加载会让某一帧长达上百毫秒，
## 若把它全额推给显示时钟，就会一次跳很远而直接撞上前沿；夹住之后落后的部分交给钟速补。
const MAX_FRAME := 0.1
## 钟速范围。慢放让缓冲长起来，快放消耗多余滞后；幅度取 ±10%，
## 修正能力足够，同时不至于让人看出角色走得比实际慢或快。
const RATE_MIN := 0.9
const RATE_MAX := 1.1
## 钟速对缓冲误差的增益：误差 25 ms 即用满 ±10% 钟速。
const RATE_GAIN := 4.0
## 判定"数据仍在流动"的窗口（秒）。停顿只在数据确实还在来的时候才计入统计：
## 对端静止时显示必然一直保持，那种保持没有意义，计入会让这个指标失去判别力
##（实测对端静止时它恒为 100%，完全掩盖了真正的停顿）。
const FLOWING_WINDOW := 0.25
## 间隔样本的保留数量。既用于估计发送方步长（最小值），也用于估水位（最大值）。
const GAP_WINDOW := 32
## 卡顿补偿。水位原来只按实测的最坏间隔定，而“最坏”总是事后才知道，
## 所以偶尔仍会被更长的一次空档击穿（真机实测每两秒约一次、每次约 100 ms）。
## 因此再加一层反馈：用实测的卡顿时长抬高水位，随后按半衰期衰减回链路基准。
## 三个常量对应三个约束：
##   以延迟最小为先 —— 没有卡顿时补偿为 0，水位就等于链路基准；
##   只补水位不足   —— 短于 STALL_MIN 的是抖动噪声，长于 STALL_MAX 的更可能是
##                     对端停止更新或系统级卡顿，加大水位也解决不了，两者都不计入；
##   不能加到太大   —— 单次补偿不超过 STALL_PENALTY_MAX。
const STALL_MIN := 0.03
const STALL_MAX := 0.2
const STALL_PENALTY_MAX := 0.06
## 补偿的半衰期（秒）。衰减比抬高慢得多，因为卡顿往往反复出现而不是一次；
## 但也不能不衰减：链路变好之后必须回到链路基准，否则等于永久多等。
const STALL_HALF_LIFE := 8.0
## 反馈生效前需要先收到的快照数。开局水位还在学，那时的卡顿不代表链路特征。
const STALL_WARMUP := 30
## 快照保留上限。按水位换算只需要两三个，留足余量以免异常时刻丢掉有用的历史。
const MAX_STATES := 64
## 时间轴突变的阈值（秒）。超过它说明时间戳的计时源换了（例如发送方重启、
## 或者初始值 0 与真实时刻混在一起），此时旧历史没有意义，直接当作时间轴重启。
## 取值 2 秒：正常的运动停顿长于它也只会导致一次重新锚定，
## 而对象当时是静止的，所以看不出来。
const TIMELINE_DISCONTINUITY := 2.0

var _times: PackedFloat64Array = PackedFloat64Array()
var _states: Array[Vector3] = []
## 当前水位（秒）。默认按实测自适应；由调用方显式指定时改为固定值（adaptive = false）。
var buffer: float = DEFAULT_BUFFER
## 为 false 时 buffer 不被自适应改写。
var adaptive: bool = true
## 显示时刻。除 reset 之外它永远单调前进，位置由它决定。
var _render_time: float = -1.0
## 最近一次收到"位置有变化"的快照的时刻。
var _last_unique_time: float = -1.0
## 本实例累计的墙钟时间（由 advance 的 delta 累加），用于判断数据是否仍在流动。
var _wall: float = 0.0
## 最近一次收到"位置有变化"的快照时的墙钟时间。
var _last_unique_wall: float = -1.0
## 显示时钟是否已经追到前沿（在等新数据）。
var _holding: bool = false
## 相邻唯一快照的间隔样本（秒）。用于估水位（见 _update_buffer）与发送方步长（见 _step_estimate）。
## 取样时取“发送方时间戳间隔”与“本地到达间隔”的较大者：
## 前者反映发送方产生新位置的节奏，后者反映链路把若干份攒到一次投递造成的空档。
## 无线链路（省电、排队）会让后者明显大于前者，而水位要盖住的正是后者。
var _gaps: PackedFloat64Array = PackedFloat64Array()
## 最近一次收到“位置有变化”的快照时的**本地墙钟**时刻（秒）。
## 它与 _last_unique_wall 不同：后者是显示帧累计时间，用于“数据是否仍在流动”，
## 而水位需要真实墙钟才能反映链路空档。
var _last_arrival_wall: float = -1.0
## 速度估计（米／秒），由最近的位移段得出。
## 它用来区分一段大间隔的两种成因，两者需要完全不同的处理：
##   连续移动中的发送停顿（发送方自己的帧卡了一下）→ 位移量约等于 速度×间隔 → 直接插值即可；
##   对端静止后重新移动 → 位移量远小于 速度×间隔 → 需要补保持点，否则会把静止时长当成位移。
## 它必须有回落到真实值的路径（见 push 里的三分支），否则一次错位样本就能把它永久抬高，
## 从而让所有正常间隔都被判成"不连续"，水位估算与静止判定一起失效。
var _speed: float = 0.0
## 卡顿补偿（秒）。见 STALL_MIN 一带的说明。
var _stall_penalty: float = 0.0
## 当前这次卡顿的开始墙钟时刻，以及它是否值得计入补偿。
var _stall_start: float = -1.0
var _stall_armed: bool = false
## 收到的“位置有变化”的快照数，用于 STALL_WARMUP。
var _unique_count: int = 0


## 估计发送方的物理步长（秒）：取最近间隔里的最小值。
## 最小值对应"连续两个物理帧各发一份"的情形，也就是发送方产生新位置的粒度。
## 它现在只用作“位移应有时的长”的下限（见 push），避免速度估计异常时算出零。
func _step_estimate() -> float:
	var smallest := 0.0
	for gap in _gaps:
		if gap <= 0.0:
			continue
		if smallest <= 0.0 or gap < smallest:
			smallest = gap
	if smallest <= 0.0:
		return 1.0 / 60.0
	return clampf(smallest, 1.0 / 240.0, 0.1)

# 统计（由 sample_stats 取走后清零）
var _samples: int = 0
var _holds: int = 0
var _pushed: int = 0
var _duplicated: int = 0
var _rate: float = 1.0


## 记录一个刚收到的快照。sender_time 是**发送方**产生这份位置时的时刻（秒），
## 而不是本地接收时刻。为什么这一点关键见文件头第 5 点。
## arrival_wall 是本地墙钟时刻（秒），只用于估水位。不传时退化为 sender_time 代替，
## 因此不涉及网络的测试只需要传两个参数。
func push(state: Vector3, sender_time: float, arrival_wall: float = -1.0) -> void:
	# 时间倒退说明发送方重启了或计时源换了，丢弃历史重新开始，否则会算出错误的结果。
	if not _times.is_empty() and sender_time < _times[_times.size() - 1]:
		reset()
	_pushed += 1
	if not _times.is_empty() and state == _states[_states.size() - 1]:
		# 位置没有变化：这份快照不带来新信息。见文件头第 2 点。
		# 不必担心"角色停下了却不更新"：位置不变时保持上一个值本来就是正确行为。
		_duplicated += 1
		return
	_last_unique_time = sender_time
	_last_unique_wall = _wall
	_unique_count += 1
	# 到达间隔必须在任何分支之前算完并前移基准：
	# 否则"静止后重新移动"那一次留下的静止时长会溶进下一段连续运动的到达间隔，
	# 把水位一路推高（静止时长是秒级）。
	var arrival_gap := -1.0
	if arrival_wall >= 0.0 and _last_arrival_wall >= 0.0:
		arrival_gap = arrival_wall - _last_arrival_wall
	if arrival_wall >= 0.0:
		_last_arrival_wall = arrival_wall
	# 本次是否补了保持点，以及那段位移应有的时长。重新锚定要用它：
	# 若把显示时刻锚到 sender_time - buffer，而保持点在更早的位置，
	# 显示就会跳过整段保持段，一帧内走完那段位移——跳跃就是这么来的。
	var resume_span := 0.0
	if not _times.is_empty():
		var previous_time := _times[_times.size() - 1]
		var gap := sender_time - previous_time
		var moved := _states[_states.size() - 1].distance_to(state)
		if gap > 0.0 and gap <= TIMELINE_DISCONTINUITY:
			# 这段位移按速度估计"应当"占多长。时间轴是否被拉长要与它比较，
			# 而不是与固定一个物理步比较：否则位移大时（发送方卡帧、掉步、或者
			# 墙钟前进而物理位置没跟上）会把整段位移压进一帧，
			# 真机实测最大单帧位移 0.17～0.75 m，而正常值应为 0.05 m。
			if _speed <= 0.0:
				# 刚开局，还没有速度估计，因此没有依据判断这段间隔是否正常。
				# 只用它建立速度估计：既不收水位样本，也不补保持点。
				# 否则第一段任何长间隔都会被当成"时间轴拉长"而插入保持点。
				_speed = moved / gap
			else:
				var expected := maxf(moved / _speed, _step_estimate())
				if gap <= expected * 1.5:
					# 位移与间隔相符：连续运动。只有这类间隔才用来估水位。
					# 静止时长绝不能计入：它是一次极大的"空档"，会把水位推到上限，
					# 于是对端每停一次、永久滞后就增加一次（这是上一轮踩过的坑）。
					# 取样取发送方间隔与本地到达间隔的较大者：无线链路会把若干份
					# 攒到一次投递，此时发送方时间戳是连续的、看不出空档，
					# 而水位要盖住的正是那个空档。
					var span := gap
					if arrival_gap >= 0.0:
						span = maxf(gap, arrival_gap)
					_gaps.append(span)
					while _gaps.size() > GAP_WINDOW:
						_gaps.remove_at(0)
					_update_buffer()
					# 用它更新速度估计。
					var measured := moved / gap
					_speed = lerpf(_speed, measured, 0.3)
				elif gap <= expected * 2.5:
					# 量级相符但有出入：多半是速度估计本身偏了。让它回落即可，
					# 不能在这里补保持点：这段位移本来就是连续的，补了反而把它压进更短的时长。
					# 没有这条回落路径，一次错位的速度估计会永久抬高自己，
					# 此后所有正常间隔都被判成"不连续"，水位就不再随链路变化
					#（实测症状：最大连续间隔固定在远小于物理步长的值上）。
					_speed = lerpf(_speed, moved / gap, 0.3)
				else:
					# 间隔远长于位移所需：时间轴被拉长。两种成因都要补保持点：
					# 其一，对端静止后重新移动（位移小，间隔里含着整段静止时长）；
					# 其二，发送方卡帧或掉步（墙钟前进而物理位置没跟上）。
					# 保持点放在"按速度估计这段位移该占的时长"之前：
					# 这样静止期间显示的是原位置（正确），位移则被摊在它应有的时长里（平滑）。
					_times.append(sender_time - expected)
					_states.append(_states[_states.size() - 1])
					resume_span = expected
	_times.append(sender_time)
	_states.append(state)
	if _holding and _render_time >= 0.0:
		# 之前已经追到前沿（在等新数据），现在有新数据了。见文件头第 4 点：
		# 必须重新锚定显示时刻，否则那段等待时长会被当成落后量。
		# 但**只能向前**：静止时长小于一个水位时，新数据之前一个水位处在旧显示时刻之前，
		# 直接赋值会把显示时刻往回移，画面就会倒退（实测表现为开始移动时一次 0.75 m 的反向跳）。
		# 那种情况交给钟速慢慢补即可，本来也在水位以内。
		# 锚定位置还要退到保持点之前：本次补过保持点时，那段位移应有的时长是 resume_span，
		# 若只退一个水位，显示就会从保持段末尾起步，一帧内走完整段位移。
		_render_time = maxf(_render_time, sender_time - maxf(buffer, resume_span))
		if _stall_armed:
			# 卡顿结束，按实际时长抬高补偿。见 STALL_MIN 一带的说明。
			_accumulate_stall()
		_stall_armed = false
		_holding = false
	_trim(sender_time)


## 推进显示并返回本帧应显示的位置。delta 是显示帧的时长（秒）。
## 这是生产路径；position_at() 只做纯查询，供测试与内部使用。
func advance(delta: float) -> Vector3:
	_samples += 1
	if _states.is_empty():
		return Vector3.ZERO
	# 单帧异常不应让显示时钟一次跳很远，见 MAX_FRAME 的说明。
	delta = minf(delta, MAX_FRAME)
	_wall += delta
	# 没有新的卡顿时，补偿应当尽快回到链路基准，即“延迟最小为优先”。
	_decay_stall(delta)
	var newest := _times[_times.size() - 1]
	if _render_time < 0.0:
		# 首次推进：把显示时刻放在最新快照之前一个水位处，立刻就有可插值的区间。
		_render_time = newest - buffer
		_rate = 1.0
		return position_at(_render_time)
	var fill := newest - _render_time
	# 缓冲少则放慢钟速，缓冲多则加快。误差与钟速的换算见 RATE_GAIN。
	_rate = clampf(1.0 + (fill - buffer) * RATE_GAIN, RATE_MIN, RATE_MAX)
	_render_time += delta * _rate
	if _render_time >= newest:
		# 缓冲被追平：没有可插值的区间，只能停在最新快照上等新数据。
		_render_time = newest
		if not _holding:
			_begin_stall()
		_holding = true
		# 只在数据确实还在来的时候才计入"停顿"，见 FLOWING_WINDOW 的说明。
		if _last_unique_wall >= 0.0 and _wall - _last_unique_wall <= FLOWING_WINDOW:
			_holds += 1
	else:
		_holding = false
	return position_at(_render_time)


## 取 target 时刻的位置。落在两个快照之间时线性插值；超出两端时保持端点。
## 不外推的理由：外推会把显示推到真实位置之前，真实快照到达时再被拉回，
## 看起来就是"快速往回一点再继续"（橡皮筋），比"停一下"更难接受。
func position_at(target: float) -> Vector3:
	if _states.is_empty():
		return Vector3.ZERO
	var last := _states.size() - 1
	if target <= _times[0]:
		return _states[0]
	if target >= _times[last]:
		return _states[last]
	var i := last - 1
	while i > 0 and _times[i] > target:
		i -= 1
	var span := _times[i + 1] - _times[i]
	if span <= 0.0:
		# 同一时刻到了两个快照，取更新的那个。
		return _states[i + 1]
	return _states[i].lerp(_states[i + 1], (target - _times[i]) / span)


## 按实测的**最大连续间隔**定水位。用最大而不是分位数：能造成可见停顿的正是最坏的那几次，
## 实测 90 分位 17 ms 而最大 100 ms，按分位数定出的水位必被击穿。
## 只保留最近 GAP_WINDOW 个样本，因此链路变好之后水位会跟着降下来——
## 这正是"延迟还能优化吗"的答案：链路越好，这个值越小，滞后越少。
func _update_buffer() -> void:
	if not adaptive or _gaps.is_empty():
		return
	buffer = clampf(link_floor_seconds() + _stall_penalty, MIN_BUFFER, MAX_BUFFER)


## 由链路实测得出的水位基准（秒）：最近窗口内的最大连续间隔 × 余量，并夹在上下限之间。
## 它是“延迟最小”的那一半：链路一变好，这个值立刻跟着降。
func link_floor_seconds() -> float:
	return clampf(worst_gap() * BUFFER_HEADROOM, MIN_BUFFER, MAX_BUFFER)


## 卡顿补偿（秒）。见 STALL_MIN 一带的说明。
func stall_penalty_seconds() -> float:
	return _stall_penalty


## 一次卡顿开始：记下起点，并判断它是否值得计入补偿。
## 只有“数据仍在流动”时开始的卡顿才算（距上次有新位置不超过 FLOWING_WINDOW）：
## 对端静止时显示必然一直保持，那种保持不是水位不足，这一点在第四轮已经踩过。
func _begin_stall() -> void:
	_stall_armed = adaptive \
		and _unique_count >= STALL_WARMUP \
		and _last_unique_wall >= 0.0 \
		and _wall - _last_unique_wall <= FLOWING_WINDOW
	_stall_start = _wall


## 一次卡顿结束：按时长抬高补偿。时长范围之外的都不计入，理由见 STALL_MIN 的说明。
func _accumulate_stall() -> void:
	var duration := _wall - _stall_start
	if duration < STALL_MIN or duration > STALL_MAX:
		return
	_stall_penalty = maxf(_stall_penalty, minf(duration, STALL_PENALTY_MAX))
	_update_buffer()


## 补偿按半衰期衰减回零。抬高只发生在其正发生卡顿的那一刻，
## 所以反复卡顿会让补偿维持在较高处，而链路正常时会自动回到链路基准。
func _decay_stall(delta: float) -> void:
	if _stall_penalty <= 0.0:
		return
	_stall_penalty *= pow(0.5, delta / STALL_HALF_LIFE)
	if _stall_penalty < 0.0005:
		_stall_penalty = 0.0
	_update_buffer()


## 最近窗口内实测的最大连续间隔（秒），水位就是按它定的。
## 静止时长不参与（见 push 里的说明），因此它反映的是链路抖动而不是角色有没有动。
func worst_gap() -> float:
	var worst := 0.0
	for gap in _gaps:
		worst = maxf(worst, gap)
	return worst


func _trim(newest: float) -> void:
	# 显示时刻只会前进（除重新锚定之外），因此比它更早一个水位的快照已经没有机会被用到。
	var cutoff := newest - buffer * 2.0
	if _render_time >= 0.0:
		cutoff = minf(cutoff, _render_time - buffer)
	while _times.size() > 2 and _times[0] < cutoff:
		_times.remove_at(0)
		_states.remove_at(0)
	while _times.size() > MAX_STATES:
		_times.remove_at(0)
		_states.remove_at(0)


# ---------------------------------------------------------------- 查询与诊断

func buffer_seconds() -> float:
	return buffer


## 当前显示时刻落后最新快照多少秒。健康时应接近水位。
func fill_seconds() -> float:
	if _states.is_empty() or _render_time < 0.0:
		return 0.0
	return _times[_times.size() - 1] - _render_time


func rate() -> float:
	return _rate


func is_holding() -> bool:
	return _holding


## 距离上次收到"位置有变化"的快照过了多久（秒）。用于诊断卡顿。
func seconds_since_unique() -> float:
	if _last_unique_wall < 0.0:
		return 0.0
	return _wall - _last_unique_wall


func has_state() -> bool:
	return not _states.is_empty()


## 取统计并清零。duplicated 是"位置与上一份相同"的快照数；
## holds 是"缓冲被追平、只能等新数据"的帧数——它直接对应人看到的"卡一下"。
## 只返回派生出的比例，不返回原始计数：调用方没有需要它们的地方。
func sample_stats() -> Dictionary:
	var stats := {
		"hold_ratio": float(_holds) / float(_samples) if _samples > 0 else 0.0,
		"duplicated_ratio": float(_duplicated) / float(_pushed) if _pushed > 0 else 0.0,
		"buffer": buffer,
		"fill": fill_seconds(),
		"rate": _rate,
	}
	_samples = 0
	_holds = 0
	_pushed = 0
	_duplicated = 0
	return stats


func reset() -> void:
	_times.clear()
	_states.clear()
	_gaps.clear()
	_speed = 0.0
	_stall_penalty = 0.0
	_stall_start = -1.0
	_stall_armed = false
	_unique_count = 0
	_last_unique_time = -1.0
	_render_time = -1.0
	_wall = 0.0
	_last_unique_wall = -1.0
	_last_arrival_wall = -1.0
	_holding = false
	_rate = 1.0
	buffer = DEFAULT_BUFFER


## 与 reset() 同义。保留 clear() 这个名字，以免调用方为此改动。
func clear() -> void:
	reset()
