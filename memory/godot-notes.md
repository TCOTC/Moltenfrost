# Godot 相关事实

只记已经实测或从源码核实过的点。`AGENTS.md` 里只说结论，细节在这里。

## `--script` 运行不注册自动加载单例（2026-09-26 实测）

`<godot> --headless --path <项目> --script <脚本>` 把那个脚本当成 MainLoop，此时**自动加载单例
（`project.godot` 里 `[autoload]` 注册的 `Net` 之类）不是可用的全局标识符**。现象是有欺骗性的两段式报错：

```text
SCRIPT ERROR: Compile Error: Identifier not found: Net      # 脚本自身
ERROR: Failed to load script "res://scripts/main.gd" ...    # 被它间接加载的脚本
```

要注意这是**编译**期报错，而且发生在运行时注册之前：只报一次 `Identifier not found`，
没有"未声明"之类的前置提示。实测三条：

- 脚本里出现自动加载单例的**运行期成员**（例如 `Net.hosting_started`）就会编译失败，
  `--script` 运行连 `preload` 入口场景都不行（`scripts/main.gd` 就是这么失败的）。
- 只取自动加载的**常量**（例如 `Net.DEFAULT_PORT`）的脚本能在 `--script` 运行里编译通过：
  `scripts/menu.gd` 只用到这一个常量，`tests/menu_test.gd` 因此能跑。
  推测是常量在分析阶段被折叠，代码生成阶段不再需要那个标识符，但没有进一步核实。
  由此得出一条判据：**“这个测试通过了”不等于“自动加载能用”**，必须真去取一个运行期成员。
- 因此需要入口场景（要跑 `scripts/main.gd`）的检查只能用"以场景为入口"的方式跑。

绕开的做法（本工程 `tests/session_test.gd` 用的）：把场景路径当位置参数启动，
自动加载会在主场景之前注册，与真正的启动方式一致。

```powershell
& <godot> --headless --path <项目> res://tests/session_test.tscn -- --port 0
```

退出码取自场景脚本里的 `get_tree().quit(<码>)`（`--script` 的 `quit(<码>)` 同理）。

## 导出预设的 `all_resources` 不含普通文本（2026-09-26 实测）

`export_filter="all_resources"` 只涵盖**被识别为资源**的文件。`.cfg`、`.json`、`.txt` 这类
普通文本不在其中，**必须写进 `include_filter`**，否则：

- 编辑器里 `FileAccess` / `ConfigFile` 读得到，一切正常；
- **导出产物的 pck 里根本没有这个文件**，运行时读不到 → 静默回退（若代码写了兜底值）
  或直接失败。属于"本地对、发出去就坏"的一类问题。

实测：新增 `config/product.cfg` 后先不加 `include_filter` 导出，用自制的
`tools/pck-find.mjs` 在 pck 里搜路径 → `MISSING`；加上 `include_filter="config/*.cfg"` 后
重新导出 → `FOUND`。那个工具是通用的，可查任意子串：

```powershell
node tools/pck-find.mjs build/server/probe.pck config/product.cfg
```

注意它的**局限**：只在 pck 里做字节搜索，因此

- 能可靠找到**文件路径**（pck 的目录区以明文存路径）；
- 找不到被压缩的脚本内容——`script_export_mode=2` 下脚本是压缩二进制，
  脚本里写的字符串常量搜索不到（实测搜域名时 `MISSING`，而脚本路径 `FOUND`）。
  所以它用来验"文件有没有进产物"，不是用来验"产物里的值是什么"。

导出命令（`--export-release <预设名> <输出路径>`，预设名取 `export_presets.cfg` 里的 `name=`）：

```powershell
& <godot> --headless --path . --export-release "Windows" build/server/probe.exe
```

## 编辑器会重写文件（2026-09-23 实测）

- `project.godot`：编辑器保存工程时整份重写。手写注释全部丢失（连头部说明都被换成 Godot 自己的模板），等于默认值的设置也会被删掉——例如显式写的 `renderer/rendering_method="forward_plus"` 就被移除了，因为 Forward+ 本来就是默认值。
- `export_presets.cfg`：只在编辑器里改动导出预设时才重写。没动之前写的注释都还在，改一次就没了。
- `*.tscn` / `*.tres`：编辑器保存时补 `uid`、重排字段、重写整个文件。

