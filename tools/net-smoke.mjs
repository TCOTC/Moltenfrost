#!/usr/bin/env node
// 熔霜 · 联机冒烟测试
//
// 两段检查：
//   1. 插值逻辑测试（tests/remote_interpolator_test.gd）：不联网，验证收到位置快照后的取样是否均匀。
//   2. 双实例检查：无头起一个专用服务端与一个客户端，各断言一次连接与角色生成。
//
// 它覆盖的是"连接是否建立、角色是否被生成并同步到对端、远端显示是否平滑、
// 元素地形与复位是否生效"，不覆盖手感与延迟——那两件事只能由人在真机上判断，
// 并配合网络损伤注入（见 memory/networking.md）。
//
// 用法：
//   node tools/net-smoke.mjs
//   node tools/net-smoke.mjs --godot "D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe"
//   node tools/net-smoke.mjs --port 27016 --timeout 30 --verbose
//
// 退出码 0 表示全部断言通过。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// 日志里出现这些字样即视为失败，不等待断言超时。
const FATAL_PATTERNS = [
  "SCRIPT ERROR",
  "Parse Error",
  "Invalid access to property",
  "Invalid call",
  "Can't autoload",
];

function parseArgs(argv) {
  const opts = {
    godot: process.env.GODOT_BIN || null,
    port: 27115,
    timeout: 20,
    verbose: false,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`参数 ${arg} 后面缺少取值`);
      return v;
    };
    switch (arg) {
      case "--godot": opts.godot = next(); break;
      case "--port": opts.port = Number(next()); break;
      case "--timeout": opts.timeout = Number(next()); break;
      case "--verbose": opts.verbose = true; break;
      case "-h": case "--help": opts.help = true; break;
      default: throw new Error(`未知参数：${arg}`);
    }
  }
  return opts;
}

const HELP = `熔霜 · 联机冒烟测试

  node tools/net-smoke.mjs [选项]

  --godot <路径>   Godot 可执行文件；不给则用 GODOT_BIN 或按常见位置探测
  --port <端口>    UDP 端口，默认 27115（避开开发时常用的 27015）
  --timeout <秒>   单个断言的等待上限，默认 20
  --verbose        把两个实例的输出实时打到终端
  -h, --help       显示本帮助
`;

// 同一个探测逻辑在 tools/setup-dev-env.mjs 里也有一份，用于确定导出模板版本。
// 两处用途不同（那边要版本号，这边只要能启动），暂时各自保留一份，避免为共用而牵动已稳定的脚本。
function detectGodot() {
  const candidates = [];
  if (process.env.GODOT_BIN) candidates.push(process.env.GODOT_BIN);
  if (process.platform === "win32") {
    candidates.push("godot.exe", "godot4.exe");
    // 本机把 Godot 装在 D:\Tool\Godot\<版本>\ 下，顺手也看一眼
    try {
      const root = "D:\\Tool\\Godot";
      if (fs.existsSync(root)) {
        for (const dir of fs.readdirSync(root)) {
          const full = path.join(root, dir);
          if (!fs.statSync(full).isDirectory()) continue;
          for (const f of fs.readdirSync(full)) {
            if (/^Godot_v.*console\.exe$/i.test(f)) candidates.push(path.join(full, f));
          }
        }
      }
    } catch { /* 探不到就算了 */ }
  } else {
    candidates.push("godot", "godot4");
    for (const appDir of [
      "/Applications/Godot.app",
      path.join(os.homedir(), "Applications", "Godot.app"),
    ]) {
      candidates.push(path.join(appDir, "Contents", "MacOS", "Godot"));
    }
  }
  for (const cmd of candidates) {
    try {
      execFileSync(cmd, ["--version"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
      return cmd;
    } catch { /* 换下一个 */ }
  }
  return null;
}

function launch(godot, args, label, opts) {
  const child = spawn(godot, args, { cwd: PROJECT_DIR, stdio: ["ignore", "pipe", "pipe"] });
  const state = { label, child, text: "", exitCode: null, exited: false };
  const collect = (stream) => {
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => {
      state.text += chunk;
      if (opts.verbose) process.stdout.write(`[${label}] ${chunk}`);
    });
  };
  collect(child.stdout);
  collect(child.stderr);
  child.on("exit", (code) => {
    state.exitCode = code;
    state.exited = true;
  });
  return state;
}

function waitForMatch(state, regex, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const tick = () => {
      const hit = FATAL_PATTERNS.find((p) => state.text.includes(p));
      if (hit) {
        reject(new Error(`${state.label} 的输出里出现「${hit}」`));
        return;
      }
      const m = regex.exec(state.text);
      if (m) {
        resolve(m);
        return;
      }
      if (state.exited && state.exitCode !== 0) {
        reject(new Error(`${state.label} 提前退出，退出码 ${state.exitCode}`));
        return;
      }
      if (Date.now() > deadline) {
        reject(new Error(`${state.label} 在 ${timeoutMs / 1000} 秒内没有出现 ${regex}`));
        return;
      }
      setTimeout(tick, 50);
    };
    tick();
  });
}

