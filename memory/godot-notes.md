# Godot 相关事实

只记已经实测或从源码核实过的点。`AGENTS.md` 里只说结论，细节在这里。

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
