#!/usr/bin/env node
// 熔霜 · 开发环境初始化
//
// 目前只做一件事：装好**本机平台**的导出模板。
// 本项目约定各机器只导自己平台的产物（Windows 机器导 Windows，Mac 机器导 macOS），
// 所以默认只装本机那一份；要装另一份得显式传 --platforms。
//
// 官方模板包 Godot_v<版本>-<渠道>_export_templates.tpz 有 1.2 GiB，里面装着十几个平台的
// 模板，本项目只用得到两个。所以这里不整包下载，而是：
//   1. 读到 ZIP 的中央目录（用 HTTP Range 只取文件尾部几十 KB）
//   2. 挑出需要的几个条目
//   3. 只把这几个条目的字节段拉下来，本地解压后写进 Godot 的导出模板目录
// 实际流量从 1.2 GiB 降到一百多 MB。
//
// 用法：
//   node tools/setup-dev-env.mjs                 # 装本机平台的模板
//   node tools/setup-dev-env.mjs --check         # 只看当前有没有装好，不下载
//   node tools/setup-dev-env.mjs --dry-run       # 只报要下载哪些文件、多大
//   node tools/setup-dev-env.mjs --list          # 列出模板包里所有条目（排查用）
//   node tools/setup-dev-env.mjs --platforms windows,macos
//   node tools/setup-dev-env.mjs --force         # 已存在的也重下
//   node tools/setup-dev-env.mjs --concurrency 8 # 并行连接数（GitHub CDN 单连接很慢）
//   node tools/setup-dev-env.mjs --version 4.6.1
//   node tools/setup-dev-env.mjs --godot /path/to/Godot
//
// 网络受限时可以用 MOLTENFROST_TPZ_URL 指向自建镜像。
//
// 下载是并行分块的：每个条目按 --chunk-mib 切段，同时开 --concurrency 个连接去取。
// 说明：在本机实测，到 GitHub CDN 的速度被压在 0.11 MiB/s 左右，开 6 个连接并不更快
// （瓶颈是单 IP 限速，不是连接数）。所以默认并发取 4，网络状况不同时可以调。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { execFileSync } from "node:child_process";

const DEFAULT_VERSION = "4.7.2";
const DEFAULT_FLAVOR = "stable";
const RELEASE_REPO = "godotengine/godot-builds";

// 各平台需要的模板条目（tpz 内的名字，不含 templates/ 前缀）。
// Windows 只要 x86_64：Intel 与 AMD 的 PC 都是这个架构。
// macOS 只要 macos.zip：注意这个包里**只有 universal 二进制**
// （godot_macos_debug.universal / godot_macos_release.universal）。
// 导出预设的 binary_format/architecture 选 arm64 或 x86_64 都会失败，报
// "未找到请求的模板二进制文件 godot_macos_release.<架构>"，所以 macOS 只能出 universal。
const PLATFORM_ENTRIES = {
  windows: [
    "windows_debug_x86_64.exe",
    "windows_release_x86_64.exe",
    // 带控制台窗口的包装程序，导出预设里的 console wrapper 会用到，两个加起来 370 KiB
    "windows_debug_x86_64_console.exe",
    "windows_release_x86_64_console.exe",
  ],
  macos: ["macos.zip"],
};
// version.txt 是 Godot 用来校验模板版本的文件，必须有。
// icudt_godot.dat 是官方模板集里的公共数据文件，体积不大，一起取上。
const ALWAYS_ENTRIES = ["version.txt", "icudt_godot.dat"];

// 本机是哪个目标平台。返回 null 表示当前系统不在本项目的目标范围内（例如 Linux）。
function currentPlatform() {
  if (process.platform === "win32") return "windows";
  if (process.platform === "darwin") return "macos";
  return null;
}

const SIG_EOCD = 0x06054b50;
const SIG_EOCD64_LOCATOR = 0x07064b50;
const SIG_EOCD64 = 0x06064b50;
const SIG_CD = 0x02014b50;
const TAIL_BYTES = 66 * 1024; // EOCD 22 字节 + 最长 64 KiB 注释

