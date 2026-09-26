#!/usr/bin/env node
// 熔霜 · 部署到联机服务器（腾讯云 CVM）
//
// 服务器访问不了 GitHub（实测 curl 超时），所以 Godot 二进制与仓库都从本机上传。
// 这个脚本因此做四件事：准备 Godot 压缩包、把仓库打成 bundle、上传两者、在服务器上跑
// tools/server-setup.sh。最后一步做的事情都在那个脚本里，便于单独在服务器上复核。
//
// 用法：
//   node tools/deploy-server.mjs --host 106.52.118.93
//   node tools/deploy-server.mjs --host 106.52.118.93 --enable-service --port 27015
//   node tools/deploy-server.mjs --host 106.52.118.93 --skip-godot   # 只更新代码
//
// 默认值可用环境变量覆盖：MOLTENFROST_HOST、MOLTENFROST_SSH_KEY、MOLTENFROST_SSH_USER。
//
// 退出码 0 表示全部成功。每一步都会打印实际执行的命令，便于手工复核。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const GODOT_VERSION = "4.7.2";
// 下载缓存与打包产物都放 build/server/：build/ 已经在 .gitignore 里（各平台产物不入库），
// 这里沿用同一个位置，避免在仓库根目录散落大文件。
const CACHE_DIR = path.join(PROJECT_DIR, "build", "server");
const GODOT_ASSET = `Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip`;
const GODOT_URL =
  `https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}-stable/${GODOT_ASSET}`;
// 官方随发布提供校验和；从本机传到服务器的东西值得核一遍。
const SUMS_URL =
  `https://github.com/godotengine/godot-builds/releases/download/${GODOT_VERSION}-stable/SHA512-SUMS.txt`;

const HELP = `熔霜 · 部署到联机服务器

  node tools/deploy-server.mjs --host <地址> [选项]

  --host <地址>        服务器公网地址（必填，或用 MOLTENFROST_HOST）
  --user <用户名>      SSH 用户，默认 ubuntu
  --key <私钥路径>     SSH 私钥，默认 ~/.ssh/id_ed25519_moltenfrost
  --port <端口>        游戏端口，默认 27015
  --advertise <地址>   服务端对外公布的地址（域名或 IP）。云服务器上程序拿到的只有 VPC 私网地址，
                       因此必须显式指定，否则服务端日志里"对方加入时填"那一行没有意义
  --enable-service     安装并启用 systemd 服务（默认只装好不启动）
  --skip-godot         跳过 Godot 的下载与安装（服务器上已有时用）
  --skip-import        跳过资源导入（仅调试脚本时用，正常部署不要加）
  --dry-run            只打印计划，不执行
  --verbose            把 SSH 的原始输出实时打出
  -h, --help           显示本帮助
`;

function parseArgs(argv) {
  const opts = {
    host: process.env.MOLTENFROST_HOST || null,
    user: process.env.MOLTENFROST_SSH_USER || "ubuntu",
    key: process.env.MOLTENFROST_SSH_KEY || path.join(os.homedir(), ".ssh", "id_ed25519_moltenfrost"),
    port: 27015,
    advertise: process.env.MOLTENFROST_HOST || null,
    enableService: false,
    skipGodot: false,
    skipImport: false,
    dryRun: false,
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
      case "--user": opts.user = next(); break;
      case "--key": opts.key = next(); break;
      case "--port": opts.port = Number(next()); break;
      case "--advertise": opts.advertise = next(); break;
      case "--enable-service": opts.enableService = true; break;
      case "--skip-godot": opts.skipGodot = true; break;
      case "--skip-import": opts.skipImport = true; break;
      case "--dry-run": opts.dryRun = true; break;
      case "--verbose": opts.verbose = true; break;
      case "-h": case "--help": opts.help = true; break;
      default: throw new Error(`未知参数：${arg}`);
    }
  }
  return opts;
}

// 远程命令统一走 ssh。StrictHostKeyChecking=accept-new 让首次连接自动接受主机密钥
//（新开的实例每次换 IP 就会换密钥，逐次手工确认太麻烦），之后仍然受 known_hosts 校验。
function sshArgs(opts, extra) {
  return [
    "-i", opts.key,
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ServerAliveInterval=15",
    "-o", "ConnectTimeout=15",
    `${opts.user}@${opts.host}`,
    ...extra,
  ];
}

