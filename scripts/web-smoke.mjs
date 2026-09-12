// 冒烟测试：确认构建产物真的把 API 挂到了 globalThis 上，并且结论正确。
//
// 这一步不能省。MoonBit 的 JS 后端会把整个模块内联成一个 IIFE，任何一处
// FFI 改动（比如回调没传进去、main 没被调用）都会让网页在浏览器里静默拿到
// `undefined`，而 `moon test` 完全覆盖不到这一层——它跑的是 wasm 上的库代码。
// 也就是说：库测试全绿，页面仍然可能是坏的。这个文件就是补这个缺口。
//
// 用法：
//   moon build --target js --release
//   node scripts/web-smoke.mjs

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bundle = resolve(root, "_build/js/release/build/cmd/web/web.js");

let failures = 0;

function check(name, condition, detail) {
  if (condition) {
    console.log(`  ok    ${name}`);
  } else {
    failures += 1;
    console.log(`  FAIL  ${name}`);
    if (detail !== undefined) {
      console.log(`        ${detail}`);
    }
  }
}

function read(rel) {
  return readFileSync(resolve(root, rel), "utf8");
}

// ---------------------------------------------------------------------------
// 加载产物
// ---------------------------------------------------------------------------

let code;
try {
  code = readFileSync(bundle, "utf8");
} catch (e) {
  console.error(`读不到构建产物：${bundle}`);
  console.error("请先执行 moon build --target js --release");
  process.exit(2);
}

// 用间接 eval 在全局作用域执行：产物是 IIFE 而非 ES 模块，
// 它靠调用 main() 把 API 挂到 globalThis 上。
(0, eval)(code);

const api = globalThis.MoonbitJsonSchema;

console.log("web 入口冒烟测试");
console.log(`  产物: ${bundle}`);
console.log(`  体积: ${(code.length / 1024).toFixed(0)} KB`);
console.log("");

// ---------------------------------------------------------------------------
// 接口形状
// ---------------------------------------------------------------------------

console.log("== 接口 ==");
check("globalThis.MoonbitJsonSchema 存在", api !== undefined && api !== null);
if (api === undefined || api === null) {
  console.log("");
  console.log("API 未挂载，后续用例无法执行。");
  process.exit(1);
}
check("validate 是函数", typeof api.validate === "function", typeof api.validate);
check("lint 是函数", typeof api.lint === "function", typeof api.lint);
check("metaschemaList 是函数", typeof api.metaschemaList === "function", typeof api.metaschemaList);

/** 解析响应，顺便断言它是合法 JSON —— 拼 JSON 出错会当场暴露。 */
function call(fn, ...args) {
  const raw = fn(...args);
  try {
    return JSON.parse(raw);
  } catch (e) {
    console.log(`        原始响应: ${String(raw).slice(0, 200)}`);
    throw new Error(`响应不是合法 JSON: ${e.message}`);
  }
}

// ---------------------------------------------------------------------------
// validate
// ---------------------------------------------------------------------------

console.log("");
console.log("== validate ==");

const schema = read("examples/person.schema.json");
const okInstance = read("examples/person.ok.json");
const badInstance = read("examples/person.bad.json");

const ok = call(api.validate, schema, okInstance);
check("合法实例判定为 ok", ok.status === "ok", JSON.stringify(ok).slice(0, 200));
check("合法实例错误数为 0", ok.count === 0, `count=${ok.count}`);
check("错误列表是数组", Array.isArray(ok.errors));

const bad = call(api.validate, schema, badInstance);
check("非法实例判定为 invalid", bad.status === "invalid", JSON.stringify(bad).slice(0, 200));
check("非法实例报出 7 处错误", bad.count === 7, `count=${bad.count}`);
check(
  "每条错误都带 instancePath / keyword / message",
  bad.errors.every(
    (e) =>
      typeof e.instancePath === "string" &&
      typeof e.keyword === "string" &&
      typeof e.message === "string" &&
      typeof e.schemaPath === "string",
  ),
);

// 转义：属性名里带引号和换行时，响应必须仍是合法 JSON。
const nasty = call(
  api.validate,
  '{"properties":{"a\\"b\\nc":{"type":"integer"}}}',
  '{"a\\"b\\nc":"not an int"}',
);
check("属性名含引号/换行时响应仍是合法 JSON", nasty.status === "invalid", JSON.stringify(nasty).slice(0, 200));

// 输入不是合法 JSON —— 必须报成 error，而不是伪装成「校验不通过」。
const brokenJson = call(api.validate, "{ not json", okInstance);
check("schema 语法错误报 status=error", brokenJson.status === "error", brokenJson.message);
check("schema 语法错误的提示可读", typeof brokenJson.message === "string" && brokenJson.message.length > 0);

const brokenInstance = call(api.validate, schema, "{{{");
check("实例语法错误报 status=error", brokenInstance.status === "error", brokenInstance.message);

// ---------------------------------------------------------------------------
// lint
// ---------------------------------------------------------------------------

console.log("");
console.log("== lint（用官方元 schema 检查 schema 自身）==");

const goodLint = call(api.lint, schema);
check("person.schema.json 通过元 schema 检查", goodLint.status === "ok", JSON.stringify(goodLint).slice(0, 200));

const badLint = call(api.lint, read("examples/broken.schema.json"));
check("broken.schema.json 被判定为不符合元 schema", badLint.status === "invalid", JSON.stringify(badLint).slice(0, 200));
check("broken.schema.json 报出 4 处问题", badLint.count === 4, `count=${badLint.count}`);

// 元 schema 的关键价值：schema 自身写错时，validate 给出的结论会误导人。
//
// `{"type":"sting"}` 这个笔误下，validate 只会说「实例不符合期望的类型」，
// 完全不提示「你的 schema 拼错了」——使用者会去查自己的数据，方向全错。
// 只有 lint 才指得出真正的问题在 `/type` 这个位置。
const typo = '{"type":"sting"}';
const typoValidate = call(api.validate, typo, '"hello"');
check(
  "validate 对 type 笔误只给实例层面的结论（不指出 schema 写错）",
  typoValidate.status === "invalid",
  JSON.stringify(typoValidate).slice(0, 200),
);
const typoLint = call(api.lint, typo);
check("lint 把问题定位到 schema 的 /type 位置", typoLint.status === "invalid");
check(
  "lint 与 validate 报告的出错位置不同（前者在 schema，后者在实例）",
  typoLint.errors[0]?.instancePath.startsWith("/") === true &&
    typoValidate.errors[0]?.instancePath === "",
  `lint=${typoLint.errors[0]?.instancePath} validate=${typoValidate.errors[0]?.instancePath}`,
);

// ---------------------------------------------------------------------------
// metaschemaList
// ---------------------------------------------------------------------------

console.log("");
console.log("== metaschemaList ==");

const list = call(api.metaschemaList);
check("status 为 ok", list.status === "ok");
check("内置 9 份官方元 schema", list.count === 9, `count=${list.count}`);
check(
  "每项都有 uri 和 chars",
  Array.isArray(list.items) &&
    list.items.every((it) => typeof it.uri === "string" && it.uri.startsWith("https://json-schema.org/draft/2020-12/")),
);
check(
  "包含根元 schema /schema",
  list.items.some((it) => it.uri === "https://json-schema.org/draft/2020-12/schema"),
);

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

console.log("");
if (failures === 0) {
  console.log("web 入口冒烟测试全部通过。");
  process.exit(0);
} else {
  console.log(`web 入口冒烟测试失败：${failures} 项。`);
  process.exit(1);
}
