// 让 README.mbt.md 与 README.md 保持一致。
//
// 为什么需要它：GitHub 默认展示 README.md，而 mooncakes.io 展示的是
// moon.mod 里 `readme` 字段指定的文件（本仓库是 README.mbt.md）。两份内容
// 一旦手工维护就必然漂移，所以由脚本从 README.md 复制一份。
//
// 用法：node scripts/sync-readme.mjs
//
// `moon check` 不在这个链路上，所以提交前记得跑一次；.githooks/pre-commit
// 也调用了它。

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const src = join(root, "README.md");
const dst = join(root, "README.mbt.md");

const banner =
  "<!-- 本文件由 scripts/sync-readme.mjs 从 README.md 复制生成，请勿直接编辑。 -->\n\n";

const body = readFileSync(src, "utf8");
writeFileSync(dst, banner + body);
console.log(`synced README.md -> README.mbt.md (${body.length} bytes)`);
