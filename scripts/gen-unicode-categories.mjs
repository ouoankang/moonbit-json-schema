// 生成 src/regex/unicode_categories.mbt —— Unicode 一般类别的区间表。
//
// 为什么要生成：`\p{Letter}` 这类写法需要知道「哪些码点属于哪个一般类别」。
// ECMAScript 把这份数据藏在引擎里，但语言本身不暴露；MoonBit 的核心库也没有。
// 所以这里借 Node 的 `\p{...}` 支持把官方数据抽出来，压成区间表，变成纯数据
// 编进项目——运行时零依赖，也不需要联网。
//
// 做法：
//   1. 把 30 个一般类别拼成一个带命名组的正则；
//   2. 逐个码点（0 .. 0x10FFFF）问它属于哪一类；
//   3. 把相邻同类码点压成 [lo, hi, cat] 区间。
// 一般类别本身是对码点空间的一个划分，所以每个码点恰好命中一个分支。
//
// 用法: node scripts/gen-unicode-categories.mjs [输出路径]

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const projectRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

// 30 个一般类别。顺序无关紧要——划分保证唯一命中。
const CATS = [
  "Lu", "Ll", "Lt", "Lm", "Lo",
  "Mn", "Mc", "Me",
  "Nd", "Nl", "No",
  "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
  "Sm", "Sc", "Sk", "So",
  "Zs", "Zl", "Zp",
  "Cc", "Cf", "Cs", "Co", "Cn",
];

const MAX_CP = 0x10ffff;

const combined = new RegExp(
  CATS.map((c) => `(?<g_${c}>\\p{${c}})`).join("|"),
  "u",
);

const runs = [];
let prevCat = -1;
let runStart = 0;
let unmatched = 0;

for (let cp = 0; cp <= MAX_CP; cp++) {
  const m = combined.exec(String.fromCodePoint(cp));
  let cat = -1;
  if (m) {
    for (let i = 0; i < CATS.length; i++) {
      if (m.groups["g_" + CATS[i]] !== undefined) { cat = i; break; }
    }
  }
  if (cat === -1) {
    unmatched++;
    cat = CATS.indexOf("Cn"); // 兜底归到「未分配」
  }
  if (cat !== prevCat) {
    if (prevCat !== -1) runs.push([runStart, cp - 1, prevCat]);
    runStart = cp;
    prevCat = cat;
  }
}
runs.push([runStart, MAX_CP, prevCat]);

// 覆盖率自检：区间必须无缝覆盖整个码点空间。
let covered = 0;
for (let i = 0; i < runs.length; i++) {
  covered += runs[i][1] - runs[i][0] + 1;
  if (i > 0 && runs[i][0] !== runs[i - 1][1] + 1) {
    throw new Error("区间不连续 @ " + i);
  }
}
if (covered !== MAX_CP + 1) {
  throw new Error("覆盖不全: " + covered + " != " + (MAX_CP + 1));
}

const hex = (n) => "0x" + n.toString(16).toUpperCase();

const lines = [];
lines.push("// 本文件由 scripts/gen-unicode-categories.mjs 自动生成，请勿手工编辑。");
lines.push("//");
lines.push("// Unicode 一般类别（General_Category）的区间表。数据源是宿主运行时");
lines.push("// 的 `\\p{...}` 实现，抽取后压成区间，覆盖 U+0000..U+10FFFF 且无缝无重叠。");
lines.push("//");
lines.push("// 用法：对码点做一次二分查找拿到类别下标，再判断该下标是否属于目标属性。");
lines.push("// 我们不是为每个属性各存一份区间，而是存「划分」本身——属性只记下它包含");
lines.push("// 哪些类别下标。这样数据量只有一份，加新属性也不用重新生成。");
lines.push("");
lines.push("///|");
lines.push("/// 一般类别的名字，下标与 `unicode_runs` 里第三项一致。");
lines.push("let unicode_category_names : Array[String] = [");
for (let i = 0; i < CATS.length; i++) {
  lines.push(`  "${CATS[i]}",`);
}
lines.push("]");
lines.push("");
lines.push("///|");
lines.push("/// 类别常量下标，便于按名字引用（避免在代码里写魔数）。");
for (let i = 0; i < CATS.length; i++) {
  lines.push(`let cat_${CATS[i]} : Int = ${i}`);
}
lines.push("");
lines.push("///|");
lines.push(`/// 区间表：\`(起始码点, 结束码点, 类别下标)\`，${runs.length} 条，已按起始码点升序。`);
lines.push("let unicode_runs : Array[(Int, Int, Int)] = [");
for (const [lo, hi, cat] of runs) {
  lines.push(`  (${hex(lo)}, ${hex(hi)}, ${cat}),`);
}
lines.push("]");
lines.push("");

const outPath = process.argv[2] ||
  "src/regex/unicode_categories.mbt";
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, lines.join("\n"), "utf8");

console.log("runs=" + runs.length + "  unmatched=" + unmatched + "  bytes=" + fs.statSync(outPath).size);

// 再跑一次格式化器，只针对刚写出的这个文件。
//
// 生成器是机械拼字符串的，拼出来的排版不一定符合 moon fmt 的规则。
// 不统一的话会陷入「手动 `moon fmt` 改动它 → 重新生成又改回来」的
// 来回漂移，CI 里「重新生成后工作区是否干净」这条检查就永远有噪音。
//
// 只传这一个文件路径，避免顺手格式化掉别人未提交的改动。
execFileSync("moon", ["fmt", outPath], { cwd: projectRoot, stdio: "inherit" });
