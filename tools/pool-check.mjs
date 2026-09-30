// 房间池的端到端自检：起一个真目录 + 真房间池 + 真 Godot 房间，走一遍完整生命周期。
//
//   node tools/pool-check.mjs [--godot <路径>] [--python <路径>]
//
// 为什么单独立一个工具而不并进 tools/net-smoke.mjs：它要额外拉起 1～3 个 Godot
// 房间进程（每个约一两秒才登记上来），并进冒烟测试会把那一步从几十秒拖到两分钟。
// 但这一层又必须有回归守卫——"打开界面看不到房间、创建一间之后别人才看得到"
// 这条行为完全由它保证，任何一处接线断了都只表现为"界面上少了一行"。
//
// 已验证的断言（与 docs/公网房间方案.md 的 7.0 对应）：
//   初始恰好 1 间备用房，且**默认列表是空的**（玩家打开界面看到的是空的）
//   创建 = 认领那间备用房，它立刻出现在所有人的列表里
//   认领之后池补上一间备用（非空闲 + 备用）
//   两个人同时创建拿到的是**两间不同的房**（认领是原子的）
//   端口段满了就不再补
//   没有备用房时认领回答"稍等"而不是错误
//
// **在 Windows 上不验 SIGTERM 优雅停止**：Node 的 kill("SIGTERM") 在那里是直接终止
// 进程、不发信号，Python 的 handler 根本不会跑。那一条由服务器上的
// tools/check-server.mjs 验（Linux）。

import { spawn, spawnSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import process from "node:process";

const args = process.argv.slice(2);
function argValue(name, fallback) {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
}

const REPO = process.cwd();
const DIR_PORT = Number(argValue("--dir-port", "27117"));
const BASE_PORT = Number(argValue("--base-port", "41101"));
const MAX_ROOMS = 3;
// Windows 上解释器叫 python.exe，Linux/macOS 上多半是 python3。
const PYTHON = argValue("--python", process.env.PYTHON || process.env.PY || "python3");

// Godot 路径优先取参数，其次问 tools/setup-dev-env.mjs（它会读 memory/local-env.json）。
let GODOT = argValue("--godot", process.env.GODOT_BIN || "");
if (!GODOT) {
  const probe = spawnSync(process.execPath, ["tools/setup-dev-env.mjs", "--print-godot"], {
    cwd: REPO, encoding: "utf8",
  });
  GODOT = (probe.stdout || "").trim();
}
if (!GODOT) {
  console.error("找不到 Godot：用 --godot <路径> 指定，或先跑 node tools/setup-dev-env.mjs");
  process.exit(1);
}

const failures = [];
let checks = 0;
function ok(condition, label) {
  checks++;
  console.log(`${condition ? "  ok  " : "  --  "} ${label}`);
  if (!condition) failures.push(label);
}

const children = [];
function launch(file, argv, label) {
  const proc = spawn(file, argv, { cwd: REPO, stdio: ["ignore", "pipe", "pipe"] });
  const lines = [];
  const keep = (chunk) =>
    chunk.toString().split(/\r?\n/).forEach((line) => line.trim() && lines.push(line));
  proc.stdout.on("data", keep);
  proc.stderr.on("data", keep);
  proc.on("error", (err) => lines.push(`无法启动 ${file}：${err.message}`));
  const entry = { proc, lines, label };
  children.push(entry);
  return entry;
}

async function listing(includeIdle) {
  const url = `http://127.0.0.1:${DIR_PORT}/rooms${includeIdle ? "?all=1" : ""}`;
  const response = await fetch(url);
  return (await response.json()).rooms;
}

// 探针要容错：目录还没起来时 fetch 会抛（ECONNREFUSED），而不是返回 false。
let reportedFetchError = false;
async function tryListing(includeIdle) {
  try {
    return await listing(includeIdle);
  } catch (err) {
    if (!reportedFetchError) {
      reportedFetchError = true;
      console.log(`  !! 取列表失败：${err.cause ? err.cause.message : err.message}`);
    }
    return null;
  }
}

async function claim() {
  const response = await fetch(`http://127.0.0.1:${DIR_PORT}/rooms/claim`, { method: "POST" });
  return await response.json();
}

async function waitFor(predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return true;
    await sleep(400);
  }
  console.log(`  !! 等待超时：${label}`);
  return false;
}

const count = async (includeIdle) => ((await tryListing(includeIdle)) || []).length;

