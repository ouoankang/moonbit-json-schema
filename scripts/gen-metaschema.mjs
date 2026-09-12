// 把 src/metaschema/raw/*.json 转成 MoonBit 源码。
//
// 为什么要做这一步：库本体要能在 wasm 上跑，而 wasm 没有文件系统，
// 不能「运行时去读 JSON 文件」。元 schema 必须在编译期就变成字面量。
//
// 为什么不直接把 JSON 内联成一个大字符串：为了让生成物可读、可 diff。
// 每个 JSON 行对应一个 MoonBit 字符串字面量，改动一眼能看出来。
//
// 用法：node scripts/gen-metaschema.mjs
//
// 数据来源是 https://json-schema.org/draft/2020-12/ 下的官方文档，
// 抓取命令见 src/metaschema/raw/README.md。

import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const rawDir = join(root, "src", "metaschema", "raw");
const outFile = join(root, "src", "metaschema", "meta_docs.mbt");

// 生成顺序固定（而不是按目录枚举顺序），这样重跑生成器不会产生无意义的 diff。
// 根文档排在最前：它是 `$vocabulary` 的来源，也是 `$ref` 的落点。
const ORDER = [
  ["schema.json", "schema"],
  ["meta_core.json", "core"],
  ["meta_applicator.json", "applicator"],
  ["meta_validation.json", "validation"],
  ["meta_unevaluated.json", "unevaluated"],
  ["meta_meta-data.json", "meta_data"],
  ["meta_format-annotation.json", "format_annotation"],
  ["meta_format-assertion.json", "format_assertion"],
  ["meta_content.json", "content"],
];

/**
 * 把一个 JSON 文档的文本转成 MoonBit 字符串字面量数组（一行一个）。
 * 转义只处理 `\` 和 `"`；raw/ 里的文档保证是纯 ASCII，所以不需要处理
 * 非 ASCII 与制表符。生成时会断言这一点。
 */
function toLineLiterals(text) {
  const nonAscii = [...text].filter((c) => c.charCodeAt(0) > 0x7e);
  if (nonAscii.length > 0) {
    throw new Error(`expected pure ASCII, found: ${JSON.stringify(nonAscii.slice(0, 8))}`);
  }
  const lines = text.replace(/\r\n/g, "\n").replace(/\n+$/, "").split("\n");
  return lines.map((l) => "    " + JSON.stringify(l).replace(/\\u([0-9a-fA-F]{4})/g, (m) => m));
}

const docs = [];
for (const [file, ident] of ORDER) {
  const text = readFileSync(join(rawDir, file), "utf8");
  const parsed = JSON.parse(text);
  if (!parsed.$id) throw new Error(`${file} has no $id`);
  docs.push({ file, ident, uri: parsed.$id, lines: toLineLiterals(text) });
}

// 同一个 URI 出现两次会让资源登记互相覆盖，这里直接拦下来。
const seen = new Set();
for (const d of docs) {
  if (seen.has(d.uri)) throw new Error(`duplicate $id: ${d.uri}`);
  seen.add(d.uri);
}

let out = "";
out += "// 本文件由 scripts/gen-metaschema.mjs 自动生成，请勿手工编辑。\n";
out += "//\n";
out += "// 内容是 JSON Schema draft 2020-12 的官方元 schema 系列文档，\n";
out += "// 原始文件保存在 src/metaschema/raw/（纯文本、原样下载，便于比对上游）。\n";
out += "//\n";
out += "// 为什么要把它们编进库本体：\n";
out += "//   * 校验 `$schema` 指向官方元 schema 的文档（也就是「检查一份 schema\n";
out += "//     本身写对了没有」）需要它，而这是本库的主要用途之一；\n";
out += "//   * wasm 目标没有文件系统，运行时读不到外部文件，只能编译期内联。\n";
out += "\n";
out += "///|\n";
out += "/// 把若干行拼成一个字符串。生成器把每个 JSON 行输出成一个字面量，\n";
out += "/// 靠这个函数还原。\n";
out += "fn join_lines(lines : Array[String]) -> String {\n";
out += "  let buf = StringBuilder()\n";
out += "  let mut first = true\n";
out += "  for line in lines {\n";
out += "    if !first {\n";
out += "      buf.write_char('\\n')\n";
out += "    }\n";
out += "    first = false\n";
out += "    buf.write_string(line)\n";
out += "  }\n";
out += "  buf.to_string()\n";
out += "}\n";

for (const d of docs) {
  out += "\n///|\n";
  out += `/// \`${d.uri}\`（源自 raw/${d.file}）。\n`;
  out += `let meta_text_${d.ident} : String = join_lines([\n`;
  out += d.lines.join(",\n") + ",\n";
  out += "])\n";
}

out += "\n///|\n";
out += "/// 元 schema 文档的 `(绝对 URI, 原文)` 列表。顺序固定。\n";
out += "pub fn metaschema_texts() -> Array[(String, String)] {\n";
out += "  [\n";
for (const d of docs) {
  out += `    ("${d.uri}", meta_text_${d.ident}),\n`;
}
out += "  ]\n";
out += "}\n";

writeFileSync(outFile, out);
console.log(`wrote ${outFile} (${out.length} bytes, ${docs.length} documents)`);
