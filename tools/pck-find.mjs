#!/usr/bin/env node
// 在导出的 PCK 里查找指定路径，用来确认某个非资源文件是否真的被打进了产物。
// 用法：node tools/pck-find.mjs <pck 路径> <要查的子串> [<要查的子串> ...]
//
// 为什么要专门查这个：Godot 的导出预设 `all_resources` 只涵盖"被识别为资源"的文件，
// 普通文本文件（.cfg/.json/.txt）不一定在内。而这属于"本地跑得好好的、发给别人就坏"
// 的一类问题——文件在仓库里、编辑器里也能读到，只有导出产物缺它。

import fs from "node:fs";

const [pckPath, ...needles] = process.argv.slice(2);
if (!pckPath || needles.length === 0) {
  process.stderr.write("用法：node tools/pck-find.mjs <pck> <子串> [<子串> ...]\n");
  process.exitCode = 2;
  process.exit();
}

const buf = fs.readFileSync(pckPath);
const text = buf.toString("latin1");

let missing = 0;
for (const needle of needles) {
  // PCK 内部按 UTF-8 存路径，用 latin1 读会让非 ASCII 字节走样，因此两种都试一次。
  const hit = text.includes(needle) || buf.includes(Buffer.from(needle, "utf8"));
  process.stdout.write(`${hit ? "FOUND   " : "MISSING "}${needle}\n`);
  if (!hit) missing++;
}

process.stdout.write(`\n${pckPath} 共 ${(buf.length / 1048576).toFixed(2)} MiB，缺失 ${missing} 项\n`);
process.exitCode = missing > 0 ? 1 : 0;
