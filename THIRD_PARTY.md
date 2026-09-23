# 第三方依赖台账

> 对应《熔霜-游戏设计文档》4.2 第 2 条：每引入一个第三方库，登记名称、版本、许可、来源链接与是否改动过。
> 许可文本原件存放于 `LICENSES/` 目录，文件名格式为 `<库名>-<许可>.txt`。
> 入站许可准入规则：MIT / BSD / Apache-2.0 / Zlib / CC0 / Unlicense 可用；LGPL 谨慎；GPL / AGPL 禁用；CC-BY-NC* 仅原型期可用。

## 一、当前状态

本仓库已引入第三方**素材**（见第四节），但没有引入任何第三方**代码库**。
`LICENSES/` 目录尚未建立——素材全部是 CC0，不要求随产物分发许可文本，但下列登记仍保留来源以备核查。
下表中 Godot 条目属于规划记录，用于说明许可来源；引擎本体不随本仓库分发。

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

---

## 五、已引入的第三方素材（2026-09-24）

全部为 **CC0 1.0（公共领域贡献）**：可商用、可修改、**无需署名**。
仍逐条登记来源，目的是将来要换素材或核查权属时有据可查。
下载清单与脚本：`tools/fetch-assets.mjs`（重跑即可重建 `assets/`，合计约 8 MiB）。

| 素材 | 类型 | 许可 | 来源 | 用途 | 是否改动 |
|---|---|---|---|---|---|
| `MetalPlates006` | PBR 贴图（反照率/法线/粗糙度/金属度） | CC0 1.0 | ambientCG，https://ambientcg.com/view?id=MetalPlates006 | 地板与金属槽件 | 否（仅重命名为小写短名） |
| `Metal032` | 同上 | CC0 1.0 | ambientCG，https://ambientcg.com/view?id=Metal032 | 墙面、柱、门框 | 否（同上） |
| `CorrugatedSteel009` | 同上（含环境光遮蔽） | CC0 1.0 | ambientCG，https://ambientcg.com/view?id=CorrugatedSteel009 | 天花板与结构 | 否（同上） |
| `Metal006` | 同上 | CC0 1.0 | ambientCG，https://ambientcg.com/view?id=Metal006 | 角色装甲与武器 | 否（同上） |
| `abandoned_workshop` | 环境贴图（1K HDR） | CC0 1.0 | Poly Haven，https://polyhaven.com/a/abandoned_workshop | 环境反射与间接光 | 否 |

### 已试过但排除的素材（避免以后再查一遍）

| 素材 | 排除原因 |
|---|---|
| `Metal034` | 实测平均色 (0.893, 0.693, 0.030)，是黄铜色，与冷色科幻相背 |
| `Metal035` | 实测平均色 (0.684, 0.445, 0.226)，是紫铜色，同上 |

两张已从 `assets/` 删除。选素材前先量色：`node tools/fetch-assets.mjs --try <id>` 下载后执行
`<godot> --headless --path . --script tools/texture-probe.gd` 打印平均色与亮度。

### 素材选用时记下的几条

- 贴图只取 1K：本工程是桌面端第一人称，相机离墙面 1～8 米，1K 在这些距离上看不出像素级差异，
  而体积只有 2K 的四分之一。要提清晰度时改 `tools/fetch-assets.mjs` 的 `ATTRIBUTE` 一处。
- **贴图必须量色再选**。名字里的“Metal”不保证是中性金属；黄铜与紫铜在冷色调场景里一眼就能看出不对，
  而单看缩略图是看不出来的（实测两次踩中）。
- 颜色以**乘数**形式作用在贴图上（`Palette.TINT_*`），所以选素材时要看平均色与线性亮度，
  而不是看它“好不好看”。
