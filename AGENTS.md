# Moltenfrost · 项目上下文

《熔霜》—— 2D 横版双人元素协同解谜。桌面端专用，双人是**多台设备联机**，不做单机同屏。
完整决策依据在 `docs/`，本文件只保留"动手前不知道就会白干"的部分。

## 关于本文件

- **保持简洁。** 加内容前先问：不知道这条，会不会白干半天？不会的就不写在这里。
- **需要记住的具体内容放 `memory/`**，本文件最多留一句指路，不要把细节堆进来。
- 决策与理由写 `docs/`；机制与坑写代码注释里（就近）；这里只写结论。
- **`memory/` 由 AI 自行维护**：记什么、记在哪一个文件、什么时候更新，都由 AI 判断后直接写入，**不需要人指定或确认**。人只需在发现某条不对时说改哪一条。

## 分支

直接在 **`main`** 上提交，不另开功能分支。`main` 就是 2D 横版这条线。
仓库里另有 `feature/element-coop-mechanics`（已停用的 3D 第一人称线）与 `backup/pre-squash`（本地备份），
详情见 `memory/git-workflow.md`。

## 环境

- Godot 4.7.2。**本机绝对路径不要写进本仓库**：盘符与目录每个人都不同，写进来的人只觉得"本来就是这样"，
  别人 clone 下来则是错的。取值顺序固定为 `GODOT_BIN` 环境变量 → `memory/local-env.json` → 自动探测，
  首次探测成功会自动记进 `memory/local-env.json`（不入库），所以每台机器只需成功探测一次；
  `node tools/setup-dev-env.mjs --print-godot` 只打印最终用到的那一份。怎么记、记在哪见 `memory/README.md`。
- 目标平台：Windows（x86_64）与 macOS（产物是 Universal 2，但**只支持 Apple Silicon**）；不做网页版与移动端
- 导出模板：`node tools/setup-dev-env.mjs --check` 看是否齐全，缺了就跑一次同名命令（不带 `--check`）
- 工程内的距离与速度单位是**像素**，关卡以 64 px 为一方格（3D 版的“米”已废弃）。不要引入米与像素的换算层：多一层就多一次漏乘，而漏乘的后果是跳跃高度差几十倍。
- 手感数值（水平速度、起跳初速、重力）是 `scripts/player.gd` 里的三个 `static var`，可用 `--move-speed` / `--jump-velocity` / `--gravity` 临时覆盖以便扫参；启动日志的 `[feel]` 行给出生效值与推出的跳跃高度与滞空。那一行是**解析值，实测高约一成**（半隐式欧拉），**关卡沟宽要按实测值算**。
- 关卡尺寸是从这几个数值**推出来**的，不是美术选择：沟宽必须大于一个跳跃的水平跨度（否则对方一步就跳过去，机制失效），池深必须小于跳跃高度（否则熔掉进岩浆爬不出来）。第一关的三个数写在 `docs/机制与玩法设计.md` 附录 B，改手感数值就要重算。

## 两台机器各导自己的平台

- Windows 机器只导 Windows，Mac 机器只导 macOS。`node tools/setup-dev-env.mjs` 默认只装本机平台的模板，要装另一份得显式传 `--platforms`。
- **`export_presets.cfg` 里的两个预设都不要删**，`build/windows` 与 `build/macos` 两个目录也都保留：各机器只是不用对方那一份，删掉会让这个文件在两台机器上分叉，每次同步都冲突。
- 两边的产物都从**同一个 commit** 构建，否则两个版本会悄悄不一致。
- macOS 的签名与公证只能在 Mac 上做（Xcode 的 codesign 与 notarytool），所以"导出 → 签名 → 打包"这条链整体留在 Mac。

## 五条硬约束

1. **渲染器用 Forward+**（桌面专用，2D 场景同样走它），不要引入按平台分流的兼容处理。
2. **2D 侧没有第二套物理后端**：`physics/2d/physics_engine` 只有 `GodotPhysics2D`（外加关闭物理的 `Dummy`），Jolt 只服务 3D，因此原“必须显式选 Jolt”这条只对 3D 成立。代价是堆叠与旋转平台的求解稳定性弱于 Jolt，依赖堆叠的关卡要先做原型验证。
3. **联机是多台设备**：ENet 主机/加入者模式；不做单机同屏，因此不需要处理"两人共用一套输入与一台相机"。
4. **开发期窗口化靠特性标签覆盖**：`project.godot` 里 `window/size/mode=3`（全屏）配 `window/size/mode.editor=0`（开发窗口）。读这个设置要用 `ProjectSettings.get_setting_with_override()`，普通 `get_setting()` 拿不到覆盖值；不要写死全屏。
5. **第三方库许可**：MIT / BSD / Apache-2.0 / Zlib / CC0 / Unlicense 可用；LGPL 谨慎；GPL / AGPL 禁用；CC-BY-NC* 只能用于原型期。引入时登记到 `THIRD_PARTY.md`。

