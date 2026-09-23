#!/usr/bin/env node
// 拍对端角色的造型：本机开显示并截图，另一个实例无头连进来当"模特"。
//
// 为什么必须两个实例：第一人称看不到自己的身体，所以角色造型只能在**看得到对端**的那一端拍。
// 为什么对端要无头：两个带渲染的实例会互相抢 GPU，而且实测会污染帧时与物理间隔
//（见 memory/networking.md），截出来的画面也会因为掉帧而糊。
//
// 用法：node tools/capture-remote.mjs
//
// 产出：build/shots/r1_front.png 等若干张，见 capture_rig.gd 的 REMOTE_SHOTS。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PORT = 27215;
const TIMEOUT_MS = 90000;

const FATAL_PATTERNS = ["SCRIPT ERROR", "Parse Error", "Failed to load", "Invalid access", "Invalid call"];

function detectGodot() {
  if (process.env.GODOT_BIN && fs.existsSync(process.env.GODOT_BIN)) return process.env.GODOT_BIN;
  if (process.platform === "win32") {
    const root = "D:\\Tool\\Godot";
    if (fs.existsSync(root)) {
      for (const dir of fs.readdirSync(root)) {
        const full = path.join(root, dir);
        if (!fs.statSync(full).isDirectory()) continue;
        for (const f of fs.readdirSync(full)) {
          if (/^Godot_v.*console\.exe$/i.test(f)) return path.join(full, f);
        }
      }
    }
  } else {
    for (const p of ["/Applications/Godot.app/Contents/MacOS/Godot",
      path.join(os.homedir(), "Applications", "Godot.app", "Contents", "MacOS", "Godot")]) {
      if (fs.existsSync(p)) return p;
    }
  }
  return null;
}

function launch(godot, args, label, verbose) {
  const child = spawn(godot, args, { cwd: PROJECT_DIR, stdio: ["ignore", "pipe", "pipe"] });
  const state = { label, child, text: "", exitCode: null, exited: false };
  const collect = (stream) => {
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => {
      state.text += chunk;
      if (verbose) process.stdout.write(`[${label}] ${chunk}`);
    });
  };
  collect(child.stdout);
  collect(child.stderr);
  child.on("exit", (code) => { state.exitCode = code; state.exited = true; });
  return state;
}

// 要结束整棵进程树：Windows 上的 *_console.exe 只是包装程序，
// 只结束它会留下真正的引擎子进程占着端口（见 memory/networking.md）。
function stop(state) {
  if (state.exited) return;
  if (process.platform === "win32") {
    try {
      execFileSync("taskkill", ["/PID", String(state.child.pid), "/T", "/F"], { stdio: "ignore" });
      return;
    } catch { /* 已经退出了 */ }
  }
  state.child.kill("SIGKILL");
}

function waitForExit(state, timeoutMs) {
  return new Promise((resolve) => {
    const deadline = Date.now() + timeoutMs;
    const tick = () => {
      if (state.exited) { resolve(true); return; }
      if (Date.now() > deadline) { resolve(false); return; }
      setTimeout(tick, 100);
    };
    tick();
  });
}

const godot = detectGodot();
if (!godot) {
  process.stderr.write("找不到 Godot 可执行文件。设置 GODOT_BIN 后重试。\n");
  process.exit(1);
}
process.stdout.write(`Godot：${godot}\n端口：UDP ${PORT}\n`);

const base = ["--path", PROJECT_DIR, "--"];
// 主机：带显示、截图取景对准对端；客户端：无头，并且开启自动驾驶让角色在动。
const host = launch(godot,
  [...base, "--port", String(PORT), "--capture", "--capture-focus", "remote"],
  "主机（截图）", process.argv.includes("--verbose"));
let client = null;
let ok = false;
try {
  // 先让主机开始监听，再让客户端连入，否则客户端会以「连接失败」退出。
  await new Promise((r) => setTimeout(r, 4000));
  client = launch(godot,
    ["--headless", ...base, "--join", "127.0.0.1", "--port", String(PORT), "--autopilot"],
    "客户端（模特）", process.argv.includes("--verbose"));
  ok = await waitForExit(host, TIMEOUT_MS);
} finally {
  if (client) stop(client);
  stop(host);
}

const fatal = FATAL_PATTERNS.find((p) => host.text.includes(p));
if (fatal) {
  process.stdout.write(`\n主机日志里出现「${fatal}」，造型截图失败。\n`);
  process.stdout.write(host.text.split(/\r?\n/).slice(-25).join("\n") + "\n");
  process.exitCode = 1;
} else if (!ok) {
  process.stdout.write("\n主机没有在限定时间内退出，可能卡在等待对端角色。\n");
  process.stdout.write(host.text.split(/\r?\n/).slice(-25).join("\n") + "\n");
  process.exitCode = 1;
} else {
  const shots = fs.readdirSync(path.join(PROJECT_DIR, "build", "shots"))
    .filter((f) => f.startsWith("r"));
  process.stdout.write(`\n完成。对端造型截图 ${shots.length} 张：${shots.sort().join(", ")}\n`);
  process.stdout.write("输出目录：build/shots\n");
}
