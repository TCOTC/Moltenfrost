#!/usr/bin/env node
// 熔霜 · 交付前自检
//
// 三段检查，按"越基础越先跑"排列：
//   1. 纯逻辑测试：插值取样、局域网房间探测、初始界面接线、产品常量、关卡判定几何。
//      都不联网（前四项用 `--script`，关卡玩法那一项以场景为入口），单独跑也很有用。
//   2. 关卡规则：把一关从头跑到尾——元素交换、死亡复活、造冰融冰、积分、通关、重开。
//   3. 双实例检查：无头起一个专用服务端与一个客户端，各断言一次连接与角色生成。
//
// 它覆盖的是"连接是否建立、角色是否被生成并同步到对端、远端显示是否平滑、
// 关卡规则本身是否自洽"，不覆盖手感与延迟——那两件事只能由人在真机上判断，
// 并配合网络损伤注入（见 memory/networking.md），也不覆盖"两台机器看见的是不是同一张图"
//（那需要两台机器一起跑，见 docs/机制与玩法设计.md）。
//
// 用法：
//   node tools/net-smoke.mjs
//   node tools/net-smoke.mjs --godot <Godot 可执行文件>   # 不给则自动探测，取值顺序见 memory/README.md
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

// 单个 --script 检查的上限（毫秒）。正常情况几秒内结束；
// 给足余量的同时保证卡住时能快速失败而不是无限等待。
const SCRIPT_TEST_TIMEOUT_MS = 120000;

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
// 两处遵守同一套取值顺序（见 memory/README.md）：值只存在 memory/local-env.json，不入库，
// 因为别人的 Godot 装在哪与你无关。
function localEnvJson() {
  const file = path.join(PROJECT_DIR, "memory", "local-env.json");
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    return {}; // 没这个文件是正常的
  }
  // 记事本与 PowerShell 5.1 的 Set-Content -Encoding utf8 会写 BOM，带 BOM 解不了。
  try {
    const parsed = JSON.parse(raw.replace(/^\uFEFF/, ""));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (e) {
    process.stderr.write(`${file} 不是合法 JSON（${e.message}），本次忽略它。\n`);
    return {};
  }
}

