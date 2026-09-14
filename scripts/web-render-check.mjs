// 用 jsdom 真正执行一遍 app.js，检查页面渲染结果。
//
// 为什么需要它（两个轻量检查各自漏掉什么）：
//   * scripts/web-smoke.mjs 只测 MoonBit 产物本身，碰不到 DOM；
//   * scripts/web-wiring-check.mjs 只做静态交叉核对，证明不了「按下去会有反应」。
// 这个文件补上中间那段：真的建一个 DOM、真的加载三个脚本、真的点按钮，
// 然后检查页面上的字变了没有。
//
// jsdom 是可选依赖，没装就直接跳过（退出码 0），不阻塞 CI：
//   npm install jsdom
// 若装在别处，用环境变量指明从哪解析：
//   JSDOM_FROM=/path/to/node_modules/ node scripts/web-render-check.mjs

import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const vendor = resolve(root, "web/vendor/moonbit-regex.js");
if (!existsSync(vendor)) {
  console.error("缺少 web/vendor/moonbit-regex.js");
  console.error("请先执行：node scripts/build-web.mjs");
  process.exit(2);
}

function loadJsdom() {
  const bases = [import.meta.url];
  if (process.env.JSDOM_FROM) {
    bases.push(resolve(process.env.JSDOM_FROM));
  }
  for (const base of bases) {
    try {
      return createRequire(base)("jsdom");
    } catch {
      // 换下一个候选位置
    }
  }
  return null;
}

const jsdom = loadJsdom();
if (!jsdom) {
  console.log("未安装 jsdom，跳过页面渲染验证。");
  console.log("如需运行：npm install jsdom（或设置 JSDOM_FROM 指向已安装的位置）");
  process.exit(0);
}
const { JSDOM } = jsdom;
const pageUrl = pathToFileURL(resolve(root, "web/index.html")).href;

let failures = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  ok    ${name}`);
  } else {
    failures += 1;
    console.log(`  FAIL  ${name}${detail !== undefined ? `  → ${detail}` : ""}`);
  }
}

const errors = [];
const dom = await JSDOM.fromFile(resolve(root, "web/index.html"), {
  runScripts: "dangerously",
  resources: "usable",
  pretendToBeVisual: true,
  url: pageUrl,
});

dom.virtualConsole.on("jsdomError", (e) => errors.push(String(e.message)));
dom.window.addEventListener("error", (e) => errors.push(String(e.message)));

// 等脚本加载 + 初始化跑完
await new Promise((r) => setTimeout(r, 2500));

const doc = dom.window.document;
const $ = (id) => doc.getElementById(id);

console.log("页面渲染验证");
console.log("");

console.log("== 启动状态 ==");
check("没有脚本报错", errors.length === 0, errors.slice(0, 3).join(" | "));
check(
  "MoonBit API 已挂载到 window",
  typeof dom.window.MoonbitRegex === "object" && dom.window.MoonbitRegex !== null,
);
check("示例下拉有 7 项", $("example-select").options.length === 7, $("example-select").options.length);
check(
  "内置元 schema 列表渲染了 9 行",
  $("meta-list").children.length === 9,
  $("meta-list").children.length,
);
check(
  "页脚统计提到了 9 份",
  $("foot-stat").textContent.includes("9 份"),
  $("foot-stat").textContent,
);
check("schema 文本框已填入内容", $("schema").value.length > 100, $("schema").value.length);
check("实例文本框已填入内容", $("instance").value.length > 50, $("instance").value.length);

try {
  JSON.parse($("schema").value);
  check("默认 schema 是合法 JSON", true);
} catch (e) {
  check("默认 schema 是合法 JSON", false, e.message);
}

console.log("");
console.log("== 默认示例（第 1 条，应当通过）==");
check(
  "判定为「校验通过」",
  $("verdict").textContent === "校验通过",
  $("verdict").textContent,
);
check("verdict 带 ok 样式", $("verdict").className.includes("ok"), $("verdict").className);
check("耗时已显示", /\d/.test($("timing").textContent), $("timing").textContent);
check("没有错误表格", $("table-slot").querySelector("table") === null);

console.log("");
console.log("== 切到第 2 条示例（应当不通过，7 处）==");
$("example-select").value = "1";
$("example-select").dispatchEvent(new dom.window.Event("change"));
await new Promise((r) => setTimeout(r, 200));

check(
  "判定为「校验不通过 · 7 处」",
  $("verdict").textContent === "校验不通过 · 7 处",
  $("verdict").textContent,
);
check("verdict 带 bad 样式", $("verdict").className.includes("bad"), $("verdict").className);
const rows = $("table-slot").querySelectorAll("tbody tr");
check("错误表格有 7 行", rows.length === 7, rows.length);
if (rows.length > 0) {
  const cells = rows[0].querySelectorAll("td");
  check("每行 4 列", cells.length === 4, cells.length);
  check(
    "第 1 列是实例位置",
    cells[0].textContent.length > 0,
    cells[0].textContent,
  );
  check(
    "第 2 列关键字非空且不像乱码",
    cells[1].textContent.length > 0 && !/^\d+$/.test(cells[1].textContent),
    cells[1].textContent,
  );
  check(
    "第 4 列是 schema 位置（以 / 开头）",
    cells[3].textContent.startsWith("/"),
    cells[3].textContent,
  );
}

console.log("");
console.log("== 切到第 4 条示例（布尔 false 说明条）==");
$("example-select").value = "3";
$("example-select").dispatchEvent(new dom.window.Event("change"));
await new Promise((r) => setTimeout(r, 200));
check(
  "判定为「校验不通过 · 1 处」",
  $("verdict").textContent === "校验不通过 · 1 处",
  $("verdict").textContent,
);
check(
  "出现关于 false 的补充说明",
  $("table-slot").textContent.includes("布尔 schema false"),
  $("table-slot").textContent.slice(0, 120),
);

console.log("");
console.log("== 切到第 6 条示例（深层出错，检查路径）==");
$("example-select").value = "5";
$("example-select").dispatchEvent(new dom.window.Event("change"));
await new Promise((r) => setTimeout(r, 200));
check(
  "错误位置显示为 /children/1/children/0/name",
  $("table-slot").textContent.includes("/children/1/children/0/name"),
  $("table-slot").textContent.slice(0, 200),
);

console.log("");
console.log("== 手动按「用元 schema 检查」验证按钮 ==");
$("btn-validate").click();
await new Promise((r) => setTimeout(r, 200));
check(
  "对递归深层示例按 validate 仍是不通过",
  $("verdict").textContent.includes("校验不通过"),
  $("verdict").textContent,
);

console.log("");
console.log("== 空输入 / 非法 JSON 的处理 ==");
$("schema").value = "{ 这不是 JSON";
$("btn-validate").click();
await new Promise((r) => setTimeout(r, 200));
check(
  "非法 schema 报「输入无法解析」而不是「不通过」",
  $("verdict").textContent === "输入无法解析",
  $("verdict").textContent,
);
check(
  "verdict 带 error 样式",
  $("verdict").className.includes("error"),
  $("verdict").className,
);

console.log("");
console.log("== 清空按钮 ==");
$("btn-clear").click();
await new Promise((r) => setTimeout(r, 100));
check("清空后 schema 为空", $("schema").value === "");
check("清空后回到「尚未校验」", $("verdict").textContent === "尚未校验", $("verdict").textContent);

console.log("");
dom.window.close();

if (failures === 0) {
  console.log("页面渲染验证全部通过。");
  process.exit(0);
} else {
  console.log(`页面渲染验证失败：${failures} 项。`);
  process.exit(1);
}
