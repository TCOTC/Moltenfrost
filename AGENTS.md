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

## 自检：分三层用，别一上来就跑全套

```powershell
node tools/dev-check.mjs --only syntax   #  0.8s  改完 .gd 的第一件事
node tools/dev-check.mjs                 #   10s  快层：语法 + 六个纯逻辑检查
node tools/dev-check.mjs --full          #   70s  全套：再加联机冒烟、房间池、目录客户端
node tools/dev-check.mjs --list          #         看有哪些项、各属哪一层
```

| 场景 | 跑什么 | 耗时 |
| --- | --- | --- |
| 改完一个 `.gd` | `--only syntax`（脚本能不能解析） | 1 秒 |
| 改了一批，还没提交 | 快层（默认） | 10 秒 |
| 动了联机 / 房间池 / 目录 / 认领 | 全套 `--full` | 70 秒 |
| 交给人试玩之前 | 全套 + 下面「服务器侧」两条 | 70 秒 + 8 秒 |
| 只改了注释或文档 | `--only syntax` 就够 | 1 秒 |

**这三档必须分开用。** 实测一次 319 分钟的对话：**95% 的工具耗时在终端上**，其中大部分是
反复跑全套——而全套里贵的那几项（联机冒烟 46 秒、房间池 11 秒、服务器上那条 8 秒）
有大量**设计出来的等待**（起无头实例、等一局跑完、DNS、公网 RTT）。改一行注释之后跑它是纯亏。
"改一行就全量回归"看起来稳妥，实际是把改动批量化的动力也一起掐掉了。

**服务器侧的两条**（要 SSH，因此在上面三层之外）：

```bash
ssh <别名> 'cd ~/moltenfrost && bash tools/directory-check.sh'   # 8 秒，七条断言
node tools/check-server.mjs --host <ssh别名> --advertise <域名>   # 公网，含认领与优雅停止
```

前者验：目录活着、**公开列表里没有任何空房**、能认领到一间、认领之后就出现在列表里、
两人直连同一房间端口、先到的当房主、房主改名与 `playing` 状态传到目录、人齐开局且各看到
2 个角色、人走光后从公开列表消失且池**收缩回只剩备用那一间**。
"本地全绿但公网连不上"先查**安全组**：游戏要 `TCP:27017`（目录）**与**
`UDP:40001-40020`（房间）**两条**，缺一个都是同一个现象。
界面与关卡外观没有自动检查（截图脚本 `tests/shot.tscn` 只供人工看一眼），改动之后要自己跑一次截图核对。
手感、音量、数值这类偏好由人判断，不要替人定。

## 让它保持快：四条硬规则

1. **判定行只用 ASCII。** 所有自检的结论行是 `ok` / `FAIL` / `ALL PASS (N checks)`，
   **不含中文**——因为中文经 PowerShell 管道会变成乱码，而"跑完看不出结论 → 换一种读法
   再跑一遍"实测浪费过两次 110 秒。读结论就用
   `| Select-String 'ok |FAIL|ALL PASS'`，它不受编码影响；要细看细节再写文件 + `-Encoding Unicode`。
2. **不要直接用 PowerShell 跑 `godot`。** 输出会乱码。要跑就加进 `tools/dev-check.mjs`
   （它用 Node 收 stdout，因此永远是可读的），或者临时经 Node 包一层。
   同理，**别用 `>` 把 `node` 的输出存成文件再读**：PowerShell 会按 GBK 解码子进程的 UTF-8，
   存下去的就是坏内容，读不回来（实测为此白跑三轮）。要存就先
   `[Console]::OutputEncoding=[Text.Encoding]::UTF8`，再 `| Out-File -Encoding utf8`，
   读的时候用 Node 而不是 `Get-Content`；检索只用 ASCII 标记。
3. **改动攒一批再跑，别改一行跑一次。** 快层 10 秒 / 全套 70 秒 / 服务器那条 8 秒，
   三档按上表用。解析错误这一类用 `--only syntax` 一秒就能定位，不要拿全套去撞。
4. **部署认准 `--skip-godot`（7 秒）。** 只传一个 1.2 MB 的 bundle；不带它要 **~5 分钟**
   （75 MB 的 Godot 二进制要过一条对 GitHub 时通时断的线路）。服务器上的 `--import`
   只要 3 秒，所以别为了省它而加 `--skip-import`（那会让新 `class_name` 不生效）。
   部署完会按"实际在跑什么"重启在跑的单元（不用带 `--enable-service`）。
   **"传上去了"与"跑的是那一份"是两件事**，这条上白查过两次；跑一次
   `check-server.mjs` 就有断言核对进程启动时间与仓库最新提交（它管这个）。
5. **失败的检查要把"能区分原因"的行打出来，不要只打末尾几行。** 实测：驱动器把
   「哪一条断言不成立」打在末尾 15 行之外，于是日志里只剩"有断言不成立"，为此多跑三轮
   （每轮 48 秒）。诊断输出按"能区分哪一种原因"挑行，不按"离末尾近"挑行。

细节（每次实测的记录）在 `memory/repo/` 与 `memory/` 里；本文件只留"不知道就会白干半天"的部分。