// ---------------------------------------------------------------- 端口占用
//
// 本检查用的是**固定端口**（目录 27117、房间 41101..41103），因为断言里要写死
// "第二次认领应当拿到 41102"这种具体端口。代价是上一次跑完留下的残留进程会让这一次
// 以极难懂的方式失败——实测 2026-10-01：上次留下的一批 Godot 房间还占着 41101..41103，
// 新池看到的是一批"不是自己拉起的"房间，于是认领返回陈旧的端口、7 条断言全错，
// 还白等了 86 秒（日志里只有"不是本进程拉起的"，看不出是上一次没清干净）。
//
// 因此：开工前先确认这些端口是空的（不空就立刻报出 PID 与清理命令），
// 收工时把还占着房间端口的残留进程收掉（Windows 上池被终止时来不及请房间退出，
// 见下面 finally 里的说明）。**失败要能区分原因**，不能让人从 86 秒日志里猜。

// 端口 → 占用它的进程。跨平台尽力而为：拿不到就返回空表，只影响提示的详细程度。
function busyPortPids(ports) {
  const want = new Set(ports);
  const found = new Map();
  const add = (pid, port) => {
    if (!Number.isFinite(pid) || !want.has(port)) return;
    found.set(pid, [...new Set([...(found.get(pid) || []), port])]);
  };
  if (process.platform === "win32") {
    for (const proto of ["UDP", "TCP"]) {
      const res = spawnSync("netstat", ["-ano", "-p", proto], { encoding: "utf8" });
      for (const raw of String(res.stdout || "").split(/\r?\n/)) {
        const parts = raw.trim().split(/\s+/);
        if (parts[0] !== proto || parts.length < 4) continue;
        // **只认"在监听"。** 关上一次的连接会以 TIME_WAIT（PID 0）在 netstat 里
        // 留一阵子，那是正常的，而且不挡新监听；把它算成占用会让开工前的自检
        // 在刚跑完一次之后立刻误报（实测踩到：报 PID 0 占着 27117 四十次）。
        if (proto === "TCP" && parts[3] !== "LISTENING") continue;
        const local = parts[1];
        add(Number(parts[parts.length - 1]), Number(local.slice(local.lastIndexOf(":") + 1)));
      }
    }
  } else {
    const res = spawnSync("ss", ["-ltunp"], { encoding: "utf8" });
    for (const raw of String(res.stdout || "").split(/\r?\n/)) {
      const pid = raw.match(/pid=(\d+)/);
      if (!pid) continue;
      for (const port of raw.matchAll(/:(\d+)\s/g)) add(Number(pid[1]), Number(port[1]));
    }
  }
  return found;
}

function describeBusy(busy) {
  return [...busy.entries()].map(([pid, ports]) => `PID ${pid}（端口 ${ports.join(", ")}）`).join("；");
}

const ROOM_PORTS = Array.from({ length: MAX_ROOMS }, (_, i) => BASE_PORT + i);

