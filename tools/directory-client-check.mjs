// 目录客户端的接线自检：起一个**真目录** + 一个假房间，再让真客户端去认领。
//
//   node tools/directory-client-check.mjs [--godot <路径>] [--python <路径>] [--real]
//
// 默认只跑本地那一轮（起一个假目录，不需要外网）。加 `--real` 会**额外**用
// config/product.cfg 里的域名跑一轮——那一轮会真的解析域名、连真的服务器，
// 因此它验的是"域名 → IP → HTTP 能用"这条链（腾讯云拦未备案域名的那个坑）。
//
// 为什么单独一条：这里要验的是"请求真的发出去了、回信真的到了"，而
// tests/menu_test.gd 里那个目录客户端替身恰好把这两件事都跳过了。
// 真机上踩到的正是这一层——点「创建房间」之后界面永久停在
// 「正在向官方服务器要一间房…」，而服务器日志里根本没有那次请求。
//
// 不需要房间池、也不需要真房间：预先向目录登记一个"空着的房间"就够了，
// 认领的语义（挑一间空的、保留、返回地址）与真部署完全相同。

import { spawn, spawnSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import process from "node:process";

const args = process.argv.slice(2);
function argValue(name, fallback) {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
}

const REPO = process.cwd();
// 用一个不常用的端口：开发时的实例与其它自检都不会占它。
const DIR_PORT = Number(argValue("--dir-port", "27123"));
// 假房间的端口。刻意与目录端口不同，这样"拿到的端口取自目录"才是有内容的断言。
const ROOM_PORT = Number(argValue("--room-port", "40231"));
const PYTHON = argValue("--python", process.env.PYTHON || process.env.PY || "python3");

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
function ok(condition, label) {
  console.log(`${condition ? "  ok  " : "  --  "} ${label}`);
  if (!condition) failures.push(label);
}

const base = `http://127.0.0.1:${DIR_PORT}`;
let directory = null;

async function health() {
  try {
    return (await fetch(`${base}/health`)).ok;
  } catch {
    return false;
  }
}

try {
  console.log(`Godot：${GODOT}`);
  console.log(`解释器：${PYTHON}`);
  console.log(`目录端口 ${DIR_PORT}，假房间端口 ${ROOM_PORT}\n`);

  directory = spawn(PYTHON, ["tools/room-directory.py", "--port", String(DIR_PORT)], {
    cwd: REPO, stdio: ["ignore", "pipe", "pipe"],
  });
  const dirLines = [];
  const keep = (chunk) =>
    chunk.toString().split(/\r?\n/).forEach((line) => line.trim() && dirLines.push(line));
  directory.stdout.on("data", keep);
  directory.stderr.on("data", keep);

  let up = false;
  for (let i = 0; i < 30; i++) {
    if (await health()) { up = true; break; }
    await sleep(300);
  }
  if (!up) throw new Error("目录没有起来（30 次探测都没应答）");
  ok(true, "真目录起来了");

  // 登记一个**空着的**房间：正是池里那间备用房的样子。
  // `players: 0` 是关键——它不会出现在公开列表里（见 room-directory.py 的 busy()），
  // 因此只能靠认领拿到，这与真部署的语义完全一致。
  const registered = await fetch(`${base}/rooms`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      name: "自检用空房", host: "check.example.com", port: ROOM_PORT,
      players: 0, max: 2, state: "waiting",
    }),
  });
  ok(registered.ok, "登记了一间空着的房间");
  const publicList = (await (await fetch(`${base}/rooms`)).json()).rooms;
  ok(publicList.length === 0, `空房不该出现在公开列表里（实际 ${publicList.length} 项）`);

  // 真客户端。它自己会做「先起一个列表请求、紧接着认领」这一串。
  const driver = spawnSync(GODOT, [
    "--headless", "--path", REPO, "--script", "tests/directory_client_test.gd",
    "--", "--base", base, "--expect-port", String(ROOM_PORT),
  ], { cwd: REPO, encoding: "utf8", timeout: 120000 });
  const output = `${driver.stdout || ""}\n${driver.stderr || ""}`;
  process.stdout.write(output.endsWith("\n") ? output : `${output}\n`);

  if (/SCRIPT ERROR|Parse Error/.test(output)) {
    failures.push("客户端驱动里出现脚本错误");
  }
  ok(driver.status === 0, `客户端驱动的断言全部通过（退出码 ${driver.status}）`);
  ok(/目录客户端接线测试通过/.test(output), "驱动跑完并打印了通过结论");

  // 可选：用**配置里的域名**跑一轮。默认不跑，因为它要外网 DNS 与一台真的服务器。
  if (args.includes("--real")) {
    console.log("\n--- 额外一轮：直接用 config/product.cfg 里的域名（验域名解析）---");
    const real = spawnSync(GODOT, [
      "--headless", "--path", REPO, "--script", "tests/directory_client_test.gd",
      "--", "--from-config",
    ], { cwd: REPO, encoding: "utf8", timeout: 120000 });
    const realOut = `${real.stdout || ""}\n${real.stderr || ""}`;
    process.stdout.write(realOut.endsWith("\n") ? realOut : `${realOut}\n`);
    ok(real.status === 0, `对着真配置跑也通过（退出码 ${real.status}）`);
    ok(/目录地址应当用解析出的 IP/.test(realOut) && !/--  目录地址应当用解析出的 IP/.test(realOut),
      "目录地址确实用的是解析出的 IP（而不是域名）");
  }
} catch (err) {
  console.log(`  --  异常：${err && err.stack ? err.stack : err}`);
  failures.push("异常");
} finally {
  if (directory) directory.kill("SIGKILL");
  await sleep(300);
}

console.log(failures.length ? `目录客户端自检失败（${failures.length} 项）` : "目录客户端自检通过。");
process.exit(failures.length ? 1 : 0);
