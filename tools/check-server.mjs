#!/usr/bin/env node
// 熔霜 · 联机服务器验收检查
//
// 对一台**已经部署好**的服务器做端到端检查，全流程都经真实公网：
//   1. SSH 可达
//   2. 服务在跑，并在监听游戏端口
//   3. 客户端经域名（而不是 IP）连得上
//   4. 拿到 RTT，说明位置同步的数据在双向流动
//   5. **服务端正常停止时客户端立刻收到断开通知**（这条最容易被改坏）
//   6. 检查结束后把服务恢复成运行状态
//
// 第 5 条为什么要单独查：客户端有两条得知服务端下线的路径——服务端主动告知，
// 以及客户端自己的心跳超时（5 秒）。前者是正常停止时的路径，后者是进程被强杀时的兜底。
// 如果 `_exit_tree` 里的主动断开失效，功能上仍然"能用"（5 秒后心跳会发现），
// 因此不会报错、也不会有人注意，只是每次正常停服都要让玩家白等 5 秒。
// 这里断言它短于心跳阈值，正是为了区分这两条路径。
//
// 用法：
//   node tools/check-server.mjs --host 106.52.118.93 --advertise moltenfrost-server.mytemos.com
//
// 退出码 0 表示全部通过。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// 出现这些字样即视为失败，不等待断言超时。
const FATAL_PATTERNS = ["SCRIPT ERROR", "Parse Error", "Invalid access to property", "Invalid call"];

// 与 scripts/net/net.gd 的 HEARTBEAT_TIMEOUT 对应。客户端自己判定下线要等这么久，
// 因此"正常停止"的检测必须明显快于它，否则说明主动告知那条路径没生效。
const HEARTBEAT_TIMEOUT_MS = 5000;
const GRACEFUL_BUDGET_MS = 3500;

const HELP = `熔霜 · 联机服务器验收检查

  node tools/check-server.mjs --host <地址> [选项]

  --host <地址>        服务器公网地址（SSH 用），必填
  --advertise <地址>   客户端要连的地址（域名）。不给则用 --host
  --user <用户名>      SSH 用户，默认 ubuntu
  --key <私钥路径>     SSH 私钥，默认 ~/.ssh/id_ed25519_moltenfrost
  --port <端口>        游戏端口，默认 27015
  --service <名字>     systemd 单元前缀，默认 moltenfrost
  --godot <路径>       Godot 可执行文件，默认自动探测
  --verbose            把客户端与 SSH 的输出实时打出
  -h, --help           显示本帮助
`;

function parseArgs(argv) {
  const opts = {
    host: process.env.MOLTENFROST_HOST || null,
    advertise: null,
    user: process.env.MOLTENFROST_SSH_USER || "ubuntu",
    key: process.env.MOLTENFROST_SSH_KEY || path.join(os.homedir(), ".ssh", "id_ed25519_moltenfrost"),
    port: 27015,
    service: "moltenfrost",
    godot: process.env.GODOT_BIN || null,
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
      case "--host": opts.host = next(); break;
      case "--advertise": opts.advertise = next(); break;
      case "--user": opts.user = next(); break;
      case "--key": opts.key = next(); break;
      case "--port": opts.port = Number(next()); break;
      case "--service": opts.service = next(); break;
      case "--godot": opts.godot = next(); break;
      case "--verbose": opts.verbose = true; break;
      case "-h": case "--help": opts.help = true; break;
      default: throw new Error(`未知参数：${arg}`);
    }
  }
  return opts;
}

// 与 tools/net-smoke.mjs 里的同名函数一样：那边要能启动就好，这边同样只需要能启动。
// 两处各自保留一份，避免为共用而牵动那个已经稳定的脚本。
function detectGodot() {
  const candidates = [];
  if (process.env.GODOT_BIN) candidates.push(process.env.GODOT_BIN);
  if (process.platform === "win32") {
    candidates.push("godot.exe", "godot4.exe");
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

// ---------------------------------------------------------------- 工具

function makeSsh(opts) {
  return (remoteCommand) => {
    const args = [
      "-i", opts.key,
      "-o", "StrictHostKeyChecking=accept-new",
      "-o", "ServerAliveInterval=15",
      "-o", "ConnectTimeout=15",
      `${opts.user}@${opts.host}`,
      remoteCommand,
    ];
    if (opts.verbose) process.stdout.write(`$ ssh … ${remoteCommand}\n`);
    const res = spawnSync("ssh", args, { encoding: "utf8" });
    if (res.status !== 0) {
      throw new Error(`远程命令失败（退出码 ${res.status}）：${remoteCommand}\n${res.stderr || ""}`);
    }
    return (res.stdout || "").trim();
  };
}

function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }

// 在给定上限内轮询文本，命中就返回耗时，超时返回 -1。
async function waitForText(read, needle, timeoutMs, pollMs = 200) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (read().includes(needle)) return Date.now() - startedAt;
    await sleep(pollMs);
  }
  return -1;
}

