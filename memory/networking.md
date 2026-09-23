# 联机

机制与坑。只记实测或从源码核实过的点；决策与理由在 `docs/熔霜-游戏设计文档.md` 4.5。

## 结论：权威节点自建，不用 Steam 中继或 EOS

- 2026-09-24 定。分歧点只有一个：由谁解决可达性。本项目面向的玩家与两台开发机都没有公网入口，
  因此只有"权威节点自带公网地址"这一条能从根上移除这个问题。
- Steam 数据报中继（SDR）：免费、零服务器，但官方文档明确非 Steam 渠道不保证服务，且需要 AppID。
- EOS P2P：免费且不要求上架 Epic，但 Godot 侧绑定由社区维护，与 4.7.2 的匹配情况未核实。
- 自建：一台最便宜的 VPS。代价是月度费用，并发上限等于进程数（一个无头进程服务一场对局）。
- **服务端必须是同一份 Godot 工程**，理由不是省事：服务端要执行物理与机关判定，
  另用一套实现就要重写 Jolt 的刚体动力学与碰撞求解，而两套实现必然分叉。

## 无头服务端

- `--headless` 等价于 `--display-driver headless --audio-driver Dummy`，Godot 4 起不需要单独的 server 版二进制。
- 判定方式：`DisplayServer.get_name() == "headless"`，或用导出预设的 `dedicated_server` 特性标签
  （Resources 页选 Export as dedicated server，可对贴图/材质选 Strip Visuals 显著缩小 PCK）。
- **服务端不能依赖渲染**：Strip Visuals 之后贴图被占位替代，任何读取图像像素的判定都会失效。
- **服务端不是玩家**：官方文档明确提醒示例代码默认把服务端当成一个玩家。本工程的规则是
  "本机是否为玩家只取决于运行模式，与它是权威节点这一点无关"。

## 实测：2026-09-24

### 客户端 peer id 是随机的，不是 2

服务端日志实测：`peer 1480001058 已连接`、`peer 799416377 已连接`，两次都不同。
`High-level multiplayer` 文档也写了"客户端被分配一个随机的正整数"。
**任何按顺序假设 id（第一个人是 2）的代码都会错。** 冒烟脚本因此从日志里正则取出 id 再用。

### 权限必须设在 `_enter_tree`，不能等 `_ready`

- 接收方在远端生成包到达的同一帧就应用初始同步状态，而那一刻它要求节点的多人权限
  已经等于发起方——`SceneReplicationInterface::on_replication_start` 里有
  `pending_spawn == obj_id && sync->get_multiplayer_authority() == pending_spawn_remote` 这个判断。
- **权限不随生成包传输**（`_make_spawn_packet` 里没有权限字段），所以各端必须各自推导出同一个值。
  本工程的做法是在生成函数里传入 peer id，`_enter_tree` 里 `set_multiplayer_authority(peer_id)`。
- 源码核实：`Node::_propagate_enter_tree()` **不**处理 `multiplayer_authority`，
  只设置 tree/depth/viewport 与分组，然后发 `NOTIFICATION_ENTER_TREE`。所以在 `add_child` 之前
  设置权限不会被父节点覆盖；反过来，权限也不会自动从父节点继承。
- `MultiplayerSynchronizer::set_multiplayer_authority` 是重写版本，会先 `_stop()` 再 `_start()`，
  因此改权限等于重新注册同步，不要频繁调用。

### `MultiplayerSpawner.spawn_function` 不会被序列化

`ADD_PROPERTY(..., PROPERTY_USAGE_NONE)`，所以它写不进 `.tscn`，**必须在每个 peer 上于运行时赋值**。
用自定义生成（`spawn(data)`）而不是 `add_spawnable_scene` 的好处是生成参数随包发送，
不需要再从节点名反推 peer id。

### 迟到的 peer 能收到已有的生成（源码核实）

`SceneReplicationInterface::on_peer_change(id, true)` 会遍历 `spawned_nodes` 并逐个
`_update_spawn_visibility(p_id, oid)`，因此"主机先开局、客户端后加入"这个常见顺序是被支持的，
不需要自己重发生成。

### 生成节点名的限制

- 必须通过 `Node::validate_node_name()`：不能以 `@` 开头（引擎的自动名），不能含 `. : / " %`。
  所以添加生成节点时要 `add_child(node, true)`（第二个参数让引擎生成可读名），或自己起合法名。
- 同一父节点下必须唯一（`on_spawn_receive` 里 `ERR_FAIL_COND_V(parent->has_node(name))`）。

