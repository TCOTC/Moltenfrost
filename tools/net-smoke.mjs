#!/usr/bin/env node
// 熔霜 · 联机冒烟测试
//
// 两段检查：
//   1. 插值逻辑测试（tests/remote_interpolator_test.gd）：不联网，验证收到位置快照后的取样是否均匀。
//   2. 双实例检查：无头起一个专用服务端与一个客户端，各断言一次连接与角色生成。
//
// 它覆盖的是"连接是否建立、角色是否被生成并同步到对端、远端显示是否平滑"，
// 不覆盖手感与延迟——那两件事只能由人在真机上判断，并配合网络损伤注入
//（见 memory/networking.md）。
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
  const proc = spawnSync(godot, args, { cwd: PROJECT_DIR, encoding: "utf8" });
  const output = `${proc.stdout || ""}${proc.stderr || ""}`;
  if (opts.verbose) process.stdout.write(output);
  const fatal = FATAL_PATTERNS.find((p) => output.includes(p));
  if (fatal) throw new Error(`${label}的输出里出现「${fatal}」\n${tail(output)}`);
  if (proc.status !== 0) throw new Error(`${label}退出码 ${proc.status}\n${tail(output)}`);
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

  const server = launch(godot, [...base, "--host", "--port", String(opts.port)], "服务端", opts);
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
  } catch (err) {
    say(`\n冒烟测试失败：${err.message}\n`);
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
