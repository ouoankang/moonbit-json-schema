// 静态交叉核对：app.js 引用的 DOM 元素是否都在 index.html 里定义，脚本路径是否都存在。
//
// 这是最便宜的一道网，但抓的正是最常见的错：改 HTML 时动了一个 id，
// 页面上某个按钮就再也不反应了，而浏览器控制台只在按下时才报错——
// 很可能没人按到那一个。
//
// 不需要任何依赖，可以在 CI 里跑。
//
// 用法：node scripts/web-wiring-check.mjs

import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const appPath = resolve(root, "web/app.js");
const htmlPath = resolve(root, "web/index.html");
const app = readFileSync(appPath, "utf8");
const html = readFileSync(htmlPath, "utf8");

let failures = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  ok    ${name}`);
  } else {
    failures += 1;
    console.log(`  FAIL  ${name}${detail !== undefined ? `  → ${detail}` : ""}`);
  }
}

console.log("页面接线检查");
console.log("");

// ---------------------------------------------------------------------------
// 1. getElementById 的 id 必须在 HTML 里存在
// ---------------------------------------------------------------------------

const used = [...app.matchAll(/getElementById\("([^"]+)"\)/g)].map((m) => m[1]);
const defined = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));

const missing = [...new Set(used)].filter((id) => !defined.has(id));
check(
  `app.js 引用的 ${new Set(used).size} 个 id 都在 index.html 里`,
  missing.length === 0,
  missing.join(", "),
);

// ---------------------------------------------------------------------------
// 2. HTML 引用的脚本文件必须存在
// ---------------------------------------------------------------------------

const scripts = [...html.matchAll(/<script src="([^"]+)"/g)].map((m) => m[1]);
check("index.html 至少引用了脚本", scripts.length > 0);

for (const src of scripts) {
  const file = resolve(root, "web", src);
  const ok = existsSync(file);
  check(
    `脚本 ${src} 存在${ok ? `（${Math.round(statSync(file).size / 1024)} KB）` : ""}`,
    ok,
  );
}

// ---------------------------------------------------------------------------
// 3. 脚本加载顺序：MoonBit 产物必须在 app.js 之前
// ---------------------------------------------------------------------------

const vendorIdx = scripts.findIndex((s) => s.includes("vendor/"));
const appIdx = scripts.findIndex((s) => s.endsWith("app.js"));
const examplesIdx = scripts.findIndex((s) => s.endsWith("examples.js"));

check("vendor 产物在 app.js 之前加载", vendorIdx !== -1 && vendorIdx < appIdx);
check("examples.js 在 app.js 之前加载", examplesIdx !== -1 && examplesIdx < appIdx);

// ---------------------------------------------------------------------------
// 4. 页面用传统 script，不用 ES module —— 这样 file:// 下双击就能打开
// ---------------------------------------------------------------------------

check(
  "没有使用 type=\"module\"（保持 file:// 可直接打开）",
  !/<script[^>]*type="module"/.test(html),
);

console.log("");
if (failures === 0) {
  console.log("页面接线检查全部通过。");
  process.exit(0);
} else {
  console.log(`页面接线检查失败：${failures} 项。`);
  process.exit(1);
}