结论：注释写在 `.gd` / `.mjs` / `.md` 里，或者写在**使用这个配置的代码**旁边。

## 资源导入与 `--headless` 的行为（2026-09-24 实测）

- `--headless --quit-after N`（`AGENTS.md` 里的交付前自检）**只运行游戏，不重新导入资源**。删掉 `.godot/imported/` 之后再执行它，控制台照样无错误、退出码 0，而导入产物仍是空的——这条自检查不出资源缺失。
- 触发重建要用 `--import`：`& <godot 可执行文件> --headless --path <项目目录> --import`。输出含 `first_scan_filesystem` 与 `reimport` 两段进度，逐个文件列出，出现文件名即表示该文件已重新导入。
- `.import` 里的产物名是**源路径字符串的 MD5**，与文件内容无关：`MD5("res://LOGO.png")` = `d64952310586affc9777048ba72b1a55`。
- 因此重命名资源时不能只改 `source_file`：`path` 与 `dest_files` 中的旧文件名必须同步换成新哈希。按此手写后引擎接受该名称（实测未再改写文件名）。
- 改名后可删除 `.godot/imported/<旧名>-*` 与 `.godot/uid_cache.bin`，交由引擎重建；`uid` 保持不变，引用方不受影响。
- PCK 虚拟文件系统区分大小写，而 Windows 与近年 macOS 的默认文件系统不区分（官方文档 Project organization），因此资源文件名统一用小写加下划线。

## 删掉整个 `.godot/` 让它重建（2026-09-26 实测）

同一路径被另一个工程用过之后，`.godot/` 会留下一堆属于那个工程的死缓存——它们不参与运行，
但会占空间、并在排查资源问题时误导判断（本仓库实测留下了 86 个文件 / 27 MiB 的
`imported/`，含 `02_weapon.png`、`abandoned_workshop_1k.hdr`、`r1_front.png` 等本工程不存在的条目）。
清理办法就是整目录删除后重建。

- **必须先关掉编辑器**。编辑器在内存里持有文件系统缓存，边开边删它会写回旧内容（等于白删）；
  而且 Windows 上部分文件被占用，删除可能只完成一半。删之前用
  `Get-Process -Name 'Godot*'` 确认没有进程。
- 重建：`& <godot 可执行文件> --headless --path <项目目录> --import`。
  输出分三段，可逐项核对：`first_scan_filesystem` → `update_scripts_classes`（逐个列出
  `class_name` 注册的脚本，本工程是 4 个：`NetCmdline`/`Player`/`RemoteInterpolator`/`StepAnalyzer`）
  → `reimport`（逐个列出实际导入的资源，本工程只有 `logo.png` 一个）。
- **会丢的只有编辑器状态**：窗口布局、打开过的脚本与光标位置、场景折叠状态
  （都在 `.godot/editor/`）。工程设置、导出预设、代码与资源都在 `.godot/` 之外，不受影响。
- 实测回收：29.0 MiB / 186 个文件 → 0.3 MiB / 8 个文件。`shader_cache/`（1.79 MiB）
  会在编辑器打开时按需重建，属正常现象。
- `.godot/` 自带一个 `.gdignore`（由引擎创建），因此它不会被当成资源目录扫描。
  这与 `build/` 需要手写 `.gdignore` 是两件事。

## 全局类缓存缺失时所有 `class_name` 都解析失败（2026-09-24 实测）

- 症状：命令行直接运行工程，蹦出 `Parse Error: Identifier "NetCmdline" not declared in the current scope`、
  `Could not find type "Player" in the current scope`，最后 `Failed to load script "res://scripts/main.gd"`。
  看起来像代码写错了，其实是环境问题。
- 根因：`.godot/global_script_class_cache.cfg` 里 `list=[]`。全局类不是靠扫目录发现的，而是这个文件里注册的；
  一台从没用编辑器打开过工程的机器（新克隆、只跑过 `--headless`）就是空的。
