// 构建浏览器产物：编译 MoonBit → 拷贝到 web/vendor/。
//
// 为什么要把产物拷进 web/：网页要能在 file:// 下直接打开，也要能被当成
// 纯静态目录托管。让页面去引用 _build/ 里的东西会把构建目录变成公开协议
// 的一部分，路径一变页面就白屏。
//
// 用法：node scripts/build-web.mjs

import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const built = resolve(root, "_build/js/release/build/cmd/web/web.js");
const outDir = resolve(root, "web/vendor");
const target = resolve(outDir, "moonbit-regex.js");

console.log("编译 cmd/web（目标 js, release）...");
execFileSync("moon", ["build", "--target", "js", "--release"], {
  cwd: root,
  stdio: "inherit",
});

mkdirSync(outDir, { recursive: true });
copyFileSync(built, target);

const kb = (statSync(target).size / 1024).toFixed(0);
console.log(`已复制 ${kb} KB → web/vendor/moonbit-regex.js`);
console.log("");
console.log("接下来可以：");
console.log("  node scripts/web-smoke.mjs      # 确认接口挂载正确");
console.log("  直接打开 web/index.html          # 本地看效果");