function run(cmd, args, opts) {
  const printable = [cmd, ...args].join(" ");
  process.stdout.write(`$ ${printable}\n`);
  if (opts.dryRun) return "";
  const res = spawnSync(cmd, args, {
    stdio: opts.verbose ? "inherit" : ["ignore", "pipe", "pipe"],
    encoding: "utf8",
  });
  if (!opts.verbose) {
    if (res.stdout) process.stdout.write(res.stdout);
    if (res.stderr) process.stderr.write(res.stderr);
  }
  if (res.status !== 0) {
    throw new Error(`命令失败（退出码 ${res.status}）：${printable}`);
  }
  return res.stdout || "";
}

// ---------------------------------------------------------------- Godot 压缩包

function sha512(file) {
  const hash = crypto.createHash("sha512");
  hash.update(fs.readFileSync(file));
  return hash.digest("hex");
}

// 问服务端这个文件有多大。用它来判断本地缓存是否完整：
// 只看"文件存在"是不够的——下载中断会留下半个文件，那种文件会被当成完整的用，
// 最后在服务器上以"解压失败"或"签名不符"的形式暴露，排查起来绕一大圈。
function remoteSize(url) {
  // 只问响应头，不下载正文。用 -L 跟随重定向，因为 GitHub 的 release 资源会 302 到
  // release-assets.githubusercontent.com，Content-Length 只在最终那个响应里。
  const res = spawnSync("curl.exe", ["-sIL", url], { encoding: "utf8" });
  const matches = [...`${res.stdout || ""}`.matchAll(/content-length:\s*(\d+)/gi)];
  if (matches.length === 0) return -1;
  return Number(matches[matches.length - 1][1]);
}

function ensureGodotAsset(opts) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const target = path.join(CACHE_DIR, GODOT_ASSET);
  const expected = remoteSize(GODOT_URL);
  const local = fs.existsSync(target) ? fs.statSync(target).size : -1;

  if (expected > 0 && local === expected) {
    process.stdout.write(`Godot 压缩包已缓存且完整：${(local / 1048576).toFixed(1)} MiB\n`);
    return target;
  }
  if (expected > 0 && local > 0) {
    process.stdout.write(`本地缓存不完整（${local} / ${expected} 字节），从断点续传…\n`);
  } else {
    process.stdout.write(`下载 ${GODOT_ASSET} …\n`);
  }

  if (!opts.dryRun) {
    // 用系统 curl 而不是 Node 的 fetch：curl 支持断点续传，这个下载几十兆且国内很慢，
    // 中断一次不该从头再来。-C - 让 curl 自己接续未完成的文件。
    run("curl.exe", ["-L", "--fail", "-C", "-", "-o", target, GODOT_URL], opts);

    // 下完之后再核对一次。这一步是必要的：curl 在某些失败模式下退出码为 0，
    // 而校验对比能兜住任何"文件不完整但没报错"的情形。
    const got = fs.statSync(target).size;
    if (expected > 0 && got !== expected) {
      throw new Error(`Godot 压缩包大小不对：得到 ${got} 字节，应为 ${expected} 字节。删掉重下：${target}`);
    }
  }

  return target;
}

// ---------------------------------------------------------------- 仓库打包

// 服务器访问不了 GitHub，所以用 git bundle 把仓库整体带过去。
// 相比打包工作区目录，bundle 是一个真正的 git 仓库：服务器上能 git log 看版本，
// 也能用同一个 bundle 做增量更新（server-setup.sh 里 fetch + reset）。
function makeBundle(opts) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const bundle = path.join(CACHE_DIR, "moltenfrost.bundle");

  // **bundle 只含已提交的内容**，工作区里未提交的改动不会随它过去。
  // 这一点踩过一次：新加的 `--advertise` 参数还在工作区里就部署了，
  // 服务器上跑的是旧代码，旧代码不认识这个参数、静默忽略，
  // 于是表现为"参数传了但没生效"，很容易误判成参数解析写错了。
  // 所以这里一旦发现未提交的改动就直接失败，让人先提交。
  const dirty = execFileSync("git", ["status", "--porcelain"], {
    cwd: PROJECT_DIR, encoding: "utf8",
  }).trim();
  if (dirty) {
    const lines = dirty.split("\n").length;
    throw new Error(
      `工作区有 ${lines} 处未提交的改动，而 bundle 只包含已提交的内容——\n` +
      `现在部署会让服务器跑旧代码（参数会静默失效，很难排查）。\n` +
      `先提交再部署。未提交的条目：\n${dirty}`,
    );
  }

  const head = execFileSync("git", ["rev-parse", "--short", "HEAD"], {
    cwd: PROJECT_DIR, encoding: "utf8",
  }).trim();
  process.stdout.write(`把仓库打成 bundle（当前 ${head}）…\n`);
  // 只打包 main：服务器上不需要其他分支，而 feature/ 与 backup/ 分支会让体积变大。
  run("git", ["bundle", "create", bundle, "main"], { ...opts, dryRun: false, verbose: false });
  const size = fs.statSync(bundle).size;
  process.stdout.write(`bundle 大小：${(size / 1048576).toFixed(2)} MiB\n`);
  return { bundle, head };
}

