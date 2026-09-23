#!/usr/bin/env node
// 列出候选素材：ambientCG 的表面贴图与 Poly Haven 的环境贴图。
// 只做筛选与打印，不做下载——先把清单看准，再决定下载哪几个。
//
// 两个站点都是 CC0，可商用、无需署名（仍会登记到 THIRD_PARTY.md）。
//
//   node tools/probe-assets.mjs

const SURFACE_KEYWORDS = /^(Metal|MetalPlates|PaintedMetal|MetalFloor|Concrete|Rubber|Panels|CorrugatedSteel)/;
const HDRI_KEYWORDS = /(factory|industrial|warehouse|hangar|bunker|night|studio|workshop|courtyard|garage)/i;

async function listSurfaces() {
  process.stdout.write("\n=== ambientCG 候选表面贴图（1K-JPG）===\n");
  const res = await fetch("https://ambientcg.com/api/v2/downloads_csv?type=Material");
  const lines = (await res.text()).split(/\r?\n/).slice(1);
  // CSV 每行是一个「素材 + 规格」组合，按 assetId 归并后只留 1K-JPG 的体积。
  const sizes = new Map();
  for (const line of lines) {
    const cells = line.split(",");
    if (cells.length < 4) continue;
    const [id, attribute, filetype, size] = cells;
    if (attribute !== "1K-JPG" || filetype !== "zip") continue;
    if (!SURFACE_KEYWORDS.test(id)) continue;
    sizes.set(id, Number(size));
  }
  const rows = [...sizes.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  process.stdout.write(`共 ${rows.length} 个候选。\n`);
  for (const [id, size] of rows) {
    process.stdout.write(`  ${id.padEnd(26)} ${(size / 1024 / 1024).toFixed(1)} MiB\n`);
  }
}

async function listHdris() {
  process.stdout.write("\n=== Poly Haven 候选环境贴图（1k HDR 体积）===\n");
  const res = await fetch("https://api.polyhaven.com/assets?t=hdris");
  const assets = await res.json();
  const names = Object.keys(assets).filter((n) => HDRI_KEYWORDS.test(n));
  process.stdout.write(`共 ${names.length} 个候选，逐个取体积较慢，下面只列前 24 个。\n`);
  for (const name of names.slice(0, 24)) {
    const files = await (await fetch(`https://api.polyhaven.com/files/${name}`)).json();
    const entry = files.hdri?.["1k"]?.hdr;
    const size = entry ? `${(entry.size / 1024 / 1024).toFixed(1)} MiB` : "—";
    process.stdout.write(`  ${name.padEnd(30)} ${size}\n`);
  }
}

await listSurfaces();
await listHdris();