- 修法：`<godot> --headless --path <项目> --import`。它会先跑 `update_scripts_classes` 段并逐个列出脚本名
  （`NetCmdline`、`Player`…），跑完 `list=` 里就有条目了。跑之前先杀掉正在失败的实例。
- 与上一条同源：`--headless --quit-after N` 同样不会重建这个缓存，所以交付前自检过不代表能跑起来。

## 特性标签覆盖（源码核实）

- 语法是把标签后缀在设置名后面：`<设置名>.<标签>`。Godot 自己就是这么用的——`rendering/renderer/rendering_method.mobile` 与 `.web` 都是特性覆盖。
- `OS::has_feature("editor")` 在**任何带编辑器功能的二进制**（TOOLS_ENABLED）里恒为 true；导出产物里为 false，代之以 `template`。所以"编辑器里窗口化、导出后全屏"这种需求用一份工程就能配出来，不需要运行时判断平台。
- 另外三个可用标签：`editor_hint`（编辑器 UI 内为真）、`editor_runtime`（编辑器二进制跑工程时为真）、`embedded_in_editor`（被嵌入编辑器运行时为真）。
- 取覆盖后的值必须用 `ProjectSettings.get_setting_with_override(name)`；普通 `get_setting()` 返回的是基础值。
- 编辑器给运行中的游戏传自定义特性用的是环境变量 `GODOT_EDITOR_CUSTOM_FEATURES`（逗号分隔）。

## macOS 导出（源码核实 + 导出实测）

- 架构是导出预设的 `binary_format/architecture`，可选 `universal` / `x86_64` / `arm64`，默认 `universal`。
- **官方模板只提供 `universal` 二进制**。`macos.zip` 里只有 `godot_macos_release.universal` 与 `godot_macos_debug.universal`（2026-09-23 实测条目列表）。而导出时代码按 `godot_macos_<debug|release>.<架构>` 精确匹配模板内的文件（`platform/macos/export/export_plugin.cpp` 里 `binary_to_use`），所以选 `x86_64` 或 `arm64` 都会失败：
  `ERROR: 导出: 未找到请求的模板二进制文件"godot_macos_release.x86_64"。`
  结论：**用官方模板时，macOS 只能出 universal**（体积更大，Intel Mac 也能跑）。要真正只出 arm64 只有两条路——在 macOS 上用 `lipo -thin arm64` 削（必须在签名之前），或者自备一份把 universal 拆成单架构的自定义模板（`custom_template/release`）。
- 若启用 ETC2 ASTC 之外的注意事项：选 `arm64` 或 `universal` 时若没启用 ETC2 ASTC，导出会被直接拒绝，报"禁用 ETC2 ASTC 纹理格式时无法为 universal 和 arm64 进行导出"。项目设置 `textures/vram_compression/import_etc2_astc` 必须为 `true`；`x86_64` / `universal` 另需 S3TC BPTC（默认已开）。本工程开了 ETC2 ASTC 以便将来切 arm64。
- 从 Windows 导出 macOS **要导 zip，不要导 .app**：Windows 文件系统给不了可执行位，产出的 .app 在 macOS 上跑不起来；DMG 只能在 macOS 上打。
- 发布给外部用户需签名并公证，否则被 Gatekeeper 拦截；从 Windows 签名要装 `rcodesign`，在 macOS 上用 Xcode 的 codesign 与 notarytool。原型期可以不签。

## 改 export_presets.cfg 要按段定位（2026-09-23 踩过）

两个预设用的是**同一套键名**（`binary_format/architecture`、`debug/export_console_wrapper`、`export_filter`…）。做批量替换会命中的是第一个匹配项，不看它属于哪个 `[preset.N.options]`——当天就是把 Windows 的架构误改成了 `universal`，而 macOS 那边没动，于是导出报的错看起来像"universal 也不行"，白查一轮。改这个文件必须带上下文（前后行）或按 `[preset.N]` 段定位。

## 导出实测数据（2026-09-23）

- Windows：`build/windows/Moltenfrost.exe` 104.17 MiB + `Moltenfrost.pck` 0.96 MiB。
- macOS（universal）：`build/macos/Moltenfrost.zip` 59.76 MiB（内含 162 MiB 的 universal 可执行文件，zip 压过）。