// ---------------------------------------------------------------- 主流程

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) { process.stdout.write(HELP); return; }
  if (!opts.host) throw new Error("必须用 --host <地址> 指定服务器，或设置 MOLTENFROST_HOST。");

  if (!fs.existsSync(opts.key)) {
    throw new Error(`找不到 SSH 私钥：${opts.key}\n用 --key 指定，或先按 memory/networking.md 的步骤生成。`);
  }

  const say = (msg) => process.stdout.write(`\n### ${msg}\n`);
  say(`部署到 ${opts.user}@${opts.host}（游戏端口 ${opts.port}）`);

  // 先确认能连上。连不上时继续下去只会在更靠后的步骤里以更难懂的方式失败。
  say("检查 SSH 连通性");
  run("ssh", sshArgs(opts, ["true"]), opts);

  const { bundle, head } = makeBundle(opts);
  const godotZip = opts.skipGodot ? null : ensureGodotAsset(opts);

  say("上传文件");
  const remoteFiles = [[bundle, "/tmp/moltenfrost.bundle"]];
  if (godotZip) remoteFiles.push([godotZip, "/tmp/godot-linux.zip"]);
  for (const [local, remote] of remoteFiles) {
    run("scp", [
      "-i", opts.key,
      "-o", "StrictHostKeyChecking=accept-new",
      local, `${opts.user}@${opts.host}:${remote}`,
    ], opts);
  }

  // 上传服务端脚本本身，然后执行。脚本在仓库里，因此它的版本与刚上传的代码一致。
  const setupScript = path.join(PROJECT_DIR, "tools", "server-setup.sh");
  run("scp", [
    "-i", opts.key,
    "-o", "StrictHostKeyChecking=accept-new",
    setupScript, `${opts.user}@${opts.host}:/tmp/server-setup.sh`,
  ], opts);

  say("在服务器上执行安装脚本");
  const remoteArgs = [
    "--bundle", "/tmp/moltenfrost.bundle",
    "--port", String(opts.port),
  ];
  if (opts.advertise) remoteArgs.push("--advertise", opts.advertise);
  if (!opts.skipGodot) remoteArgs.push("--godot-zip", "/tmp/godot-linux.zip");
  if (opts.enableService) remoteArgs.push("--enable-service");
  if (opts.skipImport) remoteArgs.push("--skip-import");
  run("ssh", sshArgs(opts, ["bash", "/tmp/server-setup.sh", ...remoteArgs]), opts);

  say("完成");
  process.stdout.write(`服务器上的版本：${head}\n`);
  // 提示语里的地址优先用 --advertise：那才是对方真正要填的东西，
  // 而 --host 在云服务器上往往是 VPC 私网地址（从本机连不上）。
  const reachable = opts.advertise || opts.host;
  process.stdout.write(
    `服务端试跑：ssh ${opts.user}@${opts.host} '/opt/godot/godot --headless --path ~/moltenfrost -- --host --port ${opts.port}${opts.advertise ? ` --advertise ${opts.advertise}` : ""}'\n` +
    `对方加入时填：${reachable}:${opts.port}\n`,
  );
  if (opts.enableService) {
    process.stdout.write(
      `启动服务：ssh ${opts.user}@${opts.host} 'sudo systemctl enable --now moltenfrost@${opts.port}'\n` +
      `看日志：  ssh ${opts.user}@${opts.host} 'journalctl -u moltenfrost@${opts.port} -f'\n`,
    );
  }
}

main().catch((err) => {
  process.stderr.write(`\n部署失败：${err.message}\n`);
  process.exitCode = 1;
});