### `SceneReplicationConfig` 的三种模式与 `.tres` 写法

- 枚举：`NEVER = 0`、`ALWAYS = 1`（每个网络帧以不可靠方式发送）、`ON_CHANGE = 2`（变化时以可靠方式发送）。
- 序列化键：`properties/N/path`、`properties/N/spawn`、`properties/N/replication_mode`。
  注意 `_get_property_list` 把 `path` 声明为 STRING 但 `_set` 要求 `Variant::NODE_PATH`，
  且子名数必须大于 0，所以文件里要写 `NodePath(".:position")` 而不是裸字符串。
- `spawn = true` 的属性在生成包里随初始状态一起送达；`ALWAYS` 的属性按网络帧持续发送。

### 主机的本机玩家要显式生成

`multiplayer.peer_connected` 只在**别的** peer 连接时触发，主机自己不会收到针对自己的信号。
所以 listen server 模式必须在 `Net.host()` 成功之后立刻为 `Net.local_id()` 生成一次角色。
（2026-09-24 就是漏了这一条，无头测试看不出来，因为专用服务端本来就不该有本机角色。）

### 没有 peer 时 `multiplayer.is_server()` 返回 true

离线状态也被当作服务端，所以无法用它区分"未开始会话"与"正在监听"。
本工程用 `Net.role`，并把"本机是否权威"定义为 `role != CLIENT`。

### 生成位置要按 peer id 错开

否则所有玩家重叠在原点。本工程按 peer id 分布在一个半径为 4 的圆上。

### macOS 客户端连 Windows 主机（2026-09-24 实测，两台真机）

- 同一 Wi-Fi 网段（Mac `192.168.5.190`，主机 `192.168.5.210`），客户端 `--join 192.168.5.210 --port 27015`
  一次连上，没有额外开防火墙规则。客户端日志顺序：
  `已连接到主机` → `peer 1 已连接` → `远端角色 peer=1 已就位` → `本机角色 peer=787917097 已就位`。
- 客户端视角里主机 peer id 是 1，与服务端的约定一致。
- **`ping` 不通不能当成不可达**：Windows Defender 防火墙默认丢弃 ICMP，而 UDP 27015 是通的。
  判断可达性只能看客户端日志里的连接结果。
- macOS 命令行的 Godot 在 `/Applications/Godot.app/Contents/MacOS/Godot`，直接带 `-- --join …` 跑工程即可，
  `window/size/mode.editor=0` 覆盖生效所以是窗口模式（日志里的 `[display]` 行会打出「生效模式=窗口」）。
- 这次仍**没**验证位置同步是否真的在流动（要人按键）、延迟与丢包。

## 命令行与日志

- 自定义参数放在 `--` 之后由 `OS.get_cmdline_user_args()` 返回；引擎不认识的参数**会被静默忽略**
  （官方文档明确写了不会给出提示），所以两种写法都扫一遍是安全的。
- `project.godot` 里开了 `run/flush_stdout_on_print=true`：不开的话 stdout 被重定向到管道时
  会缓冲，冒烟脚本读不到及时的输出，服务端日志也会滞后。官方文档在 systemd 部署一节也建议打开它。

## 冒烟测试（`tools/net-smoke.mjs`）

- 无头起一个专用服务端与一个客户端（`127.0.0.1`），按日志断言：
  服务端开始监听 → 客户端连接成功 → 服务端收到连接并生成角色 → 客户端收到自己的角色
  → 专用服务端未生成本机角色 → 两个实例均在运行且无脚本错误。
- 它顺带验证了输入映射：客户端会执行本地玩家的 `_physics_process`，
  缺动作时 `Input.get_axis` 会直接把错误写进日志。
- **它不覆盖的事**：位置同步是否真的在流动（玩家不动就看不出）、手感、延迟、丢包、
  两台真机之间的局域网、公网。手感与延迟只能靠网络损伤注入（本机限速/丢包工具），
  局域网的 1 ms RTT 与真实公网差距太大，不能让局域网测试的结论代替。

## 尚未做

- 玩家位置没有预测与插值，同步频率就是网络帧率。要不要引入 netfox 一类方案，
  等网络损伤测试的结果再定。
- 推箱与可旋转平台引入时要改为服务端权威；届时玩家移动是否一并改成"上报输入 + 服务端模拟"，
  同一个测试一并决定。
- 部署到 Linux VPS 需要新增 Linux 导出预设与 Linux 模板（`tools/setup-dev-env.mjs` 目前只认
  `windows` 与 `macos` 两个平台）。这会改动 `export_presets.cfg`，两台机器要同步一次。