try {
  console.log(`Godot：${GODOT}`);
  console.log(`解释器：${PYTHON}`);
  console.log(`目录端口 ${DIR_PORT}，房间端口 ${BASE_PORT}..${BASE_PORT + MAX_ROOMS - 1}\n`);

  // 开工前先看端口是不是空的。占用它的多半是上一次跑留下的残留（见上面的说明），
  // 而那种情况下后面 7 条断言会以"池没有拉起备用房""认领拿到旧端口"的形式全错。
  const busyAtStart = busyPortPids([DIR_PORT, ...ROOM_PORTS]);
  if (busyAtStart.size > 0) {
    console.error(
      `端口已被占用：${describeBusy(busyAtStart)}\n` +
      `它们多半是上一次本检查留下的残留（或开发中自己开的实例）。先清掉再跑：\n` +
      `  Windows: Get-Process | Where-Object { \$_.ProcessName -match 'Godot' } | Stop-Process -Force\n` +
      `  Linux:   pkill -f 'godot.*--port ${BASE_PORT}'`,
    );
    process.exit(1);
  }

  launch(PYTHON, ["tools/room-directory.py", "--port", String(DIR_PORT), "--ttl", "6"], "目录");
  await waitFor(
    async () => {
      try {
        return (await fetch(`http://127.0.0.1:${DIR_PORT}/health`)).ok;
      } catch {
        return false;
      }
    },
    10000,
    "目录起来",
  );

  const pool = launch(PYTHON, [
    "tools/room-pool.py",
    "--directory", `127.0.0.1:${DIR_PORT}`,
    "--godot", GODOT,
    "--repo", REPO,
    "--base-port", String(BASE_PORT),
    "--max-rooms", String(MAX_ROOMS),
    "--spare", "1",
    "--advertise", "pool-check.example.com",
  ], "房间池");

  // 1. 初始：恰好 1 间备用房，而默认列表是空的
  ok(await waitFor(async () => (await count(true)) === 1, 40000, "初始 1 间备用房"),
    "初始应当恰好拉起 1 间备用房（spare=1）");
  ok((await count(false)) === 0,
    "备用房不应当出现在默认列表里（玩家打开界面看到的是空的）");

  // 2. 创建 = 认领那间备用房
  const first = await claim();
  ok(first.ok && first.port === BASE_PORT,
    `认领应当给出端口最小的那间备用房，得到 ${JSON.stringify(first)}`);
  ok((await count(false)) === 1, "被认领的房间应当立刻出现在列表里（别人这才看得到）");

  // 3. 池补上第二间备用：非空闲 1 + 备用 1 = 2
  ok(await waitFor(async () => (await count(true)) === 2, 40000, "补上第 2 间"),
    "认领之后池应当补上一间备用（非空闲 + 备用）");
  ok((await count(false)) === 1, "补上的那一间是备用，不应当出现在默认列表里");

  // 4. 两个人同时创建必须拿到两间不同的房
  const second = await claim();
  ok(second.ok && second.port === BASE_PORT + 1,
    `第二次认领应当拿到另一间（${BASE_PORT + 1}），得到 ${JSON.stringify(second)}`);
  ok((await count(false)) === 2, "两间被认领的房间都应当在列表里");
  ok(await waitFor(async () => (await count(true)) === 3, 40000, "补到 3 间"),
    "池应当补到 3 间（非空闲 2 + 备用 1）");

  // 5. 端口段满了就不再补，认领改为回答"稍等"
  const third = await claim();
  ok(third.ok && third.port === BASE_PORT + 2,
    `第三次认领应当拿到 ${BASE_PORT + 2}，得到 ${JSON.stringify(third)}`);
  await sleep(5000);
  ok((await count(true)) === MAX_ROOMS, `端口段已满时不应当再补（上限 ${MAX_ROOMS} 间）`);
  const waiting = await claim();
  ok(!waiting.ok && waiting.waiting === true,
    `没有备用房时认领应当回答\"稍等\"而不是报错，得到 ${JSON.stringify(waiting)}`);

  // 6. 停池
  console.log("\n停掉房间池…");
  if (process.platform === "win32") {
    // 这一条只能在 Linux 上验：Windows 上 Node 的 kill 是直接终止进程、不发信号，
    // 于是"收到 SIGTERM → 先把每间房优雅停掉 → 再退出"这条路径根本不会被走到。
    // 服务器上由 tools/check-server.mjs 验（那是真正的目标平台）。
    pool.proc.kill();
    console.log("  （略过优雅停止检查：Windows 上不发 SIGTERM，改由服务器上的 check-server 验）");
  } else {
    pool.proc.kill("SIGTERM");
    ok(await waitFor(async () => pool.proc.exitCode !== null, 30000, "池退出"),
      "房间池应当能停下来（收到 SIGTERM 后收完房间自己退出）");
  }
} catch (err) {
  console.log(`  !! 异常：${err && err.stack ? err.stack : err}`);
  failures.push("异常");
} finally {
  for (const entry of children) {
    if (entry.proc.exitCode === null) entry.proc.kill("SIGKILL");
  }
  await sleep(500);
  // **把还占着房间端口的进程收掉。** Windows 上 Node 的 kill 不发信号（见上面第 6 节），
  // 于是池被终止时来不及请房间自己退出，那些 Godot 房间会留成孤儿、继续占着
  // 41101.. 的 UDP 端口 —— 下一次跑本检查就会以"不是本进程拉起的"那种形式全错。
  // 这里按端口把它们收掉，让本检查可以反复跑（这正是它自己的烂摊子）。
  const strays = busyPortPids(ROOM_PORTS);
  if (strays.size > 0) {
    console.log(`\n收掉还占着房间端口的残留进程：${describeBusy(strays)}`);
    for (const pid of strays.keys()) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        // 已经退出或没权限：不因为收尾失败而改变判定。
      }
    }
    await sleep(500);
    const leftover = busyPortPids(ROOM_PORTS);
    if (leftover.size > 0) {
      console.log(`  !! 还有进程占着房间端口（下次跑本检查会直接报端口占用）：${describeBusy(leftover)}`);
    }
  }
  if (failures.length) {
    for (const entry of children) {
      console.log(`\n--- ${entry.label} 最后 30 行 ---`);
      console.log(entry.lines.slice(-30).join("\n"));
    }
  }
}

// **额外一行纯 ASCII 的判定标记**：中文结论在 PowerShell 管道里会变成乱码，
// 而那会导致"看不清结果 → 再跑一遍"（实测踩过，一次 110 秒）。判定本身看退出码。
console.log(failures.length ? `房间池自检失败（${failures.length} 项）` : "房间池自检通过。");
console.log(failures.length
  ? `FAIL (${failures.length}): ${failures.join(" | ")}`
  : `ALL PASS (${checks} checks)`);
process.exit(failures.length ? 1 : 0);
