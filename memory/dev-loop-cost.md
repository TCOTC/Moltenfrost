# 开发循环的耗时（实测账本）

本文件只放**实测出来的耗时**与"因此该怎么用"。目的是让"跑一次要多久"这件事一直可见——
实测过一次 319 分钟的对话，**95% 的工具耗时在终端上**，其中大部分是反复跑贵的检查。
看不到代价，就会一直重复那个习惯。

## 分层自检：`tools/dev-check.mjs`（2026-09-30 实测）

| 层 | 命令 | 耗时 | 内容 |
| --- | --- | --- | --- |
| 单点 | `--only syntax` | **0.8s** | 所有脚本能解析、主链路能起来 |
| 快层 | （默认） | **10.2s** | 语法 + 插值 + 局域网 + 产品常量 + 界面 + 关卡几何 + 关卡玩法 |
| 全套 | `--full` | **69.0s** | 快层 + 会话生命周期 + 联机冒烟 + 房间池 + 目录客户端 |

各项实测耗时（全套那次）：`game` 6.6s 是最慢的快层项；`net-smoke` 45.9s、`pool` 11.2s、
`directory-client` 1.4s、`session` 0.6s，其余都在 1.3s 以内。

**为什么快层能这么便宜**：Godot 在这台机器上启动 + 跑一个 `--script` 测试约 0.3 秒，
而这些测试都是纯逻辑（不碰网络、不起实例）。`game` 之所以 6.6 秒，是因为它以场景为入口
（要加载关卡）。所以**快层的成本几乎就是 Godot 的启动次数**。

## 单项工具的实测代价

| 工具 | 耗时 | 什么时候才值得跑 |
| --- | --- | --- |
| `tools/net-smoke.mjs` | 46s（早先冷启动时到过 113s） | 动了联机层 |
| `tools/pool-check.mjs` | 11s（冷启动/初次补房时到过 90s） | 动了房间池或目录的可见性 |
| `tools/directory-client-check.mjs` | 1.4s（加 `--real` 再多一轮真解析） | 动了认领那条路 |
| `ssh … tools/directory-check.sh` | **8.4s** | 服务器侧验收（改前是 355s，见下） |
| `tools/check-server.mjs` | ~20s（含公网 RTT 与优雅停止） | 交给人试玩之前 |
| `deploy-server.mjs --skip-godot` | **7.3s** | 每次要同步到服务器时 |
| `deploy-server.mjs --skip-godot --skip-import` | 4.4s | 只改了 `.gd` 且没加 `class_name` |
| `deploy-server.mjs`（不带 `--skip-godot`） | **~326s** | 只在首次部署或换 Godot 版本时 |
| 本地 `git bundle create` | 0.2s / 1.2 MB | （含在部署里） |
| 服务器上 `godot --import` | 2.8s | （含在部署里） |

**326 秒那条的成因**：不带 `--skip-godot` 时要把 **75 MB 的 Godot 二进制**传过去，
而本机到 GitHub 的线路时通时断（实测 550 KB/s → 22 KB/s → 完全超时）。服务器自己连不上
GitHub，所以只能从本机上传。**因此日常部署一律加 `--skip-godot`。**

## `directory-check.sh`：355s → 8.4s 是怎么来的（2026-09-30）

原来有 `sleep 4` 与 `sleep 38` 两处固定等待，**无论成败都要等满**。改成轮询：

1. 等先到的客户端成为房主（最多 10 秒，正常 1 秒内满足）——这一条同时修掉了
   原先"两人几乎同时加入会漏掉房主判定"的不稳定。
2. 等两个客户端各自打出 `[drive] …：通过`（最多 45 秒，正常约 10 秒）。
   它们通过时会自己 `quit()`，所以不能等固定时长。
3. 第 5 节改成**等池真的收缩**（总数 ≤ 忙碌 + spare）。

顺带发现并修掉的一个**假通过**：原来的第 5 节只断言"没有忙碌的房间"，于是它在池还端着
两间房的时候就通过了——而断言写着"收敛"。现在会等到 `池里：忙碌 0 空闲 1` 才算过
（实测那次 6.3 秒通过时池里是 2 间，收紧之后 8.4 秒通过、池里确实是 1 间）。

**代价换来的是更强的断言**，不是"为了快而放宽"。这条经验值得记住：
用固定等待换来的速度提升，常常同时暴露一个原本被等待掩盖的弱断言。

## 为什么结论行必须是 ASCII

PowerShell 5.1 的管道会把子进程的 UTF-8 输出重新编码，中文结论经 `| Select-String` 会变乱码。
实测因此出现过：跑完 110 秒 → 看不出结论 → 换一种读法再跑一遍（两次）。

因此所有自检的**结论行**（`ok` / `FAIL` / `ALL PASS (N checks)`）只用 ASCII，
细节文案保留中文（只在人工细看时才需要）。判定本身看**退出码**，不看那句中文。

读结论用：`| Select-String 'ok |FAIL|ALL PASS'`。要细看再写文件 + `-Encoding Unicode`。

### 把子进程输出重定向到文件时（2026-09-30 实测，踩了三轮）

```
node tools/net-smoke.mjs > $env:TEMP\sm.txt     # 这个文件**读不回来**
```

PowerShell 用控制台的 ANSI 代码页（这台机器是 GBK）去解码子进程的 UTF-8 字节，
于是写进文件的是 `绗簩灞€` 这种**已经经过一次错解码**的内容 —— 再读回来无论用什么
编码都还原不出原文（`-Encoding Unicode` 会显示成 GBK 解 UTF-8 的乱码，`utf8` 读则
连 ASCII 都搜不到，因为文件是 UTF-16LE）。实测在"找那一行失败断言"上白跑了三轮。

可用的写法（在同一个命令里先设好控制台编码，再让 PowerShell 写 UTF-8）：

```powershell
[Console]::OutputEncoding=[Text.Encoding]::UTF8
node tools/net-smoke.mjs 2>&1 | Out-File -Encoding utf8 $env:TEMP\sm.txt
node -e "console.log(require('fs').readFileSync(process.env.TEMP+'/sm.txt','utf8'))"   # 用 Node 读
```

`[Console]::OutputEncoding` 决定 PowerShell **如何解码**子进程的输出，`Out-File -Encoding utf8`
决定它**怎么写**，两者都要设。读的时候用 Node（它自带 UTF-8），不要用 `Get-Content`。

由此也有一条更省事的做法：**别把中文当检索关键词**。同一个文件上前一个工具命中、
后一个不命中时，先怀疑编码，不要怀疑内容——搜 ASCII 标记（`[drive]`、`ok `、`FAIL`）永远成立。

### 失败时不要把关键行截掉（一次性省下 144 秒）

`net-smoke` 原先失败只打"末 15 行"，而驱动器把「哪一条断言不成立」打在更靠上的位置，
于是最该看的那一行恰好被截掉，日志里只剩"有断言不成立"。为此多跑了三轮（每轮 48 秒）。
现在改成末尾若干行 + **全部带标记的行**（`[drive]`/`[lobby]`/`[session]`/`[player]`…）。
"驱动器读到 0 人"这个现象，`[drive]` 那几条看不出是名单没到、还是名单是空的，
而 `[lobby] 名单：N 人` 那行直接给出答案——**所以诊断输出要按"能区分哪一种原因"来挑行**，
而不是按"离末尾近"来挑。

## 不要直接用 PowerShell 跑 godot

`& $godot --headless …` 的输出在终端里是乱码。要么加进 `dev-check.mjs`，
要么经 Node 包一层再打出来（`spawnSync(..., { encoding: "utf8" })` 由 Node 解码，因此可读）。