// ---------------------------------------------------------------- 参数

function parseArgs(argv) {
  const opts = {
    version: null,
    flavor: DEFAULT_FLAVOR,
    // 默认只装本机平台：各机器只导自己平台的产物，另一份模板下来也是白占空间。
    platforms: currentPlatform() ? [currentPlatform()] : Object.keys(PLATFORM_ENTRIES),
    godot: null,
    dir: null,
    list: false,
    check: false,
    dryRun: false,
    force: false,
    concurrency: Number(process.env.MOLTENFROST_CONCURRENCY || 4),
    chunkMiB: 8,
    only: null,
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
      case "--version": opts.version = next(); break;
      case "--flavor": opts.flavor = next(); break;
      case "--platforms": opts.platforms = next().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--godot": opts.godot = next(); break;
      case "--dir": opts.dir = next(); break;
      case "--list": opts.list = true; break;
      case "--check": opts.check = true; break;
      case "--dry-run": opts.dryRun = true; break;
      case "--force": opts.force = true; break;
      case "--concurrency": opts.concurrency = Number(next()); break;
      case "--chunk-mib": opts.chunkMiB = Number(next()); break;
      case "--only": opts.only = next().split(",").map((s) => s.trim()).filter(Boolean); break;
      case "-h": case "--help": opts.help = true; break;
      default: throw new Error(`未知参数：${arg}`);
    }
  }
  for (const p of opts.platforms) {
    if (!PLATFORM_ENTRIES[p]) {
      throw new Error(`不支持的平台：${p}（可用：${Object.keys(PLATFORM_ENTRIES).join(", ")}）`);
    }
  }
  return opts;
}

const HELP = `熔霜 · 开发环境初始化

  node tools/setup-dev-env.mjs [选项]

  --platforms <列表>  要装的平台，逗号分隔；默认只装本机平台（windows 或 macos）
  --version <版本>    模板版本，默认自动从本机 Godot 读，读不到用 ${DEFAULT_VERSION}
  --flavor <渠道>     默认 ${DEFAULT_FLAVOR}
  --godot <路径>      Godot 可执行文件，用来确定版本
  --dir <路径>        导出模板目录，默认按系统规则推算
  --list              列出模板包内所有条目
  --check             只检查已装情况
  --dry-run           不写盘，只报计划
  --force             已存在且大小一致的也重下
  --concurrency <n>   并行连接数，默认 4（受限速影响时调大未必更快）
  --chunk-mib <n>     分块大小，默认 8
  --only <文件名>     只处理指定的模板条目，逗号分隔（例如 version.txt）
  -h, --help          显示本帮助
`;

// ---------------------------------------------------------------- 版本

