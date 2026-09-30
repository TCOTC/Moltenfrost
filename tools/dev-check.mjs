// 熔霜 · 分层自检
//
//   node tools/dev-check.mjs              # 快层（默认）：语法 + 五个纯逻辑检查，约 20 秒
//   node tools/dev-check.mjs --full       # 全套：快层 + 冒烟 + 房间池 + 目录客户端，约 4 分钟
//   node tools/dev-check.mjs --only menu  # 只跑某一项
//   node tools/dev-check.mjs --list       # 列出所有检查项与它们属于哪一层
//
// ## 为什么要有这个工具
//
// 实测（2026-09-30，一次 319 分钟的对话）：**工具耗时里 95% 是 `run_in_terminal`**，
// 其中绝大部分是反复跑"全套验收"。而全套里最贵的几项（`net-smoke` 113 秒、
// `pool-check` 90 秒、服务器上的 `directory-check.sh` 355 秒）里有大量**设计出来的等待**
// （起无头实例、等一局跑完、DNS、公网 RTT），改一行注释之后跑它纯属浪费。
//
// 缺的从来不是"更快的测试"，而是**便宜的那一层**。因此这里按代价分两层，
// 并且把每一项的耗时都打出来——**耗时是可见的，才会有人去维护它**。
//
// ## 判定行只用 ASCII
//
// 所有结论行是 `  ok  <id>  <秒>` / `  FAIL ...` / `ALL PASS`，**不含中文**。
// 理由不是"英文更好"，而是实测过：Windows 的 PowerShell 管道会把子进程的 UTF-8 输出
// 重新编码，中文在 `Select-String` 里会变成乱码，于是出现过"跑完看不出结论 →
// 换一种读法再跑一遍"的重复执行（最慢那两次 `net-smoke` 各 110 秒就是这么来的）。
// 详情与细节文案仍可以是中文，它们只在人工细看时才需要。
//
// 判定本身不看那一行中文，而是看**退出码**：所有检查脚本成功时 `quit(0)`、失败时 `quit(1)`，
// 这比匹配一句中文结论更可靠（也顺手避开了编码问题）。
//
// ## 与另外几个自检的分工
//
//   dev-check --quick   改代码时的循环          （本文件）
//   dev-check --full     提交前                （本文件，含下面三个）
//   net-smoke.mjs        联机层：两个真实实例、大厅流程、目录协议自检
//   pool-check.mjs       房间池：起真目录 + 真池 + 真房间
//   directory-client-check.mjs  客户端认领：真目录 + 真客户端
//   check-server.mjs     真机公网验收（要 SSH，与上面都不同层）
//
// 最后一条不在本工具里：它要 SSH 与一台真服务器，不属于"本地自检"。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// 出现这些字样即视为失败。与 tools/net-smoke.mjs 用同一组判据。
const FATAL_PATTERNS = ["SCRIPT ERROR", "Parse Error"];

// 单项的上限（毫秒）。快层都应在几秒内结束；给到 60 秒是防"卡住"而不是防"慢"。
// 整层那几项是集成层（要起真实例、等一局跑完），天然慢，因此单独放宽。
const TIMEOUT_QUICK_MS = 60000;
const TIMEOUT_FULL_MS = 300000;

// ---------------------------------------------------------------- 检查表
//
// 每一项要么是"跑一个 Godot 检查脚本"，要么是"跑另一个 Node 工具"。
// `tier` 决定它出现在哪一层；`why` 是给人看的——**不知道该不该跑它时读这一句**。
const CHECKS = [
  {
    id: "syntax",
    tier: "quick",
    label: "语法与启动",
    why: "所有脚本能解析、自动加载与主场景链路能起来。改完任何 .gd 先跑这个",
    godot: { argv: ["--headless", "--path", PROJECT_DIR, "--quit-after", "3", "--", "--port", "0"] },
    // 这一项没有"通过"输出，判定只看有没有 SCRIPT ERROR / Parse Error。
    noPassLine: true,
  },
  {
    id: "interp",
    tier: "quick",
    label: "插值取样",
    why: "远端角色的平滑水位与时钟调速",
    godot: { script: "tests/remote_interpolator_test.gd" },
  },
  {
    id: "lan",
    tier: "quick",
    label: "局域网探测",
    why: "房间广播的编解码与去重",
    godot: { script: "tests/lan_discovery_test.gd" },
  },
  {
    id: "config",
    tier: "quick",
    label: "产品常量",
    why: "配置读取、回退、以及域名解析成 IP 那一步",
    godot: { script: "tests/product_config_test.gd" },
  },
  {
    id: "menu",
    tier: "quick",
    label: "初始界面接线",
    why: "按钮信号、房间列表合成、创建公网房间（认领）与它的兜底",
    godot: { script: "tests/menu_test.gd" },
  },
  {
    id: "level",
    tier: "quick",
    label: "关卡几何与规则",
    why: "判定体、沟宽与池深是否符合手感数值推出的尺寸",
    godot: { script: "tests/level_test.gd" },
  },
  {
    id: "game",
    tier: "quick",
    label: "关卡玩法",
    why: "积分结算、两人同时进出口、重开。以场景为入口（要自动加载单例）",
    godot: { scene: "tests/game_test.tscn" },
  },
  {
    id: "session",
    tier: "full",
    label: "会话生命周期",
    why: "重开一局、不残留角色、RPC 时序。要起真实会话，因此慢",
    godot: { scene: "tests/session_test.tscn" },
  },
  {
    id: "net-smoke",
    tier: "full",
    label: "联机冒烟（含大厅与目录协议）",
    why: "两个真实无头实例：连接、按 peer 生成角色、大厅人齐开局、优雅停止",
    node: "tools/net-smoke.mjs",
  },
  {
    id: "pool",
    tier: "full",
    label: "房间池生命周期",
    why: "起真目录 + 真池 + 真房间：打开时列表是空的、认领之后才出现、人走光又消失",
    node: "tools/pool-check.mjs",
  },
  {
    id: "directory-client",
    tier: "full",
    label: "目录客户端认领",
    why: "真目录 + 真客户端：请求真的发出去了、回信真的到了",
    node: "tools/directory-client-check.mjs",
  },
];