## 不要往引擎会重写的文件里写注释

`project.godot`、`export_presets.cfg`、`*.tscn`、`*.tres` 都是 Godot 序列化生成的：编辑器保存时整份重写，手写注释必丢，等于默认值的设置也会被删。说明写到使用点的代码里（例如 `scripts/main.gd` 顶部的说明）或 `docs/`。细节见 `memory/godot-notes.md`。

## 目录

| 路径 | 放什么 |
|---|---|
| `config/` | 可变量：官方服务器地址与目录端口这类随部署变化的产品常量 |
| `docs/` | 决策与依据（设计文档、命名与合规调研、服务端部署） |
| `memory/` | 长期笔记，由 AI 自行维护，按主题一个文件；本机环境记录 `local-env.json` 也在这（不入库） |
| `scripts/`、`scenes/` | 代码与场景。关卡在 `scenes/levels/`，一个关卡一个场景；对局的规则层在 `scripts/game/`，关卡组件在 `scripts/level/` |
| `tools/` | 开发工具，必须跨平台，优先 Node 单实现 |
| `build/` | 导出产物，不入库 |

`config/` 下的普通文本**不是 Godot 的“资源”**，导出时不会被 `all_resources` 自动带上：
新增这类文件要同步加进两个预设的 `include_filter`，否则编辑器里一切正常而导出产物读不到
（已实测，见 `memory/godot-notes.md`；`tools/pck-find.mjs` 可直接查产物里有没有）。

## 交付前自检

```powershell
$godot = node tools/setup-dev-env.mjs --print-godot   # 路径来自 memory/local-env.json，见上「环境」
& $godot --headless --path . --quit-after 3 -- --port 0
node tools/net-smoke.mjs
```

在仓库根执行。控制台无脚本错误再交给人试玩。动了联机相关代码则两条都跑，第二条无头起一个服务端与一个客户端，核对连接、角色生成与插值取样，并顺带跑关卡判定几何与一关的规则（`tests/level_test.gd`、`tests/game_test.tscn`）；它还会跑一遍**大厅流程**（本地开房 + 两个无头驱动）与**房间目录的协议自检**。`--port 0` 让系统分配空闲端口：不带参数时会监听 27015，那个端口平时开着开发实例就占用了，自检会以"无法监听"的报错形式失败。手感、音量、数值这类偏好由人判断，不要替人定。

**动了房间池（`tools/room-pool.py`）或目录的可见性规则**再加跑一条：它起一个真目录、真池与真房间，验"打开界面看不到空房 → 创建一间之后别人才看得到 → 人走光又消失"这条完整生命周期。

```powershell
node tools/pool-check.mjs
```

**动了「创建公网房间」那条路径**（认领）再跑一条：它起一个真目录，再让真客户端**先起一个列表请求、紧接着认领**——这条覆盖的是"请求真的发出去了、回信真的到了"，而替身把这层跳过了（真机上就是在那里卡死的）。

```powershell
node tools/directory-client-check.mjs
```

**服务器上多一层东西**（目录 + 房间池，见 `docs/服务端部署.md`）时，端到端验收是另一条：

```bash
bash tools/directory-check.sh          # 在服务器本机跑
node tools/check-server.mjs --host <ssh别名> --advertise <域名>   # 从本机跑（含公网连接与优雅停止）
```

前者验：目录活着、**公开列表里没有任何空房**、能认领到一间、认领之后就出现在列表里、
两人直连同一房间端口、先到的当房主、房主改名与 `playing` 状态传到目录、人齐开局且各看到
2 个角色、人走光后从公开列表消失且池收敛回只剩备用。
"本地全绿但公网连不上"先查**安全组**：游戏要 `TCP:27017`（目录）**与**
`UDP:40001-40020`（房间）**两条**，缺一个都是同一个现象。
界面与关卡外观没有自动检查（截图脚本 `tests/shot.tscn` 只供人工看一眼），改动之后要自己跑一次截图核对。