function detectGodot() {
  const local = localEnvJson();
  const candidates = [];
  const pinned = process.env.GODOT_BIN || local.GODOT_BIN;
  if (pinned) candidates.push(pinned);
  if (process.platform === "win32") {
    candidates.push("godot.exe", "godot4.exe");
    // 解压即用的 Godot 不会出现在 PATH 里，要扫哪些目录由本机在 local-env.json 里自己声明。
    const dirs = local.GODOT_SCAN_DIRS;
    for (const root of Array.isArray(dirs) ? dirs : dirs ? [dirs] : []) {
      try {
        if (!fs.existsSync(root)) continue;
        for (const dir of fs.readdirSync(root)) {
          const full = path.join(root, dir);
          if (!fs.statSync(full).isDirectory()) continue;
          for (const f of fs.readdirSync(full)) {
            if (/^Godot_v.*console\.exe$/i.test(f)) candidates.push(path.join(full, f));
          }
        }
      } catch { /* 探不到就算了 */ }
    }
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
  if (state === null || state === undefined || state.exited) return;
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

// 失败时只看末尾若干行会漏掉最该看的那一条：驱动器把「哪一条断言不成立」打在
// **比末尾更靠上**的位置（它后面还会打印别的），于是关键行恰好被截掉。
// 实测因此多跑了三轮（日志里只有「有断言不成立」，看不到是哪一条）。
// 所以除了末尾若干行，再把所有断言/错误行一并附上——它们才是要读的东西。
function diag(text, lines = 15) {
  const all = text.split(/\r?\n/);
  // 把带标记的行（[drive]/[lobby]/[session]/[player]…）全带上，不只是 [drive]：
  //   「驱动器读到 0 人」这一个现象，光是 [drive] 那几条看不出是名单没到、
  //   还是名单到了但是空的 —— 而 [lobby] 那行直接给出答案（"名单：N 人"）。
  const picked = all.filter((s) => /\[[a-z_]+\]|ERROR|失败|超时/.test(s));
  const pickedText = picked.join("\n");
  const tailText = tail(text, lines);
  return pickedText === tailText ? tailText : `${tailText}\n--- 上面全部带标记的行 ---\n${pickedText}`;
}

// 纯逻辑检查：按 `--script` 或“以场景为入口”跑一个检查脚本，
// 从输出里取“通过（N 项断言）”这一行。几个检查共用这段流程。
// 以场景为入口的那一项要在 `--` 之后传参数，因此这里也支持 userArgs。
function runScriptTest(godot, opts, { target, label, passPattern, userArgs = [] }) {
  const args = ["--headless", "--path", PROJECT_DIR];
  if (target.endsWith(".tscn")) {
    // 以场景为入口：与真正的启动方式走同一条路径，自动加载单例因此可用。
    args.push(target);
  } else {
    args.push("--script", target);
  }
  if (userArgs.length > 0) args.push("--", ...userArgs);
  // **必须给超时。** 检查脚本若卡住（例如调用了不存在的函数、报错之后没走到 quit），
  // spawnSync 会永远等下去，于是整个冒烟测试也永远不结束——既没有输出也没有退出码，
  // 看起来像"网络慢"而不是"脚本坏了"。实测踩过一次。
  const res = spawnSync(godot, args, {
    cwd: PROJECT_DIR,
    encoding: "utf8",
    timeout: SCRIPT_TEST_TIMEOUT_MS,
  });
  const output = `${res.stdout || ""}${res.stderr || ""}`;
  if (opts.verbose) process.stdout.write(output);
  if (res.error && res.error.code === "ETIMEDOUT") {
    throw new Error(
      `${label}超过 ${SCRIPT_TEST_TIMEOUT_MS / 1000} 秒未结束，已中止。` +
      `常见原因是脚本报错之后没有走到 quit()（检查它是否调用了不存在的函数）。\n${tail(output)}`,
    );
  }
  const fatal = FATAL_PATTERNS.find((p) => output.includes(p));
  if (fatal) throw new Error(`${label}的输出里出现「${fatal}」\n${tail(output)}`);
  if (res.status !== 0) throw new Error(`${label}退出码 ${res.status}\n${tail(output)}`);
  const m = passPattern.exec(output);
  if (!m) throw new Error(`${label}没有报告通过\n${tail(output)}`);
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

  const interpolationChecks = runScriptTest(godot, opts, {
    target: "tests/remote_interpolator_test.gd",
    label: "插值测试",
    passPattern: /插值逻辑测试通过（(\d+) 项断言）/,
  });
  assertions.push(`插值取样保持均匀（${interpolationChecks} 项断言）`);

  // 房间探测同样用真实的 UDP 走一遍：同一台机器上的两个实例要能互相发现，
  // 这是"主机开房间、另一台在界面上选房"这条路径的最小可验证形式。
  const discoveryChecks = runScriptTest(godot, opts, {
    target: "tests/lan_discovery_test.gd",
    label: "房间探测测试",
    passPattern: /局域网房间探测测试通过（(\d+) 项断言）/,
  });
  assertions.push(`局域网房间探测可用（${discoveryChecks} 项断言）`);

  // 初始界面的接线：按钮点下去有没有发出正确的信号。界面外观要人眼看，这一层只能自动验证。
  const menuChecks = runScriptTest(godot, opts, {
    target: "tests/menu_test.gd",
    label: "初始界面测试",
    passPattern: /初始界面接线测试通过（(\d+) 项断言）/,
  });
  assertions.push(`初始界面接线正确（${menuChecks} 项断言）`);

  // 产品常量（config/product.cfg）的取值与回退。
  // 单独一项检查的理由见那个文件的说明：读不到文件时会静默回退到与文件内容相同的兜底值，
  // 于是不管走哪条路径界面都一样，只能靠断言来源来发现。
  const configChecks = runScriptTest(godot, opts, {
    target: "tests/product_config_test.gd",
    label: "产品常量测试",
    passPattern: /产品常量测试通过（(\d+) 项断言）/,
  });
  assertions.push(`产品常量读取与回退正确（${configChecks} 项断言）`);

  // 关卡的判定几何。不联网，但它是"看起来站在岸上、实际算在水里"这类错误的唯一防线，
  // 因此放在联机检查之前——关卡摆错了，后面两条联机检查跑起来也没意义。
  const levelChecks = runScriptTest(godot, opts, {
    target: "tests/level_test.gd",
    label: "关卡几何测试",
    passPattern: /关卡几何测试通过（(\d+) 项断言）/,
  });
  assertions.push(`关卡判定几何自洽（${levelChecks} 项断言）`);

  // 一关的规则跑一遍：元素分配与交换、致命介质→死亡→按检查点复活、造冰与融冰、
  // 积分结算、两人同时进出口、关卡重开。以场景为入口，因为 `--script` 下没有自动加载单例。
  const gameChecks = runScriptTest(godot, opts, {
    target: "tests/game_test.tscn",
    label: "关卡玩法测试",
    passPattern: /关卡玩法测试通过（(\d+) 项断言）/,
  });
  assertions.push(`关卡规则自洽（${gameChecks} 项断言）`);

  // 连一个没有服务端的地址。ENet 建客户端是即时的，要等超时才报 connection_failed，
  // 这段"正在连接"的窗口里若往尚未连接的 peer 发 RPC，引擎会每秒刷一条错误。
  // 界面上填错地址是最常见的失败方式，所以这一段要有覆盖。
  const orphanPort = opts.port + 1;
  const orphan = launch(
    godot,
    [...base, "--join", "127.0.0.1", "--port", String(orphanPort)],
    "连不上的客户端",
    opts,
  );
  try {
    await waitFor(orphan, "[session] 启动参数", timeoutMs);
    // 跨过至少一个时延探测周期（1 秒）。
    await new Promise((resolve) => setTimeout(resolve, 3000));
    if (orphan.text.includes("not connected")) {
      throw new Error("往尚未连接的 peer 发 RPC 会刷引擎错误，日志里出现了「not connected」");
    }
  } finally {
    stop(orphan);
  }
  assertions.push("连接尚未建立时不刷 RPC 错误");

  // 晚加入：主机在没人旁观时打掉冰墙、拿掉一个积分点、通关，然后客户端才连上来。
  // 这三件事都只通过一次性 RPC 通知当时在场的 peer，因此晚加入的人必须靠一份状态快照补上
  //（Game.catch_up）。漏了它不会报任何错，症状只是"客户端立着一面服务端不认的墙，
  // 而主机那边的人径直走了过去"——只有两进程一起跑才看得见。
  //
  // **必须等主机改完世界再启动客户端**，否则客户端会收到那次广播、这个测试就白跑了。
  // **两个进程都必须是后台进程**，不能用 spawnSync 跑客户端：
  // spawnSync 会把 Node 的事件循环卡住，这段时间没人读主机的 stdout，
  // 主机的管道写满之后就在 print 上阻塞，表现为"客户端连上了、主机却没了心跳"。
  // 实测踩过一次，症状与真 bug 一模一样。
  const latePort = opts.port + 3;
  const lateScene = "res://tests/late_join_test.tscn";
  const lateBase = ["--headless", "--path", PROJECT_DIR, lateScene, "--"];
  const lateHost = launch(
    godot,
    [...lateBase, "--phase", "host", "--port", "0", "--target-port", String(latePort)],
    "晚加入测试主机",
    opts,
  );
  let lateClient = null;
  try {
    await waitFor(lateHost, "[late] 主机已在无人旁观时改掉世界", timeoutMs);
    lateClient = launch(
      godot,
      [...lateBase, "--phase", "join", "--port", "0", "--target-port", String(latePort)],
      "晚加入测试客户端",
      opts,
    );
    try {
      const m = await waitForMatch(lateClient, /晚加入状态补齐测试通过（(\d+) 项断言）/, timeoutMs);
      assertions.push(`晚加入的 peer 能补齐世界状态（${Number(m[1])} 项断言）`);
    } catch (e) {
      // 这一项要两个进程配合，只看到一侧的输出时分不清是"快照没发"还是"主机根本没在跑"，
      // 因此失败时把两边的日志都带出来。
      throw new Error(
        `${e.message}\n--- 客户端（末 20 行）---\n${tail(lateClient.text, 20)}` +
        `\n--- 主机（末 20 行）---\n${tail(lateHost.text, 20)}`,
      );
    }
  } finally {
    stop(lateClient);
    stop(lateHost);
  }

  // 对局事件的送达。Game 的广播绕开了 Node.rpc()（逐 peer 调 rpc_id），
  // 那条路不通时症状是"对端什么都看不到"且**不报任何错**——本地单机测试与
  // 前面的单元测试都覆盖不到，只有两台一起跑才看得见，因此单独一项。
  const probePort = opts.port + 2;
  const probeScene = "res://tests/rpc_probe.tscn";
  const probeServer = launch(
    godot,
    ["--headless", "--path", PROJECT_DIR, probeScene, "--", "--host", "--port", String(probePort)],
    "RPC 探针服务端",
    opts,
  );
  let probeClient = null;
  try {
    await waitFor(probeServer, "监听 UDP", timeoutMs);
    probeClient = launch(
      godot,
      ["--headless", "--path", PROJECT_DIR, probeScene, "--",
        "--join", "127.0.0.1", "--port", String(probePort)],
      "RPC 探针客户端",
      opts,
    );
    await waitFor(probeClient, "探针：客户端收到积分同步", timeoutMs);
    assertions.push("对局事件能通过 _broadcast 送到对端");
  } finally {
    if (probeClient) stop(probeClient);
    stop(probeServer);
  }

  // 会话生命周期：创建房间 → 回到初始界面 → 再创建房间。
  // 这一项以场景为入口，因为 `--script` 运行时不注册自动加载单例。
  const sessionChecks = runScriptTest(godot, opts, {
    target: "tests/session_test.tscn",
    label: "会话生命周期测试",
    passPattern: /会话生命周期测试通过（(\d+) 项断言）/,
    // 入口脚本会按项目设置监听默认端口，而开发实例平时占着它。
    userArgs: ["--port", "0"],
  });
  assertions.push(`会话可以重开且不残留角色（${sessionChecks} 项断言）`);

  // 大厅流程：两人进同一间房 → 都看到 2 人 → 先到的那个是房主 →
  // **房主请求开局 → 两端都进关且各生成一个角色**。
  //
  // 为什么要单独一项：`--host`/`--join` 走的都是"连上即开局"，上面那些双实例检查
  // 因此全都盖不到"人齐才开局"这条路径。而它是需求的核心，接线时这一段一共暴露出
  // 四个 bug（房主在客户端点了没反应、服务端从不下发名单、客户端自己造名单、
  // RPC 路径不一致导致静默失败），每一个在日志上都表现为"什么也没发生"。
  //
  // 用本机房间 + 两个驱动器，不需要目录，因此任何平台都能跑。
  // 目录那一层（登记的实时取值、满房判定、名字的 UTF-8 往返、房间回到 waiting）
  // 由 tools/directory-check.sh 在服务器上手工验（要有 Linux 与 ssh），
  // 跨平台的部分则由 python3 tools/room-directory.py --selftest 覆盖，见 docs/公网房间方案.md 7.0。
  await (async () => {
    const lobbyPort = opts.port + 5;
    const lobbyServer = launch(
      godot,
      [...base, "--host", "--port", String(lobbyPort), "--lobby"],
      "大厅服务端",
      opts,
    );
    const drivers = [];
    try {
      await waitFor(lobbyServer, "监听 UDP", timeoutMs);
      // 驱动器就是"在无头环境里替真人点那个按钮"。两端跑同一个场景，
      // 各自按自己的角色行事：房主在名单达到 2 人时请求开局，另一端什么都不做。
      //
      // `--escape` 再验一段：开局之后房主按 Esc → 两端回等待房间、房主不变、
      // 而且能再开一局。那一段是"局中 Esc 不该退出房间"这条需求的自动检查。
      const driverArgs = () => [
        "--headless", "--path", PROJECT_DIR, "res://tests/lobby_start_drive.tscn",
        "--", "--join", "127.0.0.1", "--port", String(lobbyPort), "--lobby", "--escape",
      ];
      const first = launch(godot, driverArgs(), "驱动器 1", opts);
      drivers.push(first);
      // 错开 4 秒再起第二个：两边同时连会让"谁先到"变得不确定，
      // 而这项检查要断言的恰恰是"先到的那个成为房主"。
      await new Promise((r) => setTimeout(r, 4000));
      const second = launch(godot, driverArgs(), "驱动器 2", opts);
      drivers.push(second);

      // 驱动器自己会退出（通过 quit(0)/quit(1)），所以这里等的是退出而不是某个字符串。
      const deadline = Date.now() + 60000;
      while (drivers.some((d) => !d.exited) && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 200));
      }
      const stuck = drivers.filter((d) => !d.exited);
      if (stuck.length > 0) {
        throw new Error(
          `${stuck.map((d) => d.label).join("、")}在 60 秒内没有退出，` +
          `说明大厅流程卡住了（末 12 行）：\n${tail(stuck[0].text, 12)}`,
        );
      }
      for (const driver of drivers) {
        if (driver.exitCode !== 0) {
          throw new Error(
            `${driver.label}退出码 ${driver.exitCode}，说明它没走完大厅流程：\n` +
            diag(driver.text),
          );
        }
      }
      // 两端的断言内容不同，因此分别查：
      //   先到的那个必须是房主，且必须**由它**发出开局请求
      //   另一端必须收到开局通知（只查房主那侧证明不了广播真的到了客户端）
      if (!/我是房主/.test(first.text)) {
        throw new Error(`先到的那个没有成为房主（末 12 行）：\n${tail(first.text, 12)}`);
      }
      if (!/请求开局/.test(first.text)) {
        throw new Error(`房主没有请求开局（末 12 行）：\n${tail(first.text, 12)}`);
      }
      if (!/名单：2 人/.test(first.text)) {
        throw new Error(
          `先到的那一端没有看到 2 个人，两人可能被分到了不同房间（末 12 行）：\n` +
          tail(first.text, 12),
        );
      }
      assertions.push("大厅里两人同房、先到的成为房主并请求开局");
      assertions.push("人齐后两端都进关，且各看到 2 个角色");

      // Esc 那一段。**两端都要看到"回到等待房间"**：只查房主那侧只能证明它自己
      // 切了屏，而"那个通知真的广播到了客户端"才是这条 RPC 的价值。
      for (const driver of drivers) {
        if (!/回到等待房间/.test(driver.text)) {
          throw new Error(
            `${driver.label}没有回到等待房间：\n${diag(driver.text)}`,
          );
        }
        if (!/OK: 第二局场上也是 2 个角色/.test(driver.text)) {
          throw new Error(
            `${driver.label}没走完"回房间 → 再开一局"：\n${diag(driver.text)}`,
          );
        }
      }
      if (!/OK: 回到房间后名单里还有 2 人/.test(first.text)) {
        throw new Error(`房主按 Esc 之后名单丢了：\n${diag(first.text)}`);
      }
      if (!/OK: 回到房间后房主没变/.test(first.text)) {
        throw new Error(
          `回到房间后房主变了（_join_order 被清掉的话 host_id() 会是 0，` +
          `于是谁也开不了下一局）：\n${diag(first.text)}`,
        );
      }
      assertions.push("局中按 Esc 回到等待房间：两端都在、房主不变、还能再开一局");
    } finally {
      for (const driver of drivers) stop(driver);
      stop(lobbyServer);
    }
  })();

  const server = launch(
    godot,
    [...base, "--host", "--port", String(opts.port), "--element", "frost"],
    "服务端",
    opts,
  );
  let client = null;
  try {
    await waitFor(server, "监听 UDP", timeoutMs);
    assertions.push("服务端开始监听");

    client = launch(
      godot,
      [...base, "--join", "127.0.0.1", "--port", String(opts.port)],
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

    // 元素随生成包一起送达。这里用 `--element frost` 把 0 号槽位指定成霜：
    // 无头启动的服务端是**专用服务端**，本机没有角色，因此场上唯一的那个角色
    // 就是客户端的，槽位为 0。固定住取值之后，"客户端看到的是霜"才是一条有内容的断言——
    // 否则它只在默认分配下成立，而默认分配会随谁先连接而变。
    // 元素不一致时两个人玩的是两张图，且不会报任何错，只能靠日志核对。
    await waitFor(client, `本机角色 peer=${peerId} 已就位（霜）`, timeoutMs);
    assertions.push("元素随生成包送达（--element 生效）");

    // 观察客户端角色的那一侧是服务端，所以平滑启用的证据要从服务端的日志里核对。
    // 这一条的价值在于区分"平滑没起作用"与"跑的是不带平滑的旧代码"——
    // 后者在日志里根本不会出现这一行。
    await waitFor(server, "时钟调速平滑", timeoutMs);
    assertions.push("服务端侧的远端角色启用了显示平滑");

    // 无头启动必须是专用服务端语义：不给自己生成角色。
    if (server.text.includes("本机角色")) {
      throw new Error("专用服务端不该生成本机角色，但服务端日志里出现了「本机角色」");
    }
    assertions.push("专用服务端未生成本机角色");

    // 走到这里说明客户端跑过若干物理帧而没有报错，输入映射也就一并验证了：
    // 缺动作时 Input.get_axis 会直接把错误写进日志。
    for (const state of [server, client]) {
      if (state.exited) throw new Error(`${state.label} 意外退出，退出码 ${state.exitCode}`);
    }
    assertions.push("两个实例均在运行且控制台无脚本错误");

    // 服务端被强制结束时，客户端必须自己能发现并给出提示。
    // 进程没了不会发任何包，UDP 也没有 FIN 之类的收尾，只能由客户端的心跳判定兜住。
    // 所以这里断言原因文案是"失去联系"，用来区分是心跳那条路径生效，
    // 而不是被其他机制顺带掩盖过去。
    // stop() 在 Windows 上走 taskkill /F，等价于强杀，正是要模拟的场景。
    const killedAt = Date.now();
    stop(server);
    await waitFor(client, "失去联系", 20000);
    const detectedSeconds = (Date.now() - killedAt) / 1000;
    if (detectedSeconds > 15) {
      throw new Error(
        `服务端被强制结束后客户端用了 ${detectedSeconds.toFixed(1)} 秒才发现，超过 15 秒上限`,
      );
    }
    assertions.push(
      `服务端被强制结束后由心跳判定下线（${detectedSeconds.toFixed(1)} 秒）`,
    );

    // 服务端**自行退出**（走 _exit_tree）时，客户端应当在心跳阈值之前就知道，
    // 而不是等心跳兜底。这一条守住的是 close() 之前那次 poll()：
    // 少了它，ENet 的断开通知会留在队列里随进程消失，功能上仍然"能用"
    //（5 秒后心跳会发现），因此不会报错，只会让每次正常停服白等 5 秒。
    // 用 --quit-after 让服务端自己走正常退出流程；它是引擎参数，必须放在 `--` 之前。
    const gracefulPort = opts.port + 3;
    const gracefulServer = launch(
      godot,
      ["--headless", "--path", PROJECT_DIR, "--quit-after", "1500", "--",
       "--host", "--port", String(gracefulPort)],
      "自行退出的服务端",
      opts,
    );
    let gracefulClient = null;
    try {
      await waitFor(gracefulServer, "监听 UDP", timeoutMs);
      gracefulClient = launch(
        godot,
        [...base, "--join", "127.0.0.1", "--port", String(gracefulPort)],
        "等断开通知的客户端",
        opts,
      );
      await waitFor(gracefulClient, "已连接到主机", timeoutMs);

      // 等服务端自己退出。--quit-after 计的是帧数，无头下帧率不固定，因此只等结果。
      const exitDeadline = Date.now() + 60000;
      while (!gracefulServer.exited && Date.now() < exitDeadline) {
        await new Promise((resolve) => setTimeout(resolve, 200));
      }
      if (!gracefulServer.exited) throw new Error("服务端在 60 秒内没有自行退出");
      const exitedAt = Date.now();

      await waitFor(gracefulClient, "与主机断开", 20000);
      const notifySeconds = (Date.now() - exitedAt) / 1000;
      if (notifySeconds >= 5.0) {
        throw new Error(
          `服务端自行退出后，客户端用了 ${notifySeconds.toFixed(1)} 秒才发现，` +
          `说明是心跳超时（5 秒）在兜底——检查 net.gd 的 shutdown_gracefully() 里那行 poll()。`,
        );
      }
      assertions.push(`服务端自行退出时客户端不等心跳即发现（${notifySeconds.toFixed(1)} 秒）`);
    } finally {
      if (gracefulClient) stop(gracefulClient);
      stop(gracefulServer);
    }

    say("");
    for (const line of assertions) say(`  ok  ${line}`);
    say("\n冒烟测试通过。");
    // **额外一行纯 ASCII 的判定标记。** 中文结论在 PowerShell 管道里会变成乱码，
    // 实测因此出现过"跑完看不出结果、换一种读法再跑一遍"的重复执行（一次 110 秒）。
    // 判定本身看退出码即可，但一行 ASCII 摘要让肉眼与脚本都能只认它。
    say(`ALL PASS (${assertions.length} checks)`);
  } catch (err) {
    say(`\n冒烟测试失败：${err.message}\n`);
    say(`FAIL (${err.message})`);
    say(`--- 服务端输出（末 30 行）---\n${tail(server.text)}`);
    if (client) say(`\n--- 客户端输出（末 30 行）---\n${tail(client.text)}`);
    process.exitCode = 1;
  } finally {
    if (client) stop(client);
    stop(server);
  }
}

main().catch((err) => {
  process.stderr.write(`${err.message}\n`);
  process.exitCode = 1;
});
