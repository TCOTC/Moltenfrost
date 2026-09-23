# 第三方依赖台账

> 对应《熔霜-游戏设计文档》4.2 第 2 条：每引入一个第三方库，登记名称、版本、许可、来源链接与是否改动过。
> 许可文本原件存放于 `LICENSES/` 目录，文件名格式为 `<库名>-<许可>.txt`。
> 入站许可准入规则：MIT / BSD / Apache-2.0 / Zlib / CC0 / Unlicense 可用；LGPL 谨慎；GPL / AGPL 禁用；CC-BY-NC* 仅原型期可用。

## 一、当前状态

仓库内尚未引入任何第三方库，`LICENSES/` 目录尚未建立。下表中的引擎条目属于规划记录，用于说明许可来源；引擎本体不随本仓库分发。

## 二、登记表

| 名称 | 版本 | 许可 | 来源链接 | 是否改动 | 引入阶段 | 状态 |
|---|---|---|---|---|---|---|
| Godot Engine | 4.7.x | MIT | https://github.com/godotengine/godot | 否 | 引擎（不随仓库分发） | 规划中 |

## 三、待登记（按设计文档 4.3）

引入时逐条补入上表，并同时存放许可文本原件。

| 库 | 用途 | 许可 | 引入阶段 |
|---|---|---|---|
| `ramokz/phantom-camera` | 3D 相机机位与切换 | MIT | 第 2 阶段 |
| `derkork/godot-statecharts` | 角色与机关状态图 | MIT | 第 2 阶段 |
| `Ark2000/PankuConsole` | 运行时调试面板 | MIT | 第 2 阶段 |
| `Maaack/Godot-Menus-Template` | 菜单与输入重绑定界面 | MIT | 第 2 阶段，按需 |
| `bitbrain/beehave` | AI 同伴行为树 | MIT | 第 3 阶段 |
| `OctoD/godot-gameplay-systems` | 属性、技能与能力系统 | MIT | 第 3 阶段 |
| `foxssake/netfox` | 联机状态同步与延迟补偿 | MIT | 第 3 阶段 |
| `foxssake/noray` | 公网联机连接编排与中继 | MIT | 第 3 阶段及以后 |
| `shomykohai/quest-system` | 任务系统 | MIT | 第 4 阶段 |
| `nathanhoad/godot_dialogue_manager` | 对话与叙事 | MIT | 第 4 阶段，按需 |

## 四、登记时需要一并核对的项

代码许可与素材许可分开核查。插件自带的字体、图标、音效与示例工程美术往往另有许可，例如 GDQuest 的 TPS Demo 代码是 MIT，美术是 CC-BY-NC-SA，该项目已列入排除清单。

导出产物内的许可文本归集：Godot 导出的可执行文件已自动包含引擎许可，第三方插件与素材的许可文本需自行加入游戏的致谢或授权页面。
