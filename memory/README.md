# memory/

需要长期记住、但不该塞进 `AGENTS.md` 的细节放这里。

这个目录由 AI 自行维护：记什么、记在哪一个文件、什么时候更新，都由 AI 在会话中判断后直接写入，不需要人指定或确认。人只需在发现某条不对时说改哪一条。

约定：

- 按主题一个文件（`godot-notes.md`、`art.md`、`networking.md`…），不要按日期写成流水账。
- 每条写清：结论、依据（命令 / 链接 / 文件 / 实测日期）。
- 结论变了就直接改原条目，不要在后面追加"更正"——留两个说法比没有更糟。
- 这里的东西是给人和 AI 看的笔记，不是设计文档；判断"该不该记"的标准是"以后还会不会踩同一个坑"。

## 本机路径：写进 `local-env.json`，不要写进别处

`AGENTS.md`、`README.md`、`docs/`、`tools/` 里的注释都会被同步给其他开发者，
而那台机器上不存在你的 `D:\Tool\Godot\...`。所以**本机绝对路径只写在 `memory/local-env.json`**，
它已被 `.gitignore` 排除，只存在于本机。

各人都要有一份，但**通常不需要手写**：`node tools/setup-dev-env.mjs --print-godot`
一旦探测成功就会自己写进去（字段说明见 `local-env.example.json`）。只有"什么都探不到"时
才需要手填——把 `GODOT_SCAN_DIRS` 指向 Godot 的解压目录，或直接写死 `GODOT_BIN`。

AI 首次在别人的机器上工作，按这个顺序做：跑 `--print-godot`；成功就继续；失败就把本机 Godot
的真实位置写进 `memory/local-env.json` 再跑一次。**任何情况下都不要把路径回写进入库的文件。**
注意该文件写坏了不会被静默忽略：几个工具会报"不是合法 JSON"再退回探测。

取值顺序（三个 tools 脚本与 AI 都遵守）：

1. 环境变量 `GODOT_BIN`
2. `memory/local-env.json` 的 `GODOT_BIN`
3. `memory/local-env.json` 的 `GODOT_SCAN_DIRS` 里逐目录找 `Godot_v*console.exe`
4. `PATH` 里的 `godot` / `godot4`，以及 macOS 的 `Godot.app`