## Game 面板的嵌入开关（2026-09-24 排查过一轮）

- 编辑器设置 `run/window_placement/game_embed_mode`：`-1` 禁用 / `0` 跟随工程配置 / `1` 嵌入 / `2` 浮动工作区，**默认是 0**。
- 值为 0 时它读的是**按工程**存的 metadata：`.godot/editor/project_metadata.cfg` 里的 `[game_view] embed_on_play`（缺省 true）与 `make_floating_on_play`（缺省 false）；这两个值由 Game 面板右上角那三个小图标写入。所以换一个工程要重新确认一次。
- 症状：`window/size/mode.editor=0` 明明已经生效（游戏进程日志里是"生效模式=窗口"），运行起来却仍然弹独立窗口，标题带 `(DEBUG)`。把上面那个设置改成 `1`（Embed Game）后立刻变成嵌入。
- 教训：`window/size/mode.editor` 只解决"**能不能**嵌入"的前置条件（Godot 的判定逻辑会因此显示"点击运行启动游戏"），"**要不要**嵌入"由上面那个开关决定。排查顺序：先看 Game 面板的状态文字 → 再看这两处设置。重启编辑器并不会改这个开关，所以"重启一遍"不是万能解。

## 导出模板的分平台安装（2026-09-23 实测）

- 官方模板包 `Godot_v<版本>-<渠道>_export_templates.tpz` 约 1.2 GiB，但它本身是个 ZIP，可以用 HTTP Range 只取需要的条目——`tools/setup-dev-env.mjs` 就是这么做的，Windows + macOS 两份合计 325 MiB。
- 这台机器到 GitHub CDN 约 0.11 MiB/s，且开多连接并不更快（瓶颈是单 IP 限速，不是连接数）。325 MiB 约需 50 分钟。
- 清华 / 上交 / 中科大 / TuxFamily 四个镜像都没有同步这个文件，只能走 GitHub。
- Godot 认的模板目录名是 `<版本>.<渠道>`，例如 `4.7.2.stable`；Windows 在 `%APPDATA%\Godot\export_templates\`，macOS 在 `~/Library/Application Support/Godot/export_templates/`。

## 2D 与 3D 的配置差异（2026-09-25 实测，4.7.2）

- `physics/2d/physics_engine` 的可选值是 `DEFAULT,GodotPhysics2D,Dummy`——**Jolt 只服务 3D**
  （`physics/3d/physics_engine` 才是 `DEFAULT,Jolt Physics,GodotPhysics3D,Dummy`）。
  因此 `AGENTS.md` 里"必须显式选 Jolt"这条只对 3D 成立；2D 侧除 `Dummy`（无物理）外只有一套实现，
  不存在"换后端后手感变化、参数要在选定后端之后调"这个问题，
  代价是堆叠与旋转平台的求解稳定性弱于 Jolt。`physics/2d/default_gravity` 默认 980 px/s²。
- `rendering/textures/canvas_textures/default_texture_filter` 默认 `Linear`（像素美术要改 `Nearest`）；
  `display/window/stretch/mode` 可选 `disabled,canvas_items,viewport`，
  `display/window/stretch/scale_mode` 可选 `fractional,integer`。
- 2D 类名已用 `ClassDB.class_exists()` 核实存在：`CharacterBody2D`、`CollisionShape2D`、
  `CollisionPolygon2D`、`Sprite2D`、`Polygon2D`、`Camera2D`、`TileMapLayer`、`TileSet`、
  `AnimatableBody2D`、`StaticBody2D`、`RigidBody2D`、`Light2D`、`PointLight2D`、`DirectionalLight2D`、
  `CanvasModulate`、`Parallax2D`、`ParallaxBackground`、`ParallaxLayer`、`Line2D`、`GPUParticles2D`。
  `TileMapLayer` 与 `Parallax2D` 的父类都是 `Node2D`。
- 读这些设置值的通用做法（临时脚本用完即删）：写一个 `extends SceneTree` 的脚本，
  在 `_initialize()` 里遍历 `ProjectSettings.get_property_list()`，字段 `hint_string` 就是可选项列表；
  运行方式是 `<godot 可执行文件> --headless --path <项目目录> --script res://<脚本路径>.gd`。
  只读项目设置不涉及场景树，因此可以放在 `_initialize()`；凡是涉及节点入树的都要等 `_process` 第一帧。