function parseGodotVersion(raw) {
  // 形如 4.7.2.stable.official.ed1daf0bf
  const m = /^(\d+\.\d+(?:\.\d+)?)\.([a-z0-9]+)/i.exec(String(raw).trim());
  if (!m) return null;
  return { version: m[1], flavor: m[2] };
}

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
  }

  for (const cmd of candidates) {
    try {
      const out = execFileSync(cmd, ["--version"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
      const parsed = parseGodotVersion(out);
      if (parsed) return { ...parsed, binary: cmd };
    } catch { /* 换下一个 */ }
  }
  return null;
}

// ---------------------------------------------------------------- 路径

function templatesDir(version, flavor, override) {
  if (override) return override;
  const folder = `${version}.${flavor}`;
  let base;
  if (process.platform === "win32") {
    base = path.join(process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming"), "Godot", "export_templates");
  } else if (process.platform === "darwin") {
    base = path.join(os.homedir(), "Library", "Application Support", "Godot", "export_templates");
  } else {
    base = path.join(os.homedir(), ".local", "share", "godot", "export_templates");
  }
  return path.join(base, folder);
}

function tpzUrl(version, flavor) {
  if (process.env.MOLTENFROST_TPZ_URL) return process.env.MOLTENFROST_TPZ_URL;
  const file = `Godot_v${version}-${flavor}_export_templates.tpz`;
  return `https://github.com/${RELEASE_REPO}/releases/download/${version}-${flavor}/${file}`;
}

// ---------------------------------------------------------------- HTTP Range

async function rangeGet(url, start, end, resolvedUrl) {
  const res = await fetch(resolvedUrl || url, {
    headers: { Range: `bytes=${start}-${end}`, "User-Agent": "moltenfrost-setup" },
    redirect: "follow",
  });
  if (!res.ok) throw new Error(`请求失败：HTTP ${res.status} ${res.statusText}`);
  const contentRange = res.headers.get("content-range");
  if (res.status !== 206 || !contentRange) {
    throw new Error("服务器没有按 Range 返回分段内容。拒绝退化成整包下载（那是 1.2 GiB）。");
  }
  const m = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(contentRange.trim());
  if (!m) throw new Error(`看不懂的 Content-Range：${contentRange}`);
  return { data: Buffer.from(await res.arrayBuffer()), total: Number(m[3]), url: res.url };
}

// 把一段字节切成小块并行取回再拼起来。GitHub CDN 单连接常被压到 0.1 MiB/s 上下，
// 多开几个连接能显著缩短总时间。
async function rangeGetParallel(url, start, end, resolvedUrl, opts, onProgress) {
  const total = end - start + 1;
  const chunkBytes = Math.max(1, Math.floor(opts.chunkMiB * 1024 * 1024));
  const chunks = [];
  for (let off = start; off <= end; off += chunkBytes) {
    chunks.push({ start: off, end: Math.min(off + chunkBytes - 1, end) });
  }

  const out = Buffer.allocUnsafe(total);
  let done = 0;
  let cursor = 0;

  const worker = async () => {
    for (;;) {
      const index = cursor++;
      if (index >= chunks.length) return;
      const c = chunks[index];
      const expect = c.end - c.start + 1;
      let data = null;
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          const res = await rangeGet(url, c.start, c.end, resolvedUrl);
          if (res.data.length !== expect) {
            throw new Error(`分块长度不对：要 ${expect}，实际 ${res.data.length}`);
          }
          data = res.data;
          break;
        } catch (err) {
          if (attempt === 3) throw err;
          await new Promise((r) => setTimeout(r, 300 * attempt));
        }
      }
      data.copy(out, c.start - start);
      done += data.length;
      if (onProgress) onProgress(done, total);
    }
  };

  const workers = [];
  const n = Math.max(1, Math.min(opts.concurrency, chunks.length));
  for (let i = 0; i < n; i++) workers.push(worker());
  await Promise.all(workers);
  return out;
}

// ---------------------------------------------------------------- ZIP 读取

function readZip64Extra(extra) {
  let p = 0;
  while (p + 4 <= extra.length) {
    const tag = extra.readUInt16LE(p);
    const size = extra.readUInt16LE(p + 2);
    if (tag === 0x0001) return extra.subarray(p + 4, p + 4 + size);
    p += 4 + size;
  }
  return null;
}

