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
//   node tools/check-server.mjs --host <公网IP> --advertise <域名>
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

// 与 scripts/net/net.gd 的 HEARTBEAT_TIMEOUT 对应。客户端自己判定下线要等这么久；
// 正常停止时走的是另一条路径（服务端发 goodbye），因此不该等到这么晚。
const HEARTBEAT_TIMEOUT_MS = 5000;

const HELP = `熔霜 · 联机服务器验收检查

  node tools/check-server.mjs --host <地址> [选项]

  --host <地址>        服务器公网地址（SSH 用），必填
  --advertise <地址>   客户端要连的地址（域名）。不给则用 --host
  --user <用户名>      SSH 用户，默认 ubuntu
  --key <私钥路径>     SSH 私钥，默认 ~/.ssh/id_ed25519_moltenfrost
  --port <端口>        单房间模式下的游戏端口，默认 27015
  --directory-port <端口>  目录模式下的目录端口（TCP），默认 27017
  --room-port <端口>   目录模式下客户端要连的那一间的端口，默认 40001
  --service <名字>     systemd 单元前缀，默认 moltenfrost
  --rooms <N>          目录模式下有几间房，默认 2
  --room-base-port <端口>  目录模式下房间端口的起点，默认 40001
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
    directoryPort: 27017,
    roomPort: 40001,
    service: "moltenfrost",
    rooms: 2,
    roomBasePort: 40001,
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
      case "--directory-port": opts.directoryPort = Number(next()); break;
      case "--room-port": opts.roomPort = Number(next()); break;
      case "--service": opts.service = next(); break;
      case "--rooms": opts.rooms = Number(next()); break;
      case "--room-base-port": opts.roomBasePort = Number(next()); break;
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
// 取值顺序见 memory/README.md：值只存在 memory/local-env.json，不入库。
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
  const ssh = makeSsh(opts);
  const assertions = [];
  const say = (msg) => process.stdout.write(`${msg}\n`);
  // 两种拓扑下"玩家连的是谁"根本不同：
  //   单房间模式 —— 连 `moltenfrost@<端口>` 那个房间；
  //   **目录模式（路线 A）** —— 向 `moltenfrost-directory` 拿列表，然后**直连某一间房**。
  // 不区分会真的把环境弄坏：早先本工具硬编码 `moltenfrost@<端口>`，于是它在另一个
  // 拓扑下"发现服务没跑"就把它启动了，而那个多出来的进程会去抢同一个端口
  //（实测踩到：网关与房间全在跑，却多出一个 27015 房间）。
  const directoryUnit = `${opts.service}-directory`;
  const directoryMode =
    ssh(`systemctl cat ${directoryUnit} >/dev/null 2>&1 && echo yes || echo no`) === "yes";
  const roomPorts = Array.from({ length: opts.rooms }, (_, i) => opts.roomBasePort + i);
  const roomUnits = roomPorts.map((p) => `${opts.service}@${p}`);
  const entryUnit = `${opts.service}@${opts.port}`;
  // 代码一致性要检查**所有在跑的进程**：目录与每间房都是各自的进程，
  // 只查其中一个的话"另一个跑着旧代码"查不出来。
  const codeUnits = directoryMode ? [directoryUnit, ...roomUnits] : [entryUnit];
  // 客户端要连的端口：目录模式下是**那一间房自己的端口**（客户端直连房间）。
  const gamePort = directoryMode ? opts.roomPort : opts.port;
  // 正常停止要停的是**这一客户端所连的那一个**：目录模式下客户端直连房间，
  // 于是停那间房会把 ENet 的断开通知直接发给客户端（与单房间模式同一条路径）。
  // **停目录不行**：那不会断开任何已建立的连接，客户端只能等心跳超时。
  const stopUnit = directoryMode ? `${opts.service}@${opts.roomPort}` : entryUnit;

  say(`服务器：${opts.host}    客户端连接目标：${target}:${gamePort}`);
  say(`Godot：${godot}`);
  say(`拓扑：${directoryMode
    ? `房间目录（${directoryUnit}）+ ${roomUnits.length} 间房（客户端直连）`
    : `单房间（${entryUnit}）`}\n`);

  // 1. SSH
  ssh("true");
  assertions.push("SSH 可达");

  // 2. 服务在跑。若不在跑就启动，并等它在监听。
  //    "在跑"与"在监听"是两件事：Godot 启动要几秒，只看 systemctl 会误判。
  const wantUnits = directoryMode ? [directoryUnit, ...roomUnits] : [entryUnit];
  for (const wanted of wantUnits) {
    const unitState = ssh(`systemctl is-active ${wanted} || true`);
    if (unitState !== "active") {
      say(`（${wanted} 当前是 ${unitState}，正在启动）`);
      ssh(`sudo systemctl start ${wanted}`);
    }
  }
  for (const wanted of wantUnits) ssh(`sudo systemctl is-active --quiet ${wanted}`);

  // **核对服务进程里的代码与仓库里的一致。**
  // 进程的启动时间早于仓库最新提交时间，就说明它跑的是旧代码——
  // 这种情况不报错、功能看着也正常，但新改的东西不会生效，极难排查。
  // （2026-09-26 实测：部署只更新了文件，服务进程没重启，
  // 于是日志里报的错误来自一个已经删掉的 RPC。）
  // 只在**已经启动过**的单元上判定：没启动的自然没有陈旧进程，而且启动它会
  // 引入新进程（那正是上面那条注释警告的陷阱）。
  for (const checked of codeUnits) {
    const staleCheck = ssh(
      `p=$(systemctl show -p MainPID --value ${checked}); ` +
      `[ -n "$p" ] && [ "$p" != "0" ] || { echo no-pid; exit 0; }; ` +
      `started=$(stat -c %Y /proc/$p 2>/dev/null || echo 0); ` +
      `commit=$(git -C ~/moltenfrost log -1 --format=%ct); ` +
      `if [ "$started" -lt "$commit" ]; then echo stale; else echo fresh; fi`,
    );
    if (staleCheck === "stale") {
      throw new Error(
        `${checked} 启动于仓库最新提交之前，说明它在跑旧代码（进程没随部署重启）。\n` +
        `重启后重跑本检查：ssh ${opts.user}@${opts.host} 'sudo systemctl restart ${checked}'`,
      );
    }
  }
  assertions.push(directoryMode ? `目录与 ${roomUnits.length} 间房跑的代码都与仓库一致` : "服务运行的代码与仓库一致");

  let listening = false;
  for (let i = 0; i < 30; i++) {
    // ss 在最小安装里可能没有，因此退回用 /proc/net/udp 判断。
    // 目录模式下要查**两个**：目录（TCP）与那一间房（UDP）。
    // 少查一个的现象是"检查全过，但客户端连不上"——因为目录在、房间不在。
    //
    // 匹配串里**不要用 \b**：它要穿过 PowerShell 与 ssh 两层引号，实测到那边已经
    // 不是单词边界了，于是明明在监听却数到 0（而 `grep -c 40001` 能正常命中）。
    // 端口号最多 5 位、且这一列后面跟的是空格，因此直接匹配就够，不会误命中。
    const countUdp = (port) => `sudo ss -lun 2>/dev/null | grep -c ':${port}' || true`;
    const countTcp = (port) => `sudo ss -ltn 2>/dev/null | grep -c ':${port}' || true`;
    const probes = [countUdp(gamePort)];
    if (directoryMode) probes.push(countTcp(opts.directoryPort));
    const out = ssh(probes.join(" ; "));
    const counts = out.split(/\s+/).filter((x) => x.length > 0).map(Number);
    if (counts.length === probes.length && counts.every((c) => c > 0)) { listening = true; break; }
    await sleep(1000);
  }
  if (!listening) {
    throw new Error(directoryMode
      ? `没看到监听：房间 UDP ${gamePort} 或目录 TCP ${opts.directoryPort}`
      : `服务在跑，但没有看到监听 UDP ${gamePort}`);
  }
  assertions.push(directoryMode
    ? `目录监听 TCP ${opts.directoryPort}、房间监听 UDP ${gamePort}`
    : `服务在运行并监听 UDP ${gamePort}`);

  // 3~5. 起一个客户端，做完检查后收回。
  const state = { text: "", exited: false, exitCode: null };
  const child = spawn(
    godot,
    ["--headless", "--path", PROJECT_DIR, "--", "--join", target, "--port", String(gamePort),
      ...(directoryMode ? ["--public-room"] : []), "--net-stats"],
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
      throw new Error(`客户端在 20 秒内没有连上 ${target}:${gamePort}\n${state.text.split("\n").slice(-15).join("\n")}`);
    })();
    assertions.push(`客户端经 ${target} 连上服务器（${(connectMs / 1000).toFixed(1)} 秒）`);

    // RTT 只会在收到 pong 之后才有值，因此它同时证明双向都在通。
    // 注意要等**数值**出现，而不是等 "RTT=" 出现：未测到时那一列写的是"测量中"，
    // 只匹配前级会提前返回，然后解析出一个空值（实测踩过）。
    const rttOk = await waitForText(
      () => state.text, "RTT=", 8000,
    );
    let rttValue = null;
    for (let i = 0; i < 40 && rttValue === null; i++) {
      const lines = state.text.split("\n").filter((l) => l.includes("RTT="));
      for (let j = lines.length - 1; j >= 0; j--) {
        const m = /RTT=(\d+)\s*ms/.exec(lines[j]);
        if (m) { rttValue = m[1]; break; }
      }
      if (rttValue === null) await sleep(250);
    }
    if (rttOk < 0 || rttValue === null) {
      throw new Error("客户端没有测出 RTT，说明与服务端之间没有双向数据");
    }
    assertions.push(`测得公网 RTT ${rttValue} ms`);

    // 5. 正常停止。**判据是时间短于心跳阈值**，而不是具体文案。
    // 客户端可能通过两条路径得知下线：ENet 的断开通知（服务端 close 时发出）
    // 与客户端自己的心跳超时。实测证明有效的是前者——曾经额外加过一个 reliable 的
    // "goodbye" RPC 来主动告知，但断开通知会先到，把客户端转成 OFFLINE，
    // 随后的 goodbye 被去重逻辑忽略掉了（所以按文案断言会误判）。
    // 反过来，若 close 之前漏了那次 poll()，断开通知会留在队列里随进程消失，
    // 客户端就只有等心跳兜底——功能上照常"能用"，因此时间断言才查得出这种退化。
    // 计时含 ssh 握手与 systemctl 执行的开销，因此只当作量级参考。
    const seenBefore = (state.text.match(/与主机断开/g) || []).length;
    const stopStartedAt = Date.now();
    ssh(`sudo systemctl stop ${stopUnit}`);
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
    if (detectedMs >= HEARTBEAT_TIMEOUT_MS) {
      const tail = state.text.split("\n").filter((l) => l.includes("断开")).slice(-3).join("\n");
      // 这一条现在**必然失败**，而且原因已经查清（2026-09-30）：`systemctl stop` 发的 SIGTERM
      // 不会让 Godot 走 `_exit_tree`，进程几十毫秒就没了，`shutdown_gracefully()` 里那六轮
      // poll 从未跑到，于是断开通知从未发出，客户端只能等心跳。
      // 保留为硬断言而不是降级成警告：它是真的没做到，而且判据（是否短于心跳阈值）能区分
      // "通知真的发出去了"与"心跳在兜底"。修好之后这条会自己变绿。
      throw new Error(
        `客户端用了 ${(detectedMs / 1000).toFixed(1)} 秒才发现服务端停止，达到心跳阈值（${HEARTBEAT_TIMEOUT_MS / 1000} 秒）。\n` +
        `说明是心跳在兜底。**已知原因**（2026-09-30 实测）：\n` +
        `  systemctl stop 发的 SIGTERM 不会让 Godot 走 _exit_tree —— 进程 8～24 毫秒就退出了，\n` +
        `  而 Net.shutdown_gracefully() 里那六轮 poll 本身要 240 毫秒；时间对不上就说明它没跑到。\n` +
        `  用 --quit-after 让服务端自行退出时这条断言是 0.0 秒（见 tools/net-smoke.mjs），\n` +
        `  所以只有 SIGTERM 这一条路断了。\n` +
        `修的方向与验证方式写在 docs/服务端部署.md 的 10.3（让 stop 走"自行退出"那条路；\n` +
        `改完先看退出耗时有没有上到 240 毫秒以上）。\n` +
        `客户端相关输出：\n${tail}`,
      );
    }
    assertions.push(`服务端正常停止时客户端不等心跳即发现（${(detectedMs / 1000).toFixed(1)} 秒，含 SSH 开销）`);
  } finally {
    if (!state.exited) {
      const kill = spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" });
      if (kill.status !== 0) child.kill("SIGKILL");
    }
    // 恢复成运行状态，免得检查完之后没人能连。
    say("\n（恢复服务运行状态）");
    // 恢复的是**刚被停掉的那一个**：目录模式下是那一间房，而不是某个入口端口。
    ssh(`sudo systemctl start ${stopUnit}`);
  }

  say("");
  for (const line of assertions) say(`  ok  ${line}`);
  say("\n验收检查通过。");
}

main().catch((err) => {
  process.stderr.write(`\n验收检查失败：${err.message}\n`);
  process.exitCode = 1;
});