function waitFor(state, needle, timeoutMs) {
  // 把字面串转义成正则，与需要取值的那些等待共用同一套错误处理。
  const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return waitForMatch(state, new RegExp(escaped), timeoutMs).then(() => undefined);
}

function stop(state) {
  if (state.exited) return;
  // 要结束整棵进程树：Windows 上的 *_console.exe 只是个包装程序，
  // 它会以子进程方式启动真正的引擎二进制。只结束包装进程会留下实例占着端口，
  // 下次运行就会以"端口被占用"的形式失败。
  if (process.platform === "win32") {
    try {
      execFileSync("taskkill", ["/PID", String(state.child.pid), "/T", "/F"], { stdio: "ignore" });
      return;
    } catch {
      // 已经退出了就什么都不用做。
    }
  }
  state.child.kill("SIGKILL");
}

function tail(text, lines = 30) {
  return text.split(/\r?\n/).slice(-lines).join("\n");
}

// 插值逻辑测试。它不联网，但同样属于联机正确性：远端角色是否平滑取决于
// 收到快照后的取样方式，而这一层可以用确定性的输入算出来。
function runInterpolationTest(godot, opts) {
  const proc = spawnSync(
    godot,
    ["--headless", "--path", PROJECT_DIR, "--script", "tests/remote_interpolator_test.gd"],
    { cwd: PROJECT_DIR, encoding: "utf8" },
  );
  const output = `${proc.stdout || ""}${proc.stderr || ""}`;
  if (opts.verbose) process.stdout.write(output);
  const fatal = FATAL_PATTERNS.find((p) => output.includes(p));
  if (fatal) throw new Error(`插值测试的输出里出现「${fatal}」\n${tail(output)}`);
  if (proc.status !== 0) throw new Error(`插值测试退出码 ${proc.status}\n${tail(output)}`);
  const m = /插值逻辑测试通过（(\d+) 项断言）/.exec(output);
  if (!m) throw new Error(`插值测试没有报告通过\n${tail(output)}`);
  return Number(m[1]);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) { process.stdout.write(HELP); return; }

  const godot = opts.godot || detectGodot();
  if (!godot) {
    throw new Error("找不到 Godot 可执行文件。用 --godot <路径> 指定，或设置 GODOT_BIN。");
  }
  const say = (msg) => process.stdout.write(`${msg}\n`);
  say(`Godot：${godot}`);
  say(`端口：UDP ${opts.port}    等待上限：${opts.timeout} 秒`);

  const base = ["--headless", "--path", PROJECT_DIR, "--"];
  const timeoutMs = opts.timeout * 1000;
  const assertions = [];

  const interpolationChecks = runInterpolationTest(godot, opts);
  assertions.push(`插值取样保持均匀（${interpolationChecks} 项断言）`);

  const server = launch(godot, [...base, "--host", "--port", String(opts.port)], "服务端", opts);
  let client = null;
  let client2 = null;
  try {
    await waitFor(server, "监听 UDP", timeoutMs);
    assertions.push("服务端开始监听");

    client = launch(
      godot,
      // 自动驾驶让客户端的角色沿自己的出生 Z 坐标来回移动。它的路线穿过「霜池」，
      // 而客户端拿到的是槽位 0、元素为熔，因此会被反复复位——下面那一条断言就靠它。
      [...base, "--join", "127.0.0.1", "--port", String(opts.port), "--autopilot"],
      "客户端",
      opts,
    );
    await waitFor(client, "已连接到主机", timeoutMs);
    assertions.push("客户端连接成功");

    // 客户端 peer id 由引擎随机分配（不一定是 2），所以从日志里取出来再用。
    const [, peerId] = await waitForMatch(server, /\[session\] peer (\d+) 已连接/, timeoutMs);
    assertions.push(`服务端收到客户端连接（peer ${peerId}）`);

    // 服务端应当按连接的 peer 生成角色，而不是把自己也当成玩家。
    await waitFor(server, `生成玩家 ${peerId}`, timeoutMs);
    assertions.push("服务端按连接的 peer 生成了角色");

    // 客户端应当收到那个生成包：它自己那份角色的 peer id 等于自己的 id，
    // 于是被判为本机角色。这一条同时说明 MultiplayerSynchronizer 已按预期注册。
    await waitFor(client, `本机角色 peer=${peerId} 已就位`, timeoutMs);
    assertions.push("客户端收到自己的角色（生成同步生效）");

    // 观察客户端角色的那一侧是服务端，所以平滑启用的证据要从服务端的日志里核对。
    // 这一条的价值在于区分"平滑没起作用"与"跑的是不带平滑的旧代码"——
    // 后者在日志里根本不会出现这一行。
    await waitFor(server, "时钟调速平滑", timeoutMs);
    assertions.push("服务端侧的远端角色启用了显示平滑");

    // 元素地形：客户端的自动驾驶路线穿过「霜池」，而它的元素是熔，因此应当被复位。
    // 这一条同时验证三件事：元素按槽位分配且两端一致、本机地形判定生效、
    // 复位后的位置经同步传播（服务端的 瞬移 计数与它是同一件事的两个视角）。
    await waitForMatch(
      client,
      /\[player\] peer=\d+ \S+ 角色进入「.+」，回到出生点/,
      timeoutMs,
    );
    assertions.push("客户端角色进入异元素池子后被复位");

    // 按钮判定在服务端，判据是"本元素角色站在按钮范围内"。客户端的自动驾驶路线
    // 从自己的出生点经过自己元素的按钮，所以服务端应当收到一次踩下。
    // 这一条同时说明按钮的检测范围与车道对得上（范围放得过大会误触发，过小则踩不到）。
    await waitFor(server, "[button] 熔 按钮被踩下", timeoutMs);
    assertions.push("服务端判定客户端踩下了熔按钮");

    // 另一个按钮在 z=2 车道上，而客户端在 z=4，因此只有一个按钮被踩住。
    // 门是"全部按钮同时被踩住"才开，所以它不该打开——这一条守的是判据本身。
    if (server.text.includes("[gate] 门已打开")) {
      throw new Error("只有一个按钮被踩住，门却打开了");
    }
    assertions.push("只有一个按钮被踩住时门不打开");

    // 第二个客户端拿到槽位 1，元素是霜；它的车道经过霜按钮。
    // 两个客户端各自在自己的按钮上反复踩下与离开，因此迟早会出现"两个按钮同时被踩住"的
    // 一瞬间——门就是在那一刻打开的。这是整个协同机关唯一的正向验证：
    // 元素按槽位分配、按钮判定在服务端、门的判据是全部按钮、状态广播回两端。
    client2 = launch(
      godot,
      [...base, "--join", "127.0.0.1", "--port", String(opts.port), "--autopilot"],
      "客户端２",
      opts,
    );
    await waitFor(server, "[button] 霜 按钮被踩下", timeoutMs);
    assertions.push("第二个客户端按槽位拿到霜元素并踩下霜按钮");

    await waitFor(server, "[gate] 门已打开", timeoutMs);
    assertions.push("两个按钮同时被踩住时门在服务端打开");

    // 门的状态由服务端广播。它决定玩家能不能通过，因此必须到达客户端。
    await waitFor(client, "[gate] 门已打开", timeoutMs);
    assertions.push("门的状态广播到了客户端");

    // 机关门的初始状态由两端各自在 _ready 里应用（不走 rpc，因为那时还没有 peer）。
    for (const state of [server, client]) {
      if (!state.text.includes("[gate] 门已关闭")) {
        throw new Error(`${state.label} 没有应用机关门的初始状态`);
      }
    }
    assertions.push("两端都应用了机关门的初始状态");

    // 无头启动必须是专用服务端语义：不给自己生成角色。
    if (server.text.includes("本机角色")) {
      throw new Error("专用服务端不该生成本机角色，但服务端日志里出现了「本机角色」");
    }
    assertions.push("专用服务端未生成本机角色");

    // 走到这里说明客户端跑过若干物理帧而没有报错，输入映射也就一并验证了：
    // 缺动作时 Input.get_axis 会直接把错误写进日志。
    for (const state of [server, client, client2]) {
      if (state.exited) throw new Error(`${state.label} 意外退出，退出码 ${state.exitCode}`);
    }
    assertions.push("三个实例均在运行且控制台无脚本错误");

    say("");
    for (const line of assertions) say(`  ok  ${line}`);
    say("\n冒烟测试通过。");
  } catch (err) {
    say(`\n冒烟测试失败：${err.message}\n`);
    say(`--- 服务端输出（末 30 行）---\n${tail(server.text)}`);
    if (client) say(`\n--- 客户端输出（末 30 行）---\n${tail(client.text)}`);
    if (client2) say(`\n--- 客户端２输出（末 30 行）---\n${tail(client2.text)}`);
    process.exitCode = 1;
  } finally {
    if (client2) stop(client2);
    if (client) stop(client);
    stop(server);
  }
}

main().catch((err) => {
  process.stderr.write(`${err.message}\n`);
  process.exitCode = 1;
});