// ---------------------------------------------------------------- 参数

const HELP = `熔霜 · 分层自检

  node tools/dev-check.mjs [选项]

  （默认）        快层：语法 + 纯逻辑检查，约 20 秒。改代码时用这个
  --full          全套：快层 + 联机冒烟 + 房间池 + 目录客户端，约 4 分钟。提交前用
  --only <id>     只跑某一项（可重复）。id 见 --list
  --list          列出所有检查项、所属层与耗时上限
  --verbose       把每个检查的完整输出打出来（默认只打失败的那些）
  --godot <路径>  Godot 可执行文件；不给则用 GODOT_BIN 或按常见位置探测
  -h, --help      显示本帮助

判定行只有 ASCII（ok / FAIL / ALL PASS），因此任何编码下都读得出来。
失败时会把那几项的输出尾部打出来；全过时只打一行汇总。
`;

function parseArgs(argv) {
  const opts = { full: false, only: [], verbose: false, list: false, help: false, godot: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`参数 ${arg} 后面缺少取值`);
      return v;
    };
    switch (arg) {
      case "--full": opts.full = true; break;
      case "--only": opts.only.push(next()); break;
      case "--verbose": opts.verbose = true; break;
      case "--list": opts.list = true; break;
      case "--godot": opts.godot = next(); break;
      case "-h": case "--help": opts.help = true; break;
      default: throw new Error(`未知参数：${arg}`);
    }
  }
  return opts;
}

