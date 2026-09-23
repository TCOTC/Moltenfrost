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

## 联机

目前没有主菜单，本机的角色由命令行参数决定：不带参数运行等于本机开局（主机，同时自己也是玩家），传 `--join <地址>` 则连接到远端主机。

```powershell
# 主机，本机也是玩家
godot --path . -- --port 27015

# 加入方
godot --path . -- --join 192.168.1.20 --port 27015

# 专用服务端：本机不生成角色，供局域网或自建服务器使用
godot --headless --path . -- --host --port 27015
```

同一台机器上验证两个实例时，第二个实例连 `127.0.0.1`。服务端绑定的是通配地址，因此环回与局域网网卡同时生效，局域网内其他设备直接连内网 IP 即可。首次监听端口时 Windows 与 macOS 都会弹防火墙授权，要允许专用网络。

动了联机相关代码之后执行一次冒烟测试，它无头起一个服务端与一个客户端，核对连接、按 peer 生成角色与专用服务端不生成角色的行为：

```powershell
node tools/net-smoke.mjs
```

当前实现的边界需要说清：玩家移动由本机权威判定，位置按网络帧同步，既没有预测也没有插值；推箱与机关引入时要改为服务端权威。手感与延迟的结论必须来自网络损伤注入（本机限速或丢包工具），不能由局域网测试代替。详细的机制与坑记在 `memory/networking.md`。

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
