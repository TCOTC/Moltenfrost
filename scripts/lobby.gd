class_name Lobby
extends CanvasLayer
## 等待房间。创建或加入之后停在这里，**人齐之后由房主开始**。
##
## 为什么需要单独一屏，而不是开局之后再说：需求是"匹配到玩家之后才允许点击开始游戏"。
## 要让房主能判断该不该按下去，就必须有一个地方显示"现在有谁"。
## 没有它的话，这个判断只能靠猜（"对方大概进来了吧"）。
##
## 它与 scripts/menu.gd 分开、而不是共用一块面板，理由是两者管的事不同：
##   菜单   —— 加入**之前**：房间列表、探测、手动填地址。回答"我要进哪一局"。
##   大厅   —— 加入**之后**：这一局现在有谁、什么时候开始。回答"这一局现在怎么样"。
## 混在一屏里会让"加入前"与"加入后"长得一样，玩家会分不清自己站在哪一边；
## 而这两件事的下一步动作也完全不同（再选一个房间 vs 等房主开始）。
##
## 它只做两件事：把服务端给的名单画出来，把两个动作转发成信号。
## 会话是入口脚本（scripts/main.gd）的事——只有它知道本机是主机还是加入方。
##
## 名单**由服务端下发**而不是各端自己数 peer：各端都能从 multiplayer.get_peers()
## 推出个数，但推不出槽位与元素，而大厅要显示"谁是熔、谁是霜"。
## 服务端是槽位的分配者，因此由它给出唯一那份名单，各端显示的内容不会互相矛盾。

signal start_requested()
signal leave_requested()

## 房间的公开类型。界面与入口脚本共用这一份定义，避免各自写一个字符串字面量
##（那种做法的问题是改一处忘一处，而两处不一致时界面会显示成另一个类型）。
enum Kind {
	LAN, ## 局域网创建：本机就是主机，同一网段的人在列表里能看到这个房间。
	PUBLIC, ## 公网创建：房间开在官方服务器上（服务端支持见 docs/公网房间方案.md）。
}

## 开局需要的最少人数。双人协作，因此 2 是硬下限：
## 一个人进去只有一个角色，而这一关的许多机关要求两个角色同时在场。
const MIN_PLAYERS := 2

@onready var _room_name: Label = $Root/Layout/Header/RoomName
@onready var _kind: Label = $Root/Layout/Body/InfoPanel/InfoMargin/InfoBox/Kind
@onready var _address: Label = $Root/Layout/Body/InfoPanel/InfoMargin/InfoBox/Address
@onready var _start_hint: Label = $Root/Layout/Body/InfoPanel/InfoMargin/InfoBox/StartHint
@onready var _count: Label = $Root/Layout/Body/PlayersPanel/PlayersMargin/PlayersBox/Count
@onready var _players: VBoxContainer = $Root/Layout/Body/PlayersPanel/PlayersMargin/PlayersBox/Players
@onready var _start: Button = $Root/Layout/Footer/Buttons/Start
@onready var _leave: Button = $Root/Layout/Footer/Buttons/Leave
@onready var _status: Label = $Root/Layout/Footer/Status

## 本机是不是房主。**从名单里推出来**，而不是自己去问「本机是不是服务端」。
## 两个理由：
##   1. 公网房间跑在专用服务端上，peer 1 是无头进程、不是玩家，那个判据在那边
##      会让按钮永远是灰的（见 scripts/main.gd 的 host_id）。
##   2. 这里**不能引用 Net**：--script 模式不注册自动加载单例，引用它会以
##      「Identifier not found: Net」编译失败，而 menu.gd 引用了本文件，
##      于是连初始界面的接线测试都跑不起来（仓库里记过这个坑）。
##      名单里的 you 与 host 已经够用：两者同时为真就是本机是房主。
var _is_host := false
var _player_count := 0
## 一条临时说明（例如"对方已断开"）。非空时它压过按名单推出来的那句小结，
## 因为它说的是"刚刚发生了什么"，比"现在是什么"更紧急。
## 名单一变就把它清掉：那时场面确实动过，那条"刚刚"已经过期了。
var _notice := ""


func _ready() -> void:
	visible = false
	# 主题与菜单、HUD 是同一份（scripts/ui/game_theme.gd），
	# 因此三块界面上的配色与控件形状天然一致，不会出现"大厅是新的、菜单还是旧的"。
	$Root.theme = GameTheme.build()
	GameTheme.apply_primary(_start)
	_start.pressed.connect(_on_start_pressed)
	_leave.pressed.connect(func() -> void: leave_requested.emit())
	# 开局之前这一格是空的，先给一句说明占位，避免面板在名单到达之前看起来是坏的。
	_notice = "正在等待房间信息…"
	_set_status(_notice)


## 类型名。同时被菜单（选项文本）与大厅（显示）用到，因此只有这一处定义。
static func kind_name(kind: int) -> String:
	return "公网" if kind == Kind.PUBLIC else "局域网"


## 打开大厅。名单还没到，因此房主是谁、有几个人都要等 apply() 才知道。
func open() -> void:
	visible = true
	_clear_rows()
	_player_count = 0
	_is_host = false
	# 名单要等主机下发（槽位与元素只有服务端分得出来），这句占位让面板在那之前不是空的。
	_notice = "正在等待房间信息…"
	_refresh()


func close() -> void:
	visible = false


