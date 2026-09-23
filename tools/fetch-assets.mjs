#!/usr/bin/env node
// 下载 CC0 素材：ambientCG 的表面贴图（PBR）与 Poly Haven 的环境贴图（HDRI）。
//
// 为什么用脚本而不是手工下载：素材要能随工程重建。换一台机器、或以后整体换风格时，
// 重跑一次即可，不需要回忆当初点过哪些链接。清单写在 ASSETS 里，是这个文件的唯一事实来源。
//
// 为什么只取 1K：本工程是桌面端第一人称，相机离墙面 1～8 米，1K 在这些距离上已经看不出
// 像素级差异，而体积只有 2K 的四分之一左右。要提清晰度时改 ATTRIBUTE 一处即可。
//
// 依赖：只用 Node 内置模块。ZIP 解压自己实现（约 60 行，见下），
// 因为引入 npm 依赖会让「新机器跑通工程」多一步，而这里只需要读 deflate 与 stored 两种条目。
//
//   node tools/fetch-assets.mjs              下载全部清单
//   node tools/fetch-assets.mjs --list       只列出将要下载的内容与体积
//   node tools/fetch-assets.mjs --only MetalPlates006
//   node tools/fetch-assets.mjs --force      已存在的也重新下载

import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const TEXTURE_DIR = path.join(PROJECT_DIR, "assets", "textures");
const HDRI_DIR = path.join(PROJECT_DIR, "assets", "hdri");

const ATTRIBUTE = "1K-JPG";

// 表面贴图清单。maps 是要保留的贴图种类；其余（Displacement、Metalness 之外的、mtlx、blend 等）删掉，
// 因为本工程的材质只用反照率、法线、粗糙度、金属度与环境光遮蔽五种，多留的只是仓库体积。
// 不是每个素材都有全部五种：ambientCG 对部分素材不提供金属度或环境光遮蔽，
// 缺失的那些由下载函数报出来，材质侧会按文件是否存在决定用不用。
//
// 用途一列是给后来人看的：换素材时先看这一列，才知道某个 id 是被哪一处引用的。
const SURFACES = [
  { id: "MetalPlates006", maps: ["Color", "NormalGL", "Roughness", "Metalness"], use: "地板与金属槽件：菱形防滑钢板（深中性灰，线性亮度 0.056）" },
  { id: "Metal032", maps: ["Color", "NormalGL", "Roughness", "Metalness"], use: "墙面：拉丝金属板（中性偏蓝，0.252）" },
  { id: "CorrugatedSteel009", maps: ["Color", "NormalGL", "Roughness", "Metalness", "AmbientOcclusion"], use: "天花板与结构：瓦楞钢（中性，0.231）" },
  { id: "Metal006", maps: ["Color", "NormalGL", "Roughness", "Metalness"], use: "角色装甲与武器：亮中性金属（0.328）；明暗靠染色区分" },
];

// 环境贴图。这一条是「去塑料感」的关键：金属材质本身几乎不漫反射，
// 它显示的全部是环境反射；环境里没有可反射的内容时，金属必然看起来像塑料。
const HDRIS = [
  { id: "abandoned_workshop", use: "环境反射与间接光：废弃车间的窗光与灯管" },
];

function parseArgs(argv) {
  const opts = { list: false, force: false, only: null, try: null };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--list": opts.list = true; break;
      case "--force": opts.force = true; break;
      case "--only": opts.only = argv[++i]; break;
      // 试素材用：下载一个不在清单里的素材，只取反照率/法线/粗糙度三张。
      // 用途是在决定换素材之前先量一下它的平均色（tools/texture-probe.gd），
      // 而不用先改清单、下载全套、发现颜色不对、再改回来。
      case "--try": opts.try = argv[++i]; break;
    }
  }
  return opts;
}

// ---------------------------------------------------------------- 下载

async function download(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`下载失败 HTTP ${res.status}：${url}`);
  return Buffer.from(await res.arrayBuffer());
}

// ---------------------------------------------------------------- ZIP
//
// 只实现读取。ambientCG 的包用 deflate，个别小文件用 stored，
// 因此这两种 method 都要支持。做法是按中央目录定位每个条目，再读它对应的本地头。
//
// 为什么不用 Expand-Archive 或 unzip：本工程的自检脚本要求跨平台单实现（AGENTS.md），
// 而 PowerShell 与 macOS 的解压命令不同，还会写出多余的中文目录名。

