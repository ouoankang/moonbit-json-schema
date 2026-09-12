<!-- 本文件由 scripts/sync-readme.mjs 从 README.md 复制生成，请勿直接编辑。 -->

# moonbit-json-schema

**用 MoonBit 从零实现的 JSON Schema draft 2020-12 校验器。**

[![MoonBit](https://img.shields.io/badge/MoonBit-0.6-blue)](https://www.moonbitlang.com/)
[![license](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

| 指标 | 结果 |
| --- | --- |
| 官方一致性套件 · 必测用例 | **1301 / 1301（100.0%）** |
| 官方一致性套件 · 可选用例 | 567 / 1023（55.4%，未实现 `format` 断言，见[已知限制](#已知限制)） |
| 单元测试 | 51 / 51 通过（默认 `wasm` 目标） |
| 自写源码 | 约 5 600 行 MoonBit（不含生成的 Unicode 表与元 schema） |

---

## 目录

- [这个项目解决什么问题](#这个项目解决什么问题)
- [快速开始](#快速开始)
- [覆盖了哪些关键字](#覆盖了哪些关键字)
- [一致性测试成绩](#一致性测试成绩)
- [项目结构](#项目结构)
- [几个值得说的实现点](#几个值得说的实现点)
- [已知限制](#已知限制)
- [第三方资源与许可](#第三方资源与许可)
- [AI 辅助说明](#ai-辅助说明)

---

## 这个项目解决什么问题

JSON Schema 是描述 JSON 数据形状的通用契约语言：OpenAPI、CI 配置、包清单、
编辑器插件配置，几乎都是用它写的。它的实现遍布各种语言——Python 的
`jsonschema`、Go 的 `santhosh-tekuri/jsonschema`、Rust 的 `jsonschema-rs`——
唯独 MoonBit 生态里还没有一个完整的 draft 2020-12 实现。

`moonbit-json-schema` 补上这一块。它不是「够用就行」的简化版，而是把规范里
真正难的几块都做完了：

- **URI 解析**（RFC 3986 §5.2）与 **JSON Pointer**（RFC 6901）——`$ref` 不是字符串匹配；
- **注解传播模型**——`unevaluatedProperties` / `unevaluatedItems` 的全部语义；
- **动态作用域**——`$dynamicAnchor` / `$dynamicRef`；
- **方言与词汇表**——`$schema` 指向的元 schema 通过 `$vocabulary` 决定关键字是否生效；
- **一套自己写的 ECMA-262 正则引擎**——`pattern` 要求按 ECMA-262 语义解释，
  而 `wasm` 目标上没有宿主正则可用，只能自己实现。

顺带它还内置了官方元 schema 系列文档，所以除了「校验实例」，它还能
**检查一份 schema 本身写得对不对**（`lint`）——`{"type":"sting"}` 这种笔误
在校验实例时永远不会报错，只有拿元 schema 校验一遍才会暴露。

想先看效果再读代码：打开 `web/index.html`（双击即可，无需构建），
浏览器里跑的就是这份实现本身。

---

## 快速开始

### 1. 装 MoonBit 工具链

Linux / macOS：

```sh
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
```

Windows 见 [MoonBit 官网安装说明](https://www.moonbitlang.com/download/)。

验证：

```sh
moon version --all
```

### 2. 跑测试

```sh
moon check     # 类型检查
moon test      # 51 个单元测试（默认 wasm 目标）
```

### 3. 用命令行

```sh
# 用 schema 校验实例
moon run --target js cmd/main -- validate examples/person.schema.json examples/person.ok.json

# 检查 schema 自身是否合法（拿官方元 schema 当尺子）
moon run --target js cmd/main -- lint examples/broken.schema.json

# 导出内置的官方元 schema 原文
moon run --target js cmd/main -- metaschema > metaschema.txt
```

实际输出：

```text
$ moon run --target js cmd/main -- validate examples/person.schema.json examples/person.bad.json
schema : examples/person.schema.json
  examples/person.bad.json          不通过（7 处）
        /name                         minLength           string is shorter than minLength (counted in Unicode code points)
        /age                          minimum             value is below the minimum
        /tags                         uniqueItems         array items are not unique
        /address/postcode             pattern             string does not match pattern `^[0-9]{6}$`
        /friends/0                    required            missing required property `name`
        /role                         enum                instance is not one of the enumerated values
        /nickname                     false               boolean schema `false` rejects every instance

结果: 有 1 个实例不通过。
```

```text
$ moon run --target js cmd/main -- lint examples/broken.schema.json examples/person.schema.json
  examples/broken.schema.json             不符合元 schema（4 处）
        /properties/age/type           anyOf               instance does not match any of the subschemas
        /properties/level/enum         type                expected type `array`
        /minLength                     minimum             value is below the minimum
        /required                      type                expected type `array`
  examples/person.schema.json             合法

结果: 有 1 份 schema 不符合元 schema。
```

> CLI 走 `js` 后端是因为它要读文件，而 `wasm` 目标没有文件系统。
> **库本体（`src/`）不依赖任何平台能力**，在 `wasm` 上通过全部单元测试。

### 4. 当库用

```moonbit
let schema_node = @json.parse(schema_text)
let instance = @json.parse(instance_text)

// 编译一次，可以复用着校验很多实例
let compiled = @schema.Schema::of(schema_node)
let errors : Array[@schema.ValidationError] = compiled.validate(instance)
if errors.length() == 0 {
  println("通过")
} else {
  for e in errors {
    println(e.instance_path + "  " + e.keyword + "  " + e.message)
  }
}
```

跨文档 `$ref` 用 `of_with_documents` 事先登记远程文档：

```moonbit
let compiled = @schema.Schema::of_with_documents(root, [
  ("https://example.com/other.json", other_doc),
])
```

想把官方元 schema 也挂上（这样 `$ref` 到
`https://json-schema.org/draft/2020-12/schema` 能解析）：

```moonbit
let compiled = @schema.Schema::of_with_documents(
  root,
  @metaschema.metaschema_documents(),
)
```

### 5. 在浏览器里

`web/index.html` 是一个纯静态页面，浏览器里跑的是**同一份实现**——它经
MoonBit 的 js 后端编译而来，不是另写的 JavaScript 版本。直接双击打开即可，
不需要起服务器：

```
web/index.html
```

页面提供三个动作：校验实例、用元 schema 检查 schema、查看内置的 9 份官方
元 schema。它同时也是一份手把手的说明——每个示例都在演示一个具体的关键字
行为（注解怎么冒泡、`$dynamicRef` 怎么收敛、`lint` 为什么能抓到 `validate`
抓不到的错）。

重新构建页面产物：

```sh
node scripts/build-web.mjs
```

页面自己也有一组检查，四层各挡一类问题——只跑第一层是不够的：

| 脚本 | 挡什么 |
| --- | --- |
| `web-wiring-check.mjs` | DOM id 对不上、脚本路径写错、加载顺序反了 |
| `web-smoke.mjs` | 接口没挂上或挂错（`moon test` 完全覆盖不到这一层） |
| `web-examples-check.mjs` | 示例与实现脱节——页面开始演示一个并不存在的功能 |
| `web-render-check.mjs` | 真建 DOM、真点按钮，检查页面上的字变了没有 |

`web-render-check.mjs` 依赖 `jsdom`，没装会自行跳过，不影响其余检查。

---

## 覆盖了哪些关键字

### 断言与子应用器

| 分组 | 关键字 |
| --- | --- |
| 原地应用器 | `$ref`、`$dynamicRef`、`allOf`、`anyOf`、`oneOf`、`not`、`if` / `then` / `else`、`dependentSchemas` |
| 通用 | `type`、`enum`、`const` |
| 数值 | `multipleOf`、`maximum`、`exclusiveMaximum`、`minimum`、`exclusiveMinimum` |
| 字符串 | `maxLength`、`minLength`、`pattern` |
| 数组 | `maxItems`、`minItems`、`uniqueItems`、`prefixItems`、`items`、`contains`、`maxContains`、`minContains`、`unevaluatedItems` |
| 对象 | `maxProperties`、`minProperties`、`required`、`dependentRequired`、`properties`、`patternProperties`、`additionalProperties`、`propertyNames`、`unevaluatedProperties` |
| 兼容旧草案 | `dependencies`（2019-09 起被拆成 `dependentRequired` + `dependentSchemas`） |

### 结构与标识

`$id`、`$anchor`、`$dynamicAnchor`、`$defs`、`$vocabulary`、`$schema`、`$comment`。

嵌套 `$id` 会正确改变后续子 schema 的 base URI；URN 形式的 `$id`
（`urn:uuid:...`）也能正确处理。跨文档 `$ref` 通过
`Schema::of_with_documents` 注册外部文档，不需要在校验途中做 IO。

### 注解关键字

`title`、`description`、`default`、`examples`、`deprecated`、`readOnly`、
`writeOnly`、`format`、`contentMediaType`、`contentEncoding`——一概不参与判定。
`format` 在 2020-12 里默认就是注解，把它当断言会误判一批用例。

---

## 一致性测试成绩

成绩由仓库自带的一致性测试台跑出，测试数据随仓库版本化，**不依赖网络**：

```sh
moon run --target js cmd/conformance
```

```text
JSON-Schema-Test-Suite / draft2020-12
  套件目录      : tests/JSON-Schema-Test-Suite
  远程文档      : 79 份远程 + 9 份官方元 schema

== 必测 ==
  ok    not.json                        40/40
  ok    ref.json                        79/79
  ok    type.json                       80/80
  ok    refRemote.json                  31/31
  ok    dynamicRef.json                 44/44
  ok    unevaluatedProperties.json      129/129
  ok    unevaluatedItems.json           71/71
  ... （共 46 个文件）

  必测合计: 1301/1301  100.0%
```

### 关于「必测」与「可选」

官方套件把用例分成两份：

- `draft2020-12/*.json`——**必测**。规范要求实现必须全部通过，1301 条。
- `draft2020-12/optional/*.json`——**可选**。规范明确允许实现不提供，
  1023 条。其中绝大部分是 `format` 断言（`optional/format/*.json`，共 854 条）。

本实现必测部分全绿；可选部分 567/1023，未通过的全部集中在
`format` 断言与跨草案方言上（见[已知限制](#已知限制)）。
测试台会把可选用例的失败单独列出来，但**不计入退出码**。

### 测试台自己也是被测对象

测试台（`cmd/conformance`）按 group 编译一次 schema、复用到该 group 的全部
用例上——既省时间，也更接近真实用法。支持两个环境变量：

```sh
JSTS_ONLY=dynamicRef JSTS_VERBOSE=1 moon run --target js cmd/conformance
```

`JSTS_ONLY=<子串>` 只跑文件名匹配的用例，`JSTS_VERBOSE=1` 逐条打印
「期望 / 实际」。上面那些难修的 bug 都是这样定位出来的。

---

## 项目结构

```text
.
├── src/
│   ├── pointer/            RFC 6901 JSON Pointer
│   ├── regex/              自写的 ECMA-262 正则引擎
│   │   ├── unicode_categories.mbt   Unicode 一般类别区间表（生成物）
│   │   └── unicode_wbtest.mbt       白盒测试：表的不变量
│   ├── schema/
│   │   ├── uri.mbt         RFC 3986 五段分解 + 相对引用解析
│   │   ├── compile.mbt     $id/$anchor 索引、$ref 与 $dynamicRef 解析
│   │   ├── validate.mbt    求值引擎（断言 + 注解）
│   │   └── errors.mbt      ValidationError
│   └── metaschema/         官方 2020-12 元 schema（编译期内联）
│       ├── meta_docs.mbt   生成物
│       └── raw/            原样下载的官方 JSON
├── cmd/
│   ├── main/               CLI：validate / lint / metaschema
│   ├── web/                浏览器入口：把 API 挂到 globalThis
│   └── conformance/        官方一致性测试台
├── web/                    在线试用页（纯静态，双击可开）
│   ├── index.html
│   ├── app.js              页面胶水层，不含校验逻辑
│   ├── examples.js         示例数据（自带期望值，可被脚本校验）
│   └── vendor/             MoonBit 编译产物（由 build-web.mjs 拷贝）
├── examples/               示例 schema 与实例
├── scripts/
│   ├── gen-unicode-categories.mjs
│   ├── gen-metaschema.mjs
│   ├── build-web.mjs                编译并拷贝页面产物
│   ├── web-wiring-check.mjs         DOM id 与脚本路径（无依赖）
│   ├── web-smoke.mjs                接口是否真的挂上了
│   ├── web-examples-check.mjs       示例是否还与实现一致
│   └── web-render-check.mjs         真跑一遍页面（需 jsdom，可选）
└── tests/JSON-Schema-Test-Suite/   随仓库版本化的官方套件
```

---

## 几个值得说的实现点

下面这几处都是**写错了不会报错、只会静默给出错误答案**的地方，也是这个项目
花时间最多的地方。它们各自对应套件里一组专门的用例。

### 1. 注解必须带实例位置，不能顺着树往上冒泡

`unevaluatedProperties: false` 的依据是「这一层里哪些属性已经被认领过」。
问题在于 `properties` 会对**子实例**求值子 schema：

```json
{
  "properties": { "foo": { "properties": { "bar": { "type": "string" } } } },
  "unevaluatedProperties": false
}
```

对 `{"foo": {"bar": "foo"}, "bar": "bar"}` 求值时，内层那句「`bar` 已认领」
说的是 `/foo` 这个位置的 `bar`，跟根位置的 `bar` 毫无关系。如果像普通子结果
一样把注解收上来，根位置就会凭空多出一条认领记录，于是这份**应该不通过**的数据
被判为通过。

所以代码里「合并子结果」分成了两个方法：

```moonbit
fn Outcome::merge(self, other)   // 同一实例位置：收注解
fn Outcome::require(self, other) // 更深实例位置：只取通过与否，注解丢掉
```

`properties` / `patternProperties` / `additionalProperties` / `propertyNames` /
`prefixItems` / `items` / `unevaluated*` 用 `require`；`allOf` / `anyOf` /
`oneOf` / `$ref` / `if-then-else` / `dependentSchemas` 用 `merge`。判断标准就是
一句话：**子 schema 是不是在同一个实例位置上求值**。

对应用例：`unevaluatedProperties.json` 与 `unevaluatedItems.json` 里的
"Evaluated … needs to consider instance location"。

### 2. `$id` 只能解析一次

`SchemaRef` 里存了两个看起来很像、实际必须分开的字段：

```moonbit
priv struct SchemaRef {
  node : Json
  path : String
  uri  : String  // 节点所在资源的绝对 URI（$id 已解析）
  base : String  // 求值这个节点时传入的 base = 它自己 $id 的解析基准
}
```

规范要求 `$id` 相对**父 base** 解析。如果偷懒把 `uri` 当 `base` 用，
一份 `{"$id":"a/", "items":{"$ref":"x.json"}}` 的远程文档会算出 `a/a/x.json`——
路径里多出一层目录，`$ref` 于是静默解析失败。

对应用例：`refRemote.json` 的 "base URI change - change folder"。

### 3. 打断自引用环的判据，必须能唯一定位一个 schema 节点

求值引擎用一张 `active` 表记录「正在求值中的 (schema, 实例位置)」，遇到重复就
按通过处理，以此打断 `{"$ref": "#"}` 这类环。最初的键是
`schema_path + 实例路径`，而 `schema_path` 是**相对根文档**的路径——
两份不同文档的根都是 `""`，于是「远程文档根」的 `$ref` 被误判成自引用，
整个远程 schema 被跳过。

修复是在键里加上 `base`：

```moonbit
let key = base + "\u{1}" + schema_path + "\u{1}" + instance_path
```

这个 bug 的隐蔽之处在于**它让不通过的用例变成通过**——查不到引用时引擎
按「未实现」处理，而「未实现」不能算失败。结果是那些期望「不通过」的用例
全部误判为通过，而期望「通过」的照样通过。只看通过率是发现不了的，
必须正反两面都测。

### 4. 动态作用域不只在 `$ref` 处压栈

`$dynamicRef` 在动态作用域里从最外层往里找第一个同名 `$dynamicAnchor`。
一开始只在 `$ref` / `$dynamicRef` 命中时压栈——这不够：`if` / `then` /
`$defs` 里用 `$id` 直接开出来的资源是**走**进去的，不经过任何 `$ref`。

现在 `eval_object` 在节点自带 `$id` 时就 `enter_resource`，返回前弹栈。
`enter_resource` 对「与栈顶相同」的情况去重，所以 `$ref` 那一侧的压栈和这一侧
不会重复。

另一处细节：`$ref` 指向 `bar#/$defs/item` 时，如果 `item` 自带 `$id`，
那么进入的是 `item` 这个资源，`bar` 只是被**跨过**——压栈的必须是前者。
对应用例：`optional/dynamicRef.json` 的
"$dynamicRef skips over intermediate resources"。

### 5. 为什么正则引擎要自己写

规范的 `pattern` 要求按 **ECMA-262** 语义解释，不是「宿主语言的正则」。
在 `wasm` 目标上没有宿主正则可用，所以 `src/regex/` 是一套完整的实现：
解析器（含 Annex B 回退）、CPS 风格的回溯匹配器、捕获组回滚、前后瞻、
反向引用、懒惰量词。

两个最容易踩的语义差异：

- **`\d` / `\w` 只认 ASCII**，`\p{digit}` 才按 Unicode 算（匹配孟加拉数字）。
  混用会让 `optional/ecmascript-regex.json` 里的用例成片失败。
- **按码点匹配，不按 UTF-16 码元**。`{}` 里是 🐲 时，
  `^🐲*$` 必须按一个码点算。

`\p{...}` 需要 Unicode 一般类别数据。`scripts/gen-unicode-categories.mjs`
用宿主的 `\p{...}` 逐码点查询、压成区间，生成 4 144 条无缝覆盖
U+0000..U+10FFFF 的区间表；`unicode_wbtest.mbt` 把「类别数、覆盖范围、
区间无缝升序」这几个不变量钉住。

### 6. `$vocabulary` 是关键字的总开关

元 schema 里没声明的词汇表，其关键字必须当成**未知关键字忽略**。
官方套件里有一份把 validation 词汇表摘掉的元 schema，用它当 `$schema` 的
文档里 `minimum` 必须完全不起作用。

与其在 1500 行的 `eval_object` 里给每个关键字都套一个条件判断，
不如在入口处把键去掉——所以有 `eval_object` 这层薄包装：

```moonbit
let mut effective = obj
if !v.vocab_validation { effective = without_keywords(effective, validation_keywords) }
if !v.vocab_applicator { effective = without_keywords(effective, applicator_keywords) }
if !v.vocab_unevaluated { effective = without_keywords(effective, unevaluated_keywords) }
```

默认全开。这个默认很关键：绝大多数 schema 的 `$schema` 指向的是标准 URI，
而那份文档未必被登记进来——「查不到就当成什么都没启用」会让所有关键字
集体失效。

---

## 已知限制

诚实列出来，都是有意取舍，不是遗漏：

1. **`format` 默认是注解，不实现 format 断言。**
   这符合 2020-12 的默认行为（`format-annotation` 词汇表），
   所以 `optional/format/*.json` 里那些「期望不通过」的用例不计入成绩。
   要拿到这部分分数需要实现 date / time / duration / ipv4 / ipv6 / uri /
   email / hostname / idn-hostname 等十几个格式的解析器——包括 IDNA，
   工作量与收益不成比例，所以留作后续。
2. **只支持 draft 2020-12。** 2019-09 及更早草案不识别。
   这会让 `optional/cross-draft.json` 的 1 条用例失败（它要求把
   `draft2019-09/` 下的引用按 2019-09 语义处理）。
3. **CLI 需要 `js` 后端**，因为它读文件而 `wasm` 没有文件系统。
   库本体不受影响。
4. **`contentSchema` 不做校验**（`contentMediaType` / `contentEncoding`
   按注解处理）。规范本身也不要求校验。
5. 求值有递归深度上限（256 层），超出后放弃深入——宁可放过也不误报。

---

## 第三方资源与许可

本项目以 **Apache-2.0** 发布，见 [LICENSE](LICENSE)。

包含的第三方资源：

| 资源 | 用途 | 许可 |
| --- | --- | --- |
| [JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) | 一致性测试数据，随仓库版本化在 `tests/JSON-Schema-Test-Suite/` | MIT |
| [JSON Schema 规范](https://json-schema.org/) 的官方元 schema | 内联在 `src/metaschema/`，用于 `lint` | 见 [json-schema-spec LICENSE](https://github.com/json-schema-org/json-schema-spec/blob/main/LICENSE) |
| Unicode 一般类别数据 | `src/regex/unicode_categories.mbt`，由 `scripts/gen-unicode-categories.mjs` 从宿主运行时的 `\p{...}` 生成 | Unicode License |

`tests/VENDORED.md` 记录了随仓库版本化的测试数据的来源与快照信息。

---

## AI 辅助说明

本项目的代码与文档在 AI 助手（WorkBuddy）的辅助下完成，过程可追溯、结论可复现：

- **生成物都带生成脚本。** `src/regex/unicode_categories.mbt` 由
  `scripts/gen-unicode-categories.mjs` 生成，`src/metaschema/meta_docs.mbt`
  由 `scripts/gen-metaschema.mjs` 生成。两份脚本都带自检
  （区间覆盖率、`$id` 唯一性、纯 ASCII 断言），重跑可复现。
- **每条结论都有对应的验证命令。** 一致性成绩用
  `moon run --target js cmd/conformance` 复现；单元测试用 `moon test`。
  两个命令都不依赖网络。
- **AI 写的每一处修复都有回归测试。** 上面「几个值得说的实现点」里提到的
  四个 bug，修复后都补了对应的用例：
  `src/schema/remote_test.mbt` 覆盖跨文档 `$ref` 的别名与嵌套 `$id`，
  `src/schema/schema_test.mbt` 覆盖注解与环判据，
  `src/regex/regex_test.mbt` 覆盖 ECMA-262 语义分歧点。
- **错误结论是怎么被发现的。** 开发过程中出现过「必测通过率 98% 却仍有
  静默错误」的阶段：环判据那个 bug 让 6 条远程引用用例被跳过。它是靠
  `JSTS_VERBOSE=1` 逐条核对「期望 / 实际」而不是只看百分比找到的。

---

## 许可

Apache License 2.0，见 [LICENSE](LICENSE)。