## Camera2D 没有 `current` 属性（2026-09-25 实测）

`Camera3D` 有 `current`，`Camera2D` 没有；给 `Camera2D` 写 `current = true` 会报
`Invalid assignment of property or key 'current' ... on a base object of type 'Camera2D'`。
它只有 `enabled`（可读写）、`make_current()` 与 `is_current()`。实测得到的三条：

- `enabled = false` 的相机入树时不接管视角，之后也不会把视角清空。
- 已经有相机在用的时候，后来入树的相机不会抢走视角。
- 要**确定**接管必须调 `make_current()`。它不能先于 `enabled` 调，引擎里有
  `enabled && is_inside_tree()` 的断言，先调会报 `Condition "!enabled || !is_inside_tree()" is true`。

因此"每个实例各带一台相机、只有本机那台生效"的写法是：场景里写 `enabled = false`，
本机角色 `enabled = true` 再 `make_current()`。实测 `get_viewport().get_camera_2d()` 始终是本机那台，
之后出场的远端角色不会把视角抢走。参考 `scripts/player.gd` 的 `_ready`。

**`SceneTree` 脚本不能在 `_initialize()` 里做入树相关的事**：那个阶段节点还不算在树内，
上一条的断言就是这么被触发的。要等 `_process` 的第一帧，`tests/remote_interpolator_test.gd`
与 `tools/` 下一次写临时脚本时都照此办理。

## `add_child` 会立刻执行该节点的 `_ready`（2026-09-25 复核）

`add_child(node)` 返回时 `node._ready()` 已经跑完，因此**运行时构建的带脚本节点必须先把子节点建全、
设好脚本与导出属性，最后才 `add_child`**；否则脚本的 `_ready` 里访问 `$Mesh` 之类的子节点会失败。

这条的另一个用途是**捕获运行时的副作用**：实例化 `main.tscn` 时，`main.gd` 的 `_ready` 会按
`project.godot` 把窗口设成全屏（`window/size/mode=3`）。想用截图脚本临时开窗口化，
就必须在 `add_child` **之后**再调 `DisplayServer.window_set_mode()`，写在前面会被 `_ready` 覆盖掉。

## `physics_frame` 信号早于节点的 `_physics_process`（2026-09-26 实测）

`SceneTree.physics_frame` 在每个物理步开始时发出，**早于**所有节点的 `_physics_process`。
用 `extends SceneTree` 的脚本做逐帧验证时这一点决定了两件事：

- 注入输入要在这个信号里做：此时 `Input.action_press()` 当帧就能被节点的
  `Input.is_action_just_pressed()` 看到，行为与真人按键一致。
- **观测状态会晚一帧**：在这里读到的 `velocity` / `is_on_floor()` 是**上一步**处理完的结果。
  因此不能写「站在地面且竖直速度为负」这类瞬时判据——等能观测到时，起跳已经把角色推离地面、
  `is_on_floor()` 已经变假了。实测踩过一次，报出来的失败是假失败。
  改为看「竖直速度是否转负」「若干帧内的最小值」这类在信号之后仍成立的条件。

## 手写速度积分比解析式跳得高（2026-09-26 实测）

自己用 `velocity.y += gravity * delta` 加 `move_and_slide()` 驱动跳跃时，实测高度比
`v² / (2·g)` 高约 `v·dt/2`（半隐式欧拉每步先加一次重力再位移的离散补偿）。
60 Hz、1160 px/s、4200 px/s² 下：解析 160.2 px、实测 170.1 px，差额 9.9 px 与 `v·dt/2 = 9.7 px` 对得上。
滞空的实测值也比 `2v/g` 长约 0.05 s，其中一半是同样的补偿，另一半是落地判定的帧粒度
（`is_on_floor()` 要到碰撞之后的下一帧才为真）。

结论：调跳跃手感时按这个差额估算即可，不要因为「算出来和手感对不上」去反推重力。
数值本身在 `scripts/player.gd`，注释里记了实测值。