function unzip(buffer) {
  // 末尾的中央目录结束记录（EOCD）长度固定 22 字节，但注释长度可变，所以从尾部往前找签名。
  let eocd = -1;
  for (let i = buffer.length - 22; i >= 0 && i > buffer.length - 22 - 65536; i--) {
    if (buffer.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("不是有效的 ZIP：找不到中央目录");
  const count = buffer.readUInt16LE(eocd + 10);
  let offset = buffer.readUInt32LE(eocd + 16);

  const entries = [];
  for (let i = 0; i < count; i++) {
    if (buffer.readUInt32LE(offset) !== 0x02014b50) throw new Error("中央目录条目签名不符");
    const method = buffer.readUInt16LE(offset + 10);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer.toString("utf8", offset + 46, offset + 46 + nameLength);
    entries.push({ name, method, compressedSize, localOffset });
    offset += 46 + nameLength + extraLength + commentLength;
  }

  for (const entry of entries) {
    const at = entry.localOffset;
    if (buffer.readUInt32LE(at) !== 0x04034b50) throw new Error(`本地头签名不符：${entry.name}`);
    // 本地头里的文件名与扩展区长度可能与中央目录不同，必须按本地头的值算数据起点。
    const nameLength = buffer.readUInt16LE(at + 26);
    const extraLength = buffer.readUInt16LE(at + 28);
    const start = at + 30 + nameLength + extraLength;
    const raw = buffer.subarray(start, start + entry.compressedSize);
    if (entry.method === 0) {
      entry.data = Buffer.from(raw);
    } else if (entry.method === 8) {
      entry.data = zlib.inflateRawSync(raw);
    } else {
      throw new Error(`不支持的压缩方式 ${entry.method}：${entry.name}`);
    }
  }
  return entries;
}

// ---------------------------------------------------------------- 表面贴图

async function fetchSurface(asset, opts) {
  const dir = path.join(TEXTURE_DIR, asset.id);
  if (fs.existsSync(dir) && !opts.force) {
    process.stdout.write(`  跳过 ${asset.id}（已存在，用 --force 重新下载）\n`);
    return;
  }
  const url = `https://ambientCG.com/get?file=${asset.id}_${ATTRIBUTE}.zip`;
  process.stdout.write(`  下载 ${asset.id}（${asset.use}）…\n`);
  const entries = unzip(await download(url));

  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const kept = [];
  for (const entry of entries) {
    // 只按后缀匹配：包内的文件名前缀随素材变化，且可能带尺寸后缀与变体标记。
    const hit = /_([A-Za-z]+)\.(jpg|jpeg|png)$/i.exec(entry.name);
    if (!hit) continue;
    if (!asset.maps.includes(hit[1])) continue;
    // 统一成小写短名，供材质侧按固定名字查找，不受素材包命名变化影响。
    const target = path.join(dir, `${hit[1].toLowerCase()}.${hit[2].toLowerCase()}`);
    fs.writeFileSync(target, entry.data);
    kept.push(hit[1]);
  }
  if (kept.length === 0) {
    fs.rmSync(dir, { recursive: true, force: true });
    throw new Error(`${asset.id} 里没有找到需要的贴图；包内条目：` +
      entries.map((e) => e.name).join(", "));
  }
  // 缺哪几张要说出来，否则「这套材质没有金属度」这件事只会在画面上表现成"某处看起来不对"。
  const missing = asset.maps.filter((m) => !kept.includes(m));
  process.stdout.write(`    保留 ${kept.length} 张：${kept.join("/")}` +
    (missing.length ? `；该素材未提供：${missing.join("/")}\n` : "\n"));
}

// ---------------------------------------------------------------- 环境贴图

async function fetchHdri(asset, opts) {
  const target = path.join(HDRI_DIR, `${asset.id}_1k.hdr`);
  if (fs.existsSync(target) && !opts.force) {
    process.stdout.write(`  跳过 ${asset.id}（已存在，用 --force 重新下载）\n`);
    return;
  }
  const files = await (await fetch(`https://api.polyhaven.com/files/${asset.id}`)).json();
  const entry = files.hdri?.["1k"]?.hdr;
  if (!entry) throw new Error(`${asset.id} 没有 1k hdr 文件`);
  process.stdout.write(`  下载 ${asset.id}（${asset.use}，${(entry.size / 1024 / 1024).toFixed(1)} MiB）…\n`);
  fs.mkdirSync(HDRI_DIR, { recursive: true });
  fs.writeFileSync(target, await download(entry.url));
}

// ---------------------------------------------------------------- 入口

const opts = parseArgs(process.argv.slice(2));
const wantSurface = (id) => !opts.only || opts.only === id;
const wantHdri = (id) => !opts.only || opts.only === id;

if (opts.list) {
  process.stdout.write("表面贴图（ambientCG，CC0）：\n");
  for (const a of SURFACES) process.stdout.write(`  ${a.id}\n     ${a.use}\n`);
  process.stdout.write("环境贴图（Poly Haven，CC0）：\n");
  for (const a of HDRIS) process.stdout.write(`  ${a.id}\n     ${a.use}\n`);
} else if (opts.try) {
  await fetchSurface({ id: opts.try, maps: ["Color", "NormalGL", "Roughness", "Metalness"] }, opts);
  process.stdout.write("\n这是试素材，量完颜色后若不用它，记得删掉 assets/textures/ 下那一目录。\n");
} else {
  for (const asset of SURFACES) {
    if (wantSurface(asset.id)) await fetchSurface(asset, opts);
  }
  for (const asset of HDRIS) {
    if (wantHdri(asset.id)) await fetchHdri(asset, opts);
  }
  process.stdout.write("\n素材下载完成。\n");
  process.stdout.write("注意：新增或替换素材后要执行一次 --import，让引擎建立导入产物。\n");
}
