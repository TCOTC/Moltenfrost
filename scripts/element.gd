class_name Element
extends RefCounted
## 角色与机关的元素属性，以及各元素的显示信息。
##
## 单独成一个文件的原因：元素这个标识被角色、地形与机关三处共用，而这三种脚本互不引用。
## 放在这里，任一处都能单独取用，不必为了一个枚举去引用另一处的实现。
##
## 「熔」与「霜」既是角色名，也是属性名（见 docs/熔霜-游戏设计文档.md 2.2 与 3.1）。
## 原型期只有这两种元素与三种反应中的一种（熔 + 霜），多元素反应网络是第 3 阶段的内容。

enum Kind {
	MOLTEN, ## 熔。火属性。怕水。
	FROST, ## 霜。水属性。怕岩浆。
}

## 日志与界面里的显示名。
const LABELS := {
	Kind.MOLTEN: "熔",
	Kind.FROST: "霜",
}

## 原型期用来分辨角色与地形的颜色。正式的角色美术与元素表现另做。
const COLORS := {
	Kind.MOLTEN: Color(1.0, 0.42, 0.12),
	Kind.FROST: Color(0.36, 0.82, 0.98),
}


static func label(kind: int) -> String:
	return LABELS.get(kind, "未知元素")


static func color(kind: int) -> Color:
	return COLORS.get(kind, Color.MAGENTA)