// ---------------------------------------------------------------- 主流程

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) { process.stdout.write(HELP); return; }
  if (!opts.host) throw new Error("必须用 --host <地址> 指定服务器。");

  const godot = opts.godot || detectGodot();
  if (!godot) throw new Error("找不到 Godot 可执行文件。用 --godot <路径> 指定，或设置 GODOT_BIN。");

  const target = opts.advertise || opts.host;
  const unit = `${opts.service}@${opts.port}`;
  const ssh = makeSsh(opts);
  const assertions = [];
  const say = (msg) => process.stdout.write(`${msg}\n`);

  say(`服务器：${opts.host}    客户端连接目标：${target}:${opts.port}`);
  say(`Godot：${godot}\n`);

  // 1. SSH
  ssh("true");
  assertions.push("SSH 可达");

  // 2. 服务在跑。若不在跑就启动，并等它在监听。
  //    "在跑"与"在监听"是两件事：Godot 启动要几秒，只看 systemctl 会误判。
  const active = ssh(`systemctl is-active ${unit} || true`);
  if (active !== "active") {
    say(`（服务当前是 ${active}，正在启动）`);
    ssh(`sudo systemctl start ${unit}`);
  }
  ssh(`sudo systemctl is-active --quiet ${unit}`);
  let listening = false;
  for (let i = 0; i < 30; i++) {
    // ss 在最小安装里可能没有，因此退回用 /proc/net/udp 判断。
    const out = ssh(`sudo ss -lun 2>/dev/null | grep -c ':${opts.port}\\b' || grep -ci ':${opts.port.toString(16).toUpperCase()}' /proc/net/udp || true`);
    if (Number(out) > 0) { listening = true; break; }
    await sleep(1000);
  }
  if (!listening) throw new Error(`服务在跑，但没有看到监听 UDP ${opts.port}`);
  assertions.push(`服务在运行并监听 UDP ${opts.port}`);

  // 3~5. 起一个客户端，做完检查后收回。
  const state = { text: "", exited: false, exitCode: null };
  const child = spawn(
    godot,
    ["--headless", "--path", PROJECT_DIR, "--", "--join", target, "--port", String(opts.port), "--net-stats"],
    { cwd: PROJECT_DIR, stdio: ["ignore", "pipe", "pipe"] },
  );
  const collect = (stream) => {
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => {
      state.text += chunk;
      if (opts.verbose) process.stdout.write(chunk);
    });
  };
  collect(child.stdout);
  collect(child.stderr);
  child.on("exit", (code) => { state.exited = true; state.exitCode = code; });

  try {
    const fatal = () => FATAL_PATTERNS.find((p) => state.text.includes(p));

    const connectMs = await (async () => {
      const startedAt = Date.now();
      while (Date.now() - startedAt < 20000) {
        const hit = fatal();
        if (hit) throw new Error(`客户端输出里出现「${hit}」`);
        if (state.text.includes("已连接到主机")) return Date.now() - startedAt;
        await sleep(200);
      }
      throw new Error(`客户端在 20 秒内没有连上 ${target}:${opts.port}\n${state.text.split("\n").slice(-15).join("\n")}`);
    })();
    assertions.push(`客户端经 ${target} 连上服务器（${(connectMs / 1000).toFixed(1)} 秒）`);

    // RTT 只会在收到 pong 之后才有值，因此它同时证明双向都在通。
    const rttMs = await waitForText(() => state.text, "RTT=", 8000);
    if (rttMs < 0) throw new Error("客户端没有测出 RTT，说明与服务端之间没有双向数据");
    const rttLine = state.text.split("\n").filter((l) => l.includes("RTT=")).pop() || "";
    const rtt = /RTT=(\d+)/.exec(rttLine);
    assertions.push(`测得公网 RTT ${rtt ? rtt[1] : "?"} ms`);

    // 5. 正常停止。计时从发出 stop 起，到客户端出现断开提示止。
    const seenBefore = (state.text.match(/与主机断开/g) || []).length;
    const stopStartedAt = Date.now();
    ssh(`sudo systemctl stop ${unit}`);
    const detectedMs = await (async () => {
      while (Date.now() - stopStartedAt < HEARTBEAT_TIMEOUT_MS + 8000) {
        if ((state.text.match(/与主机断开/g) || []).length > seenBefore) {
          return Date.now() - stopStartedAt;
        }
        await sleep(100);
      }
      return -1;
    })();

    if (detectedMs < 0) {
      throw new Error("服务端已停止，但客户端一直没报告断开");
    }
    if (detectedMs > GRACEFUL_BUDGET_MS) {
      throw new Error(
        `客户端用了 ${(detectedMs / 1000).toFixed(1)} 秒才发现服务端停止，超过 ${(GRACEFUL_BUDGET_MS / 1000).toFixed(1)} 秒。\n` +
        `这个时长说明是**心跳超时**在兜底（阈值 ${HEARTBEAT_TIMEOUT_MS / 1000} 秒），` +
        `也就是服务端退出时没有主动告知客户端——检查 main.gd 的 _exit_tree 是否还调用了 Net.close()。`,
      );
    }
    assertions.push(`服务端正常停止时客户端 ${(detectedMs / 1000).toFixed(1)} 秒内收到断开通知`);
  } finally {
    if (!state.exited) {
      const kill = spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" });
      if (kill.status !== 0) child.kill("SIGKILL");
    }
    // 恢复成运行状态，免得检查完之后没人能连。
    say("\n（恢复服务运行状态）");
    ssh(`sudo systemctl start ${unit}`);
  }

  say("");
  for (const line of assertions) say(`  ok  ${line}`);
  say("\n验收检查通过。");
}

main().catch((err) => {
  process.stderr.write(`\n验收检查失败：${err.message}\n`);
  process.exitCode = 1;
});