// ---------------------------------------------------------------- Godot 探测
//
// 与 tools/net-smoke.mjs / check-server.mjs / setup-dev-env.mjs 各留一份。
// 刻意不抽成共用模块：这四处用途不同（那三个分别要启动实例、要跑客户端、要装模板），
// 而共用会让一处的小改动牵动另外三处已稳定的脚本。取值顺序一致（见 memory/README.md）。
function localEnvJson() {
  const file = path.join(PROJECT_DIR, "memory", "local-env.json");
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch {
    return {};
  }
  try {
    const parsed = JSON.parse(raw.replace(/^\uFEFF/, ""));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
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
      const res = spawnSync(cmd, ["--version"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
      if (res.status === 0) return cmd;
    } catch { /* 换下一个 */ }
  }
  return null;
}

// ---------------------------------------------------------------- 执行

function tail(text, lines = 14) {
  const arr = String(text || "").split(/\r?\n/).filter((l) => l.trim());
  return arr.slice(-lines).join("\n");
}

// 跑一项。返回 { ok, seconds, output, note }。
function runCheck(check, godot) {
  const startedAt = Date.now();
  const timeoutMs = check.tier === "quick" ? TIMEOUT_QUICK_MS : TIMEOUT_FULL_MS;

  let res;
  if (check.node) {
    // 子工具自己会打印判定，因此这里同样**只看退出码**（它们失败时非零退出）。
    res = spawnSync(process.execPath, [check.node], {
      cwd: PROJECT_DIR, encoding: "utf8", timeout: timeoutMs,
      env: process.env,
    });
  } else {
    const spec = check.godot;
    const argv = spec.script
      ? ["--headless", "--path", PROJECT_DIR, "--script", spec.script]
      : spec.scene
        ? ["--headless", "--path", PROJECT_DIR, spec.scene]
        : spec.argv;
    res = spawnSync(godot, argv, { cwd: PROJECT_DIR, encoding: "utf8", timeout: timeoutMs });
  }

  const seconds = (Date.now() - startedAt) / 1000;
  const output = `${res.stdout || ""}\n${res.stderr || ""}`;

  if (res.error && res.error.code === "ETIMEDOUT") {
    return { ok: false, seconds, output, note: `超过 ${timeoutMs / 1000} 秒未结束，已中止` };
  }
  const fatal = FATAL_PATTERNS.find((p) => output.includes(p));
  if (fatal) {
    return { ok: false, seconds, output, note: `输出里出现「${fatal}」` };
  }
  if (res.status !== 0) {
    return { ok: false, seconds, output, note: `退出码 ${res.status}` };
  }
  if (check.node && !/ALL PASS|全部通过|通过|ALL OK/.test(output)) {
    // 子工具退出码 0 但它自己没报通过 —— 多半是它被改过、判定行变了。
    // 这种情况宁可报失败，也不要"绿着但没测"。
    return { ok: false, seconds, output, note: "退出码为 0，但输出里没有通过标志" };
  }
  return { ok: true, seconds, output, note: "" };
}

// ---------------------------------------------------------------- 主流程

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) { process.stdout.write(HELP); return 0; }

  if (opts.list) {
    process.stdout.write("id                 层     耗时上限  说明\n");
    for (const c of CHECKS) {
      process.stdout.write(
        `  ${c.id.padEnd(16)} ${(c.tier === "quick" ? "快" : "全").padEnd(5)} ` +
        `${String((c.tier === "quick" ? TIMEOUT_QUICK_MS : TIMEOUT_FULL_MS) / 1000) + "s"}`.padEnd(9) +
        `  ${c.label}\n`,
      );
    }
    return 0;
  }

  let selected = CHECKS;
  if (opts.only.length > 0) {
    selected = [];
    for (const id of opts.only) {
      const hit = CHECKS.find((c) => c.id === id);
      if (!hit) {
        process.stderr.write(`没有这个检查项：${id}（用 --list 看全部）\n`);
        return 2;
      }
      selected.push(hit);
    }
  } else if (!opts.full) {
    selected = CHECKS.filter((c) => c.tier === "quick");
  }

  const godot = opts.godot || process.env.GODOT_BIN || detectGodot();
  // 只跑 Node 子工具的场合不需要 Godot（例如只跑 pool），因此这里只在该需要时才算错。
  const needsGodot = selected.some((c) => c.godot);
  if (needsGodot && !godot) {
    process.stderr.write("找不到 Godot 可执行文件。用 --godot <路径> 指定，或设置 GODOT_BIN。\n");
    return 2;
  }

  const tierName = opts.only.length > 0 ? "指定项" : opts.full ? "全套" : "快层";
  process.stdout.write(`dev-check (${tierName})  ${selected.length} 项  Godot=${godot || "(不需要)"}\n`);

  const failed = [];
  const timings = [];
  for (const check of selected) {
    const r = runCheck(check, godot);
    timings.push({ id: check.id, seconds: r.seconds });
    // **判定行只有 ASCII**（见文件头）：这样任何编码下 `Select-String 'ok |FAIL'` 都读得出来。
    process.stdout.write(
      `${(r.ok ? "  ok  " : "  FAIL")} ${check.id.padEnd(18)} ${r.seconds.toFixed(1).padStart(6)}s` +
      `${r.ok ? "" : `   <- ${r.note}`}\n`,
    );
    if (!r.ok) failed.push({ check, output: r.output, note: r.note });
    if (opts.verbose) process.stdout.write(`${r.output}\n`);
  }

  // 失败时把输出尾部打出来。**不截断到只剩一行**：多数失败要靠上下文才能定位。
  for (const f of failed) {
    process.stdout.write(`\n--- ${f.check.id} 失败（${f.note}）最后几行 ---\n${tail(f.output)}\n`);
  }

  const total = timings.reduce((s, t) => s + t.seconds, 0);
  const slowest = [...timings].sort((a, b) => b.seconds - a.seconds)[0];
  process.stdout.write(`\n耗时合计 ${total.toFixed(1)}s`);
  if (slowest) process.stdout.write(`，最慢的是 ${slowest.id}（${slowest.seconds.toFixed(1)}s）`);
  process.stdout.write("\n");

  if (failed.length === 0) {
    // 这一行同样是 ASCII，方便脚本与肉眼都只认它。
    process.stdout.write(`ALL PASS (${selected.length} checks, ${total.toFixed(1)}s)\n`);
    return 0;
  }
  process.stdout.write(`FAIL (${failed.length}/${selected.length}): ${failed.map((f) => f.check.id).join(", ")}\n`);
  return 1;
}

process.exit(main());
