# Moltenfrost · 项目上下文

《熔霜》—— 2D 横版双人元素协同解谜。桌面端专用，双人是**多台设备联机**，不做单机同屏。
完整决策依据在 `docs/`，本文件只保留"动手前不知道就会白干"的部分。

## 关于本文件

- **保持简洁。** 加内容前先问：不知道这条，会不会白干半天？不会的就不写在这里。
- **需要记住的具体内容放 `memory/`**，本文件最多留一句指路，不要把细节堆进来。
- 决策与理由写 `docs/`；机制与坑写代码注释里（就近）；这里只写结论。
- **`memory/` 由 AI 自行维护**：记什么、记在哪一个文件、什么时候更新，都由 AI 判断后直接写入，**不需要人指定或确认**。人只需在发现某条不对时说改哪一条。

## 环境

- Godot 4.7.2：`D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe`
- 目标平台：Windows（x86_64）与 macOS（产物是 Universal 2，但**只支持 Apple Silicon**）；不做网页版与移动端
- 导出模板：`node tools/setup-dev-env.mjs --check` 看是否齐全，缺了就跑一次同名命令（不带 `--check`）
- 工程内的距离与速度单位是**像素**，关卡以 64 px 为一方格（3D 版的“米”已废弃）。不要引入米与像素的换算层：多一层就多一次漏乘，而漏乘的后果是跳跃高度差几十倍。
- 手感数值（水平速度、起跳初速、重力）是 `scripts/player.gd` 里的三个 `static var`，可用 `--move-speed` / `--jump-velocity` / `--gravity` 临时覆盖以便扫参；启动日志的 `[feel]` 行给出生效值与推出的跳跃高度与滞空。那一行是**解析值，实测高约一成**（半隐式欧拉），**关卡沟宽要按实测值算**。

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
| `docs/` | 决策与依据（设计文档、命名与合规调研） |
| `memory/` | 长期笔记，由 AI 自行维护，按主题一个文件 |
| `scripts/`、`scenes/` | 代码与场景 |
| `tools/` | 开发工具，必须跨平台，优先 Node 单实现 |
| `build/` | 导出产物，不入库 |

## 交付前自检

```powershell
& 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --headless --path 'D:\CodeProjects\Moltenfrost' --quit-after 3 -- --port 0
node tools/net-smoke.mjs
```

控制台无脚本错误再交给人试玩。动了联机相关代码则两条都跑，第二条无头起一个服务端与一个客户端，核对连接、角色生成与插值取样。`--port 0` 让系统分配空闲端口：不带参数时会监听 27015，那个端口平时开着开发实例就占用了，自检会以"无法监听"的报错形式失败。手感、音量、数值这类偏好由人判断，不要替人定。