async function readCentralDirectory(url, log) {
  const probe = await rangeGet(url, 0, 0);
  const total = probe.total;
  const resolvedUrl = probe.url;
  log(`模板包：${(total / 1024 / 1024).toFixed(1)} MiB`);

  const tailSize = Math.min(TAIL_BYTES, total);
  const tailStart = total - tailSize;
  const tail = (await rangeGet(url, tailStart, total - 1, resolvedUrl)).data;

  let eocd = -1;
  for (let i = tail.length - 22; i >= 0; i--) {
    if (tail.readUInt32LE(i) === SIG_EOCD) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("找不到 ZIP 的中央目录结尾（EOCD），这个包可能不是标准 ZIP");

  let cdEntries = tail.readUInt16LE(eocd + 10);
  let cdSize = tail.readUInt32LE(eocd + 12);
  let cdOffset = tail.readUInt32LE(eocd + 16);

  // ZIP64：条目数或偏移越界时走 64 位记录
  const locatorAt = eocd - 20;
  if (locatorAt >= 0 && tail.readUInt32LE(locatorAt) === SIG_EOCD64_LOCATOR) {
    const eocd64Offset = Number(tail.readBigUInt64LE(locatorAt + 8));
    const eocd64 = (await rangeGet(url, eocd64Offset, eocd64Offset + 55, resolvedUrl)).data;
    if (eocd64.readUInt32LE(0) === SIG_EOCD64) {
      cdEntries = Number(eocd64.readBigUInt64LE(32));
      cdSize = Number(eocd64.readBigUInt64LE(40));
      cdOffset = Number(eocd64.readBigUInt64LE(48));
    }
  }

  const cd = (await rangeGet(url, cdOffset, cdOffset + cdSize - 1, resolvedUrl)).data;
  const entries = [];
  let p = 0;
  while (p + 46 <= cd.length && cd.readUInt32LE(p) === SIG_CD) {
    let method = cd.readUInt16LE(p + 10);
    let compSize = cd.readUInt32LE(p + 20);
    let uncompSize = cd.readUInt32LE(p + 24);
    const nameLen = cd.readUInt16LE(p + 28);
    const extraLen = cd.readUInt16LE(p + 30);
    const commentLen = cd.readUInt16LE(p + 32);
    let localOffset = cd.readUInt32LE(p + 42);
    const name = cd.subarray(p + 46, p + 46 + nameLen).toString("utf8");

    if (compSize === 0xffffffff || uncompSize === 0xffffffff || localOffset === 0xffffffff) {
      const z64 = readZip64Extra(cd.subarray(p + 46 + nameLen, p + 46 + nameLen + extraLen));
      if (z64) {
        let q = 0;
        if (uncompSize === 0xffffffff) { uncompSize = Number(z64.readBigUInt64LE(q)); q += 8; }
        if (compSize === 0xffffffff) { compSize = Number(z64.readBigUInt64LE(q)); q += 8; }
        if (localOffset === 0xffffffff) { localOffset = Number(z64.readBigUInt64LE(q)); }
      }
    }
    if (name && !name.endsWith("/")) {
      entries.push({ name, method, compSize, uncompSize, localOffset });
    }
    p += 46 + nameLen + extraLen + commentLen;
  }
  if (entries.length !== cdEntries) {
    log(`注意：中央目录声明 ${cdEntries} 个条目，实际解析出 ${entries.length} 个`);
  }
  return { entries, resolvedUrl };
}

async function readEntry(url, entry, resolvedUrl, opts, onProgress) {
  const header = (await rangeGet(url, entry.localOffset, entry.localOffset + 29, resolvedUrl)).data;
  const nameLen = header.readUInt16LE(26);
  const extraLen = header.readUInt16LE(28);
  const dataStart = entry.localOffset + 30 + nameLen + extraLen;
  const raw = await rangeGetParallel(url, dataStart, dataStart + entry.compSize - 1, resolvedUrl, opts, onProgress);
  if (entry.method === 0) return raw;
  if (entry.method === 8) return zlib.inflateRawSync(raw);
  throw new Error(`不支持的压缩方式：${entry.method}（条目 ${entry.name}）`);
}

// ---------------------------------------------------------------- 主流程

function human(bytes) {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MiB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(0)} KiB`;
  return `${bytes} B`;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) { process.stdout.write(HELP); return; }

  const say = (msg) => process.stdout.write(`${msg}\n`);

  let version = opts.version;
  let flavor = opts.flavor;
  if (!version) {
    const found = detectGodot();
    if (found) {
      version = found.version;
      flavor = found.flavor;
      say(`检测到 Godot ${version}.${flavor}（${found.binary}）`);
    } else {
      version = DEFAULT_VERSION;
      say(`没找到本机 Godot，按默认版本 ${DEFAULT_VERSION}.${DEFAULT_FLAVOR} 处理`);
    }
  }

  const destDir = templatesDir(version, flavor, opts.dir);
  const wanted = [];
  for (const platform of opts.platforms) {
    for (const name of PLATFORM_ENTRIES[platform]) wanted.push({ platform, name });
  }
  for (const name of ALWAYS_ENTRIES) wanted.push({ platform: "-", name });

  // --check：只照本地目录看一遍，不联网
  if (opts.check) {
    say(`模板目录：${destDir}`);
    if (!fs.existsSync(destDir)) { say("状态：目录不存在"); return; }
    let missing = 0;
    for (const want of wanted) {
      const file = path.join(destDir, want.name);
      const ok = fs.existsSync(file);
      if (!ok) missing++;
      say(`  ${ok ? "有" : "缺"}  ${want.name}${ok ? `  ${human(fs.statSync(file).size)}` : ""}`);
    }
    say(missing === 0 ? "状态：齐全" : `状态：缺 ${missing} 个文件，跑一次不带 --check 的命令即可`);
    return;
  }

  const url = tpzUrl(version, flavor);
  say(`版本：${version}.${flavor}`);
  say(`来源：${url}`);
  const { entries, resolvedUrl } = await readCentralDirectory(url, say);

  if (opts.list) {
    for (const e of entries) say(`  ${human(e.uncompSize).padStart(9)}  ${e.name}`);
    return;
  }

  // 挑条目
  const chosen = [];
  if (opts.only) {
    // --only 直接按条目名取，不限于平台映射里的那几个文件
    for (const name of opts.only) {
      const hit = entries.find((e) => e.name === `templates/${name}` || e.name === name);
      if (!hit) throw new Error(`模板包里没有 ${name}。用 --list 看看实际有哪些条目。`);
      chosen.push({ platform: "only", name: path.posix.basename(hit.name), entry: hit });
    }
  } else {
    for (const want of wanted) {
      const hit = entries.find((e) => e.name === `templates/${want.name}`);
      if (!hit) {
        throw new Error(`模板包里没有 templates/${want.name}。用 --list 看看实际有哪些条目。`);
      }
      chosen.push({ ...want, entry: hit });
    }
  }
  if (chosen.length === 0) throw new Error("没有选中任何条目");

  const totalBytes = chosen.reduce((sum, c) => sum + c.entry.uncompSize, 0);
  say(`\n要装 ${chosen.length} 个文件，共 ${human(totalBytes)}（完整模板包是 ${human(1281349702)} 量级）`);
  for (const c of chosen) say(`  ${human(c.entry.uncompSize).padStart(9)}  ${c.name}`);

  if (opts.dryRun) { say("\n--dry-run：没有写盘。"); return; }

  fs.mkdirSync(destDir, { recursive: true });
  for (const c of chosen) {
    const outPath = path.join(destDir, c.name);
    if (!opts.force && fs.existsSync(outPath) && fs.statSync(outPath).size === c.entry.uncompSize) {
      say(`  跳过（已存在且大小一致）  ${c.name}`);
      continue;
    }
    say(`  下载中  ${c.name}`);
    let mark = -1;
    const data = await readEntry(url, c.entry, resolvedUrl, opts, (done, total) => {
      const pct = Math.floor((done / total) * 100);
      if (pct >= mark + 20 || pct === 100) {
        mark = pct;
        process.stdout.write(process.stdout.isTTY ? `\r  ${c.name} ${pct}%` : `  ${c.name} ${pct}%\n`);
      }
    });
    if (process.stdout.isTTY) process.stdout.write("\n");
    if (data.length !== c.entry.uncompSize) {
      throw new Error(`${c.name} 解出来的大小是 ${data.length}，预期 ${c.entry.uncompSize}`);
    }
    // 先写 .part 再改名：中途失败不会留下一个"大小恰好对得上"的半成品被后续运行跳过
    const partPath = `${outPath}.part`;
    fs.writeFileSync(partPath, data);
    fs.renameSync(partPath, outPath);
    say(`  写入    ${outPath}`);
  }

  say(`\n完成。模板目录：${destDir}`);
  say("接下来在 Godot 里给项目加 Windows 与 macOS 两个导出预设即可。");
}

main().catch((err) => {
  process.stderr.write(`\n失败：${err.message}\n`);
  process.exitCode = 1;
});