## 用服务端下发的房间信息刷新整屏。各端收到的内容相同，但是**you 是各端自己补的**
##（见 main.gd 的 _with_local_flags），因此房主这一判断在各端会得出各自的答案。
## 形状：{name: String, kind: int, address: String, host_id: int, players: Array[Dictionary]}
## 每个玩家项：{id: int, slot: int, element: int, host: bool, you: bool}
func apply(info: Dictionary) -> void:
	_room_name.text = String(info.get("name", "未命名房间"))
	_kind.text = "类型 · %s" % kind_name(int(info.get("kind", Kind.LAN)))
	var address := String(info.get("address", ""))
	# 空地址时给一个短横而不是空字符串：空着会看起来像"还没加载完"，
	# 而它实际是"这次拿不到对外地址"（例如端口由系统分配）。
	_address.text = address if not address.is_empty() else "—"
	_clear_rows()
	var entries: Array = info.get("players", [])
	_is_host = false
	for entry in entries:
		if entry is Dictionary:
			_add_row(entry)
			if bool((entry as Dictionary).get("you", false)) and bool((entry as Dictionary).get("host", false)):
				_is_host = true
	_player_count = entries.size()
	_count.text = "在场 %d 人" % _player_count
	# 名单变了就把临时说明清掉，让位给按新名单推出来的小结。
	_notice = ""
	_refresh()


## 显示一条临时说明（例如"对方已断开"）。不改变名单本身，
## 但会在下一次名单变动时被小结替掉。
func set_message(text: String) -> void:
	_notice = text
	_set_status(text)


# ---------------------------------------------------------------- 名单

## 一行一个人：左侧一条元素色竖条，中间是"你 · 熔"这样的名字，右侧标房主。
## 元素色取自 Element.kind_color()，与关卡里角色的胸章同色——
## 在大厅里学到的"橙是熔、蓝是霜"，进入关卡后要能直接接上。
func _add_row(entry: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var bar := ColorRect.new()
	bar.custom_minimum_size = Vector2(6, 30)
	bar.color = Element.kind_color(int(entry.get("element", Element.Kind.MOLTEN)))
	row.add_child(bar)

	var who := Label.new()
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.text = _row_label(entry)
	who.add_theme_color_override("font_color", GameTheme.TEXT)
	row.add_child(who)

	var role := Label.new()
	role.text = "房主" if bool(entry.get("host", false)) else ""
	role.add_theme_color_override("font_color", GameTheme.TEXT_DIM)
	role.add_theme_font_size_override("font_size", GameTheme.FONT_LABEL)
	row.add_child(role)

	_players.add_child(row)


## 一行的文案。`you` 由各端自己判断（见 main.gd），因此这里只负责显示。
## 没有本机名字这种东西——两人的身份靠"你"与 peer 号区分就够了，
## 让玩家输名字会多一个只有两个人才用的输入框。
func _row_label(entry: Dictionary) -> String:
	var element := Element.kind_name(int(entry.get("element", Element.Kind.MOLTEN)))
	if bool(entry.get("you", false)):
		return "你 · %s" % element
	return "玩家 %d · %s" % [int(entry.get("id", 0)), element]


func _clear_rows() -> void:
	for child in _players.get_children():
		child.queue_free()


# ---------------------------------------------------------------- 按钮状态

func _refresh() -> void:
	var enough := _player_count >= MIN_PLAYERS
	if not _is_host:
		# 非房主不留一个"能点但是点了没用"的按钮。灰按钮会让人反复去点，
		# 而文字能一次说清为什么点不了。
		_start.disabled = true
		_start.text = "等待房主开始"
	else:
		_start.disabled = not enough
		_start.text = "开始游戏" if enough else "开始游戏（还差 %d 人）" % (MIN_PLAYERS - _player_count)
	_start_hint.text = _hint_text(enough, _is_host)
	_set_status(_notice if not _notice.is_empty() else _summary(_is_host))


## 按当前名单推出来的那句小结。与 _hint_text 分开：
## 那一句说的是"按钮为什么能点/不能点"（常驻在按钮上方），
## 这一句说的是"现在是什么情况"（在底部的状态行），两者受众位置不同。
func _summary(is_host: bool) -> String:
	if not is_host:
		return "已进入房间，等房主点「开始游戏」。"
	if _player_count >= MIN_PLAYERS:
		return "可以开始了。也可以再等一会儿，看看还有没有人进来。"
	return "等待对方加入。这个房间已经在局域网里广播过了，对方打开游戏就能在列表里看到它。"


func _hint_text(enough: bool, is_host: bool) -> String:
	if not is_host:
		return "已经进入房间，等房主点「开始游戏」。"
	if enough:
		return "人齐了，点下面的「开始游戏」进入关卡。也可以等一会儿，让更多人加入。"
	return "还差 %d 人。对方在同一个局域网里打开游戏，这个房间会出现在「加入一局」的列表里；\n也可以把上面的地址直接告诉他。" % (MIN_PLAYERS - _player_count)


func _on_start_pressed() -> void:
	# 双保险：按钮已经是灰的，但键盘/快捷键仍可能触发 pressed。
	# 开局是不可逆的动作，值得在这里再判一次。
	if _player_count < MIN_PLAYERS:
		_set_status("至少要 %d 个人才能开始。" % MIN_PLAYERS)
		return
	start_requested.emit()


func _set_status(text: String) -> void:
	_status.text = text
