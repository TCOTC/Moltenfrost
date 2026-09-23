# 熔霜 · Moltenfrost

<p align="center">
  <img src="logo.png" alt="熔霜 · Moltenfrost" width="160">
</p>

3D 双人元素协同解谜游戏，开发中。

- 玩法：两名角色各具元素属性，在同一个物理世界内协同解谜，并在此基础上扩展元素反应与 PVE 内容。
- 平台：桌面端，Windows（x86_64）与 macOS（Universal 2，支持范围为 Apple Silicon）。
- 联机：双人各用一台设备，通过联机协作，不做单机同屏。
- 技术：Godot 4.7.2，渲染后端 Forward+，物理引擎 Jolt，联机传输层用 `ENetMultiplayerPeer`。

## 开发环境

需要 Godot 4.7.2 与该版本的导出模板。

```powershell
node tools/setup-dev-env.mjs --check   # 查看模板是否齐全
node tools/setup-dev-env.mjs           # 不齐全时执行，安装本机平台的模板
```

各机器只导出自己平台的产物：Windows 机器出 Windows 版，Mac 机器出 macOS 版，因此默认只安装本机平台那一份模板，需要另一份时显式传 `--platforms windows,macos`。

## 运行与自检

用编辑器打开工程即可运行。改动后按下面的命令做一次自检，控制台无脚本错误再交给人试玩：

```powershell
godot --headless --path . --quit-after 3
```

导出预设见 `export_presets.cfg`，产物写入 `build/`。两个预设都要保留，两台机器各用其中一份，否则这个文件会在两边分叉。

## 目录

| 路径 | 内容 |
|---|---|
| `docs/` | 设计文档、命名与合规调研 |
| `memory/` | 开发笔记，按主题一个文件 |
| `scenes/`、`scripts/` | 场景与代码 |
| `tools/` | 跨平台开发工具，以 Node 实现 |
| `build/` | 导出产物，不入库 |

## 许可

本仓库不是开源项目。代码、美术、音频与文档均保留所有权利，授权范围限于 `LICENSE` 第 1 条列出的在线浏览、平台内复制与引用。名称与 Logo 的用法另见 `TRADEMARK.md`。不接受外部 PR。
