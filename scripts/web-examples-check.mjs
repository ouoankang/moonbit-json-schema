// 校验演示页里的示例数据是否仍然和实现的行为一致。
//
// 为什么需要这个：演示页最容易犯的错不是「报错」，而是「演一个不存在的功能」。
// 示例的期望值一旦和实现脱节，页面照样能打开、照样显示结果，只是显示的是
// 错的结论 —— 而这种错误肉眼看不出来，必须靠断言。
//
// 用法：
//   moon build --target js --release
//   node scripts/web-examples-check.mjs

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const bundle = resolve(root, "_build/js/release/build/cmd/web/web.js");
const examplesPath = resolve(root, "web/examples.js");

// 加载 MoonBit 产物（IIFE，靠 main() 把 API 挂到 globalThis 上）。
(0, eval)(readFileSync(bundle, "utf8"));

// 加载示例数据（同样是自执行脚本，挂到 globalThis 上）。
(0, eval)(readFileSync(examplesPath, "utf8"));

const api = globalThis.MoonbitJsonSchema;
const examples = globalThis.JSON_SCHEMA_DEMO_EXAMPLES;

if (!api) {
  console.error("没有挂载 MoonbitJsonSchema，先执行 moon build --target js --release");
  process.exit(2);
}
if (!Array.isArray(examples) || examples.length === 0) {
  console.error(`没有从 ${examplesPath} 读到示例数据`);
  process.exit(2);
}

let failures = 0;

console.log("演示页示例校验");
console.log("");

for (const [i, ex] of examples.entries()) {
  const exp = ex.expect;
  const label = `${String(i).padStart(2)}. ${ex.name}`;

  if (!exp || !exp.action) {
    failures += 1;
    console.log(`  FAIL  ${label}`);
    console.log("        示例缺少 expect.action，无法判断它是为了演示什么");
    continue;
  }

  let data;
  try {
    const raw =
      exp.action === "lint"
        ? api.lint(JSON.stringify(ex.schema))
        : api.validate(JSON.stringify(ex.schema), JSON.stringify(ex.instance));
    data = JSON.parse(raw);
  } catch (e) {
    failures += 1;
    console.log(`  FAIL  ${label}`);
    console.log(`        调用抛异常或响应不可解析: ${e.message}`);
    continue;
  }

  const problems = [];

  if (data.status !== exp.status) {
    problems.push(`status 期望 ${exp.status}，实际 ${data.status}`);
  }

  if (typeof exp.count === "number" && data.count !== exp.count) {
    problems.push(`count 期望 ${exp.count}，实际 ${data.count}`);
  }

  // status 为 ok 时错误数必然是 0，这里顺手钉一下，防止实现漏报又漏计。
  if (expectedOk(exp) && data.count !== 0) {
    problems.push(`status=ok 但 count=${data.count}`);
  }

  if (exp.instancePath !== undefined) {
    const paths = (data.errors || []).map((e) => e.instancePath);
    if (!paths.includes(exp.instancePath)) {
      problems.push(`期望错误位置含 ${exp.instancePath}，实际 ${JSON.stringify(paths)}`);
    }
  }

  if (exp.keyword !== undefined) {
    const kws = (data.errors || []).map((e) => e.keyword);
    if (!kws.includes(exp.keyword)) {
      problems.push(`期望关键字 ${exp.keyword}，实际 ${JSON.stringify(kws)}`);
    }
  }

  // 每条错误都必须带齐四个字段，缺一个页面上就会显示成空白单元格。
  for (const e of data.errors || []) {
    for (const f of ["instancePath", "keyword", "schemaPath", "message"]) {
      if (typeof e[f] !== "string") {
        problems.push(`错误项缺少字段 ${f}`);
      }
    }
  }

  if (problems.length === 0) {
    console.log(`  ok    ${label}`);
    console.log(`        ${exp.action} → ${data.status}${typeof exp.count === "number" ? ` (${data.count} 处)` : ""}`);
  } else {
    failures += 1;
    console.log(`  FAIL  ${label}`);
    for (const p of problems) {
      console.log(`        ${p}`);
    }
  }
}

function expectedOk(exp) {
  return exp.status === "ok";
}

console.log("");
if (failures === 0) {
  console.log(`${examples.length} 条示例全部与实现行为一致。`);
  process.exit(0);
} else {
  console.log(`${failures} / ${examples.length} 条示例与实现行为不一致。`);
  process.exit(1);
}
