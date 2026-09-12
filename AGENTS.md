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
- `///|` 文档分隔符必须紧邻声明，中间插了别的行会让下一段声明变成孤立块。

### vendored 数据

`tests/JSON-Schema-Test-Suite/` 是官方套件的原样副本（MIT），
**不要就地修改**，见 `tests/VENDORED.md`。

### 提交前

`.githooks/pre-commit` 会同步 README、跑 `moon check`。启用它：

```sh
git config core.hooksPath .githooks
```
