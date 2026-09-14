// 从 test262 的 S15.10.2.x 用例提取「模式 → 匹配结果」判定，
// 生成 JSON 数据集供 MoonBit 一致性测试台跑。
//
// 提取三类形态：
//   1. /pat/.test("input") + assert(!)__executed       => { expected: true/false }
//   2. /pat/.exec("input") + var __expected = [...]   => { captures: [...], index: N }
//   3. /pat/.exec("input") + 断言 null                 => { expected: false }
//
// 带 flags（u/i/m/s/g/y）的用例跳过（引擎不支持 flags，诚实排除）。
//
// 用 Node 直连 api.github.com（绕开坏代理）。原始文件缓存在 raw/。
// 用法：node scripts/gen-test262.mjs （需 GH_TOKEN）

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const TOKEN = process.env.GH_TOKEN;
const RAW_DIR = join(process.cwd(), "tests", "test262", "raw");
const OUT = join(process.cwd(), "tests", "test262", "data.json");
mkdirSync(RAW_DIR, { recursive: true });

const list = JSON.parse(readFileSync(join(process.cwd(), "tests", "test262", "_filelist.json"), "utf8"));
const API = "https://api.github.com/repos/tc39/test262/contents/test/built-ins/RegExp";

async function getRaw(name) {
  const res = await fetch(`${API}/${name}`, {
    headers: { Authorization: `token ${TOKEN}`, Accept: "application/vnd.github.raw", "User-Agent": "gen-test262" },
  });
  if (!res.ok) throw new Error(`${name}: ${res.status}`);
  return await res.text();
}

// 提取 /pattern/flags.method("input")
function extractExecLine(line) {
  const m = line.match(/=\s*\/((?:\\.|[^/])*)\/([a-z]*)(\.test|\.exec)\(\s*"((?:\\.|[^"])*)"\s*\)/);
  if (!m) return null;
  return { pattern: m[1], input: m[4], method: m[3], flags: m[2] || "" };
}

function decode(str) {
  return str
    .replace(/\\n/g, "\n").replace(/\\t/g, "\t").replace(/\\r/g, "\r")
    .replace(/\\f/g, "\f").replace(/\\v/g, "\v").replace(/\\b/g, "\b")
    .replace(/\\0(?![0-9])/g, "\0")
    .replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/\\u\{([0-9a-fA-F]+)\}/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/\\"/g, '"').replace(/\\'/g, "'").replace(/\\\\/g, "\\");
}

// 提取 var __expected = ["a", undefined, ...]; 返回数组（字符串或 null）
function extractExpectedArray(src) {
  const line = src.split("\n").find((l) => l.includes("var __expected = ["));
  if (!line) return null;
  const m = line.match(/var __expected = \[(.*)\];/);
  if (!m) return null;
  const inner = m[1];
  if (inner.trim() === "") return [];
  // 按「顶层逗号」切分：字符串字面量里的逗号不切（这里的用例字符串无嵌套引号内逗号）
  const parts = inner.split(",").map((p) => p.trim());
  const arr = parts.map((p) => {
    if (p === "undefined") return null;
    // 去引号（单引号或双引号）+ 解码转义
    let s = p;
    if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
      s = s.slice(1, -1);
    }
    return decode(s);
  });
  return arr;
}

function extractIndex(src) {
  const m = src.match(/__expected\.index\s*=\s*(-?\d+)/);
  return m ? parseInt(m[1], 10) : 0;
}

// 判断 exec 是否「断言不匹配（null）」
function isExecNull(src) {
  return /__executed === null|sameValue\(\s*__executed,\s*null/.test(src);
}

const data = [];
let skipped = 0;

// 并发下载
const results = [];
for (let i = 0; i < list.length; i += 8) {
  const batch = list.slice(i, i + 8);
  const r = await Promise.all(batch.map(async (name) => {
    const p = join(RAW_DIR, name);
    let src;
    if (existsSync(p)) { src = readFileSync(p, "utf8"); }
    else { src = await getRaw(name); writeFileSync(p, src, "utf8"); }
    return { name, src };
  }));
  results.push(...r);
}

for (const { name, src } of results) {
  const el = src.split("\n").find((l) => l.includes("__executed = /"));
  if (!el) { skipped++; continue; }
  const ex = extractExecLine(el);
  if (!ex) { skipped++; continue; }
  if (ex.flags) { skipped++; continue; }

  const input = decode(ex.input);

  if (ex.method === ".test") {
    const neg = /assert\(!__executed/.test(src);
    data.push({ file: name, pattern: ex.pattern, input, expected: !neg, kind: "test" });
  } else {
    // .exec
    if (isExecNull(src)) {
      data.push({ file: name, pattern: ex.pattern, input, expected: false, kind: "exec" });
      continue;
    }
    const arr = extractExpectedArray(src);
    if (arr === null) { skipped++; continue; }
    const index = extractIndex(src);
    data.push({ file: name, pattern: ex.pattern, input, captures: arr, index, kind: "exec" });
  }
}

writeFileSync(OUT, JSON.stringify(data, null, 0), "utf8");
console.log(`提取完成: ${data.length} 条，跳过 ${skipped} 个`);
console.log(`  test: ${data.filter(d => d.kind === 'test').length}`);
console.log(`  exec: ${data.filter(d => d.kind === 'exec').length}`);
