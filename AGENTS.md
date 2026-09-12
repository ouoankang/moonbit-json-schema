# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

---

## 本项目特有的约定

### 目标与后端

`moon.mod` 里 `preferred_target = "wasm"`，所以 `moon test` 默认在 **wasm**
上跑。**`src/` 下的库代码不允许依赖任何平台能力**——这是刻意的：
`pattern` 要按 ECMA-262 语义解释，而 wasm 上没有宿主正则，所以正则引擎是
自己写的（`src/regex/`）。

需要文件 IO 的只有 `cmd/` 下的两个可执行程序，它们走 js 后端：

```sh
moon run --target js cmd/main -- validate examples/person.schema.json examples/person.ok.json
moon run --target js cmd/conformance
```

两个程序都用 `#cfg(target="js")` / `#cfg(not(target="js"))` 成对提供 FFI，
非 js 后端给空实现——这样 `moon check` 在任何目标上都不会因为缺 FFI 失败。

### 改代码之后要跑的检查

```sh
moon check                                  # 类型检查
moon test                                   # 单元测试（wasm）
moon run --target js cmd/conformance        # 必测不全会让退出码非 0
```

一致性套件支持两个环境变量，定位单个特性时很有用：

```sh
JSTS_ONLY=dynamicRef JSTS_VERBOSE=1 moon run --target js cmd/conformance
```

**不要只看通过率。** 这个项目的求值引擎在「引用解析不了」时会 fail-open
（按通过处理），所以一个 bug 能让一批「期望不通过」的用例静默变成通过，
而通过率看不出任何异常。修引用/作用域相关的 bug 时，务必用
`JSTS_VERBOSE=1` 逐条核对「期望 / 实际」。

### 生成物

两个文件是生成的，改数据要改脚本、重跑脚本，不要手改：

| 生成物 | 脚本 | 数据来源 |
| --- | --- | --- |
| `src/regex/unicode_categories.mbt` | `scripts/gen-unicode-categories.mjs` | 宿主 Node 的 `\p{...}` |
| `src/metaschema/meta_docs.mbt` | `scripts/gen-metaschema.mjs` | `src/metaschema/raw/*.json` |

另有一份「伪生成物」：`README.mbt.md` 是 `README.md` 的副本（GitHub 读前者、
mooncakes.io 读后者）。改完 README 记得跑 `node scripts/sync-readme.mjs`。

两个生成器在写完之后会**只针对刚写出的那个文件**跑一次 `moon fmt`。这一步
不是可有可无的：生成器是机械拼字符串的，拼出来的排版（数组换行、尾逗号、
多行参数列表）不一定符合格式化器的规则。不统一的话会陷入「手动 `moon fmt`
改动它 → 重新生成又改回来」的来回漂移，CI 里「重新生成后工作区是否干净」
这条检查就永远有噪音，很快没人会再看它。改生成器时别把这一步删掉。

### 测试文件放哪

- `*_test.mbt` —— **黑盒**测试，只能看到公开 API。库的默认选择。
- `*_wbtest.mbt` —— **白盒**测试，能看包内私有定义。
  只有必须断言内部不变量时才用，例如 `src/regex/unicode_wbtest.mbt`
  要检查生成的区间表本身（类别数、覆盖范围、无缝升序）。

放错了会报 `The value identifier ... is unbound`——把用到私有定义的文件
改成 `_wbtest.mbt` 即可。

### 踩过的 MoonBit 语法坑

- `.mbt` 文件里**不能写 `import`**，依赖一律进同目录的 `moon.pkg`。
- 函数**没有 `priv` 关键字**，默认就是包内可见。
- `pub struct` 若含私有类型的字段，那些字段要单独标 `priv`，
  否则报 "A public definition cannot depend on private type"。
- 不能把构造器直接当高阶函数传（`f(x, NonCapture)` 报 4203），
  要包成闭包 `fn(inner : Node) -> Node { NonCapture(inner) }`。
- `Null` / `True` / `False` 是只读类型，不能作为 `Json` 值构造。
- `let` 型顶层值与 `Map` 字段：Map 通过方法改内容不算可变，标了 `mut`
  反而触发 `unused_mut` 警告。
- 已废弃的 API：`Char::from_int` → `Int::unsafe_to_char`，
  `String::ends_with` → `String::has_suffix`，
  JS FFI 里的 `Array[String]` → `FixedArray[String]`。
- **`s[i]` 返回的是 `UInt16`（UTF-16 码元），不是 `Char`。**
  所以 `s[i].to_string()` 得到的是十进制码位——`"https"` 会变成
  `"104116116112115"`，而且**能编译通过**，只在运行结果里露馅。
  要遍历字符用 `s.code_units()` 配 `unit.unsafe_to_char()`（见
  `src/schema/uri.mbt` 的 `percent_decode`），要单个字符用 `s.get_char(i)`。
- `extern "js"` 的 FFI **可以直接把 MoonBit 闭包当参数传给 JS**
  （`cmd/web/main.mbt` 靠这个把 API 挂到 `globalThis`）。这是把 MoonBit
  编成浏览器可调用模块的关键手法。
- `///|` 文档分隔符必须紧邻声明，中间插了别的行会让下一段声明变成孤立块。

### 在线演示页（`web/` + `cmd/web/`）

`web/index.html` 是一个纯静态页面，浏览器里跑的是**同一份实现**——
经 MoonBit 的 js 后端编译而来，不是另写的 JavaScript 版本。

```
cmd/web/main.mbt        MoonBit 侧入口：把三个函数挂到 globalThis
        ↓ moon build --target js --release
_build/js/release/build/cmd/web/web.js
        ↓ node scripts/build-web.mjs（拷贝）
web/vendor/moonbit-json-schema.js   ← 提交进仓库，clone 下来即可打开
```

接口形状（`web-smoke.mjs` 会钉住）：三个函数都收字符串、返回 JSON 字符串。

| 函数 | 作用 |
| --- | --- |
| `validate(schemaText, instanceText)` | 校验实例 |
| `lint(schemaText)` | 用元 schema 检查 schema 自身 |
| `metaschemaList()` | 列出内置的 9 份官方元 schema |

改完 `cmd/web/` 或 `web/` 之后：

```sh
node scripts/build-web.mjs          # 重新编译并拷贝产物
node scripts/web-wiring-check.mjs   # DOM id 与脚本路径（无依赖）
node scripts/web-smoke.mjs          # 接口是否真的挂上了
node scripts/web-examples-check.mjs # 页面示例是否还与实现一致
node scripts/web-render-check.mjs   # 真跑一遍页面（需 jsdom，没有则跳过）
```

四个检查各挡一类问题，别只跑第一个：

- **wiring** 静态核对，证明不了「按下去有反应」；
- **smoke** 证明接口挂上了，碰不到 DOM；
- **examples** 证明示例不说谎——页面最容易犯的不是报错，而是**演示一个
  并不存在的功能**，那种错误照样能打开、照样有输出，只能靠断言抓；
- **render** 真的建 DOM、真的点按钮，检查页面上的字变了没有。

页面刻意用传统 `<script>` 而非 ES module，为的是 `file://` 下双击就能打开。
改脚本引用时留意 `web-wiring-check.mjs` 里那条顺序断言。

### vendored 数据

`tests/JSON-Schema-Test-Suite/` 是官方套件的原样副本（MIT），
**不要就地修改**，见 `tests/VENDORED.md`。

### 提交前

`.githooks/pre-commit` 会同步 README、跑 `moon check`。启用它：

```sh
git config core.hooksPath .githooks
```
