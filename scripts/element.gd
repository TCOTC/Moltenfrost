class_name Element
extends RefCounted
## 元素与介质的规则表。
##
## 本作所有玩法上的不对称都从这张表来：熔与水、霜与岩浆是两对致命关系，
## 其余组合都是通行。规则整理见 docs/机制与玩法设计.md 的 2.1（双角色属性）与
## 3.1（交互矩阵）。
##
## 单独成一个文件、而不是写成 Player 里的一个枚举，是为了让三处引用同一份定义：
## 关卡（Hazard 的 medium、Solid 的 meltable）、角色（Player.element）、
## 外壳（HUD 与菜单显示"你是什么"）。把"哪种介质对谁是致命的"抄成第二份，
## 就一定会有两处不一致的那一天，而那种不一致在本作里等价于随机暴毙。

enum Kind { MOLTEN, FROST }
enum Medium { LAVA, WATER }

## 角色色。取色标准是"在对方的介质上也要看得见"：熔的橙红放进岩浆里已经分不开，
## 因此角色的主体色比介质亮、并靠形状区分（见 CharacterArt 的说明）。
const MOLTEN_COLOR := Color(1.0, 0.45, 0.13)
const FROST_COLOR := Color(0.42, 0.84, 0.99)
## 介质色。岩浆偏暗红、水偏暗蓝，两者都比角色暗，角色站在里面时不会糊成一片。
const LAVA_COLOR := Color(0.72, 0.17, 0.05)
const WATER_COLOR := Color(0.11, 0.34, 0.68)


static func kind_name(kind: int) -> String:
	match kind:
		Kind.MOLTEN:
			return "熔"
		Kind.FROST:
			return "霜"
	return "?"


static func kind_color(kind: int) -> Color:
	match kind:
		Kind.MOLTEN:
			return MOLTEN_COLOR
		Kind.FROST:
			return FROST_COLOR
	return Color.WHITE


static func medium_name(medium: int) -> String:
	match medium:
		Medium.LAVA:
			return "岩浆"
		Medium.WATER:
			return "水"
	return "?"


static func medium_color(medium: int) -> Color:
	match medium:
		Medium.LAVA:
			return LAVA_COLOR
		Medium.WATER:
			return WATER_COLOR
	return Color.WHITE


static func other(kind: int) -> int:
	return Kind.FROST if kind == Kind.MOLTEN else Kind.MOLTEN


## 这个元素在这种介质里会不会死。只有两对是致命的，其余一律通行——
## 这正是"熔可以在岩浆里走、霜可以在水里走"的完整表述。
static func is_lethal(kind: int, medium: int) -> bool:
	return (kind == Kind.MOLTEN and medium == Medium.WATER) \
		or (kind == Kind.FROST and medium == Medium.LAVA)


## 这个元素能不能把冰块化掉。目前只有熔能，写成函数是为了让"谁能融冰"
## 只在这个文件里出现一次，关卡的 meltable 与技能判定都问它。
static func melts(kind: int) -> bool:
	return kind == Kind.MOLTEN


## 解析命令行与存档里的元素名。认不出来时返回 -1，由调用方决定回退。
static func parse(text: String) -> int:
	match text.strip_edges().to_lower():
		"molten", "fire", "熔", "火":
			return Kind.MOLTEN
		"frost", "ice", "霜", "冰":
			return Kind.FROST
	return -1
