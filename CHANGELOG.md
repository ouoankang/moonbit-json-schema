# Changelog

本项目遵循「一个版本一个可验证的变更」的原则，不设严格语义化版本号——
它还未发布到 mooncakes.io，先按日期记录。

## 2026-09-12 · 初版

首个完整版本，JSON Schema draft 2020-12 校验器从零实现。

### 核心能力

- **校验内核**：draft 2020-12 全部必测关键字，含断言、子应用器、结构调整、
  引用与标识（`$ref` / `$id` / `$anchor` / `$dynamicRef` / `$vocabulary`）、
  注解与求值（`unevaluatedProperties` / `unevaluatedItems`）。
- **自研正则引擎**：符合 ECMA-262 语义（`\d`/`\w` 严格 ASCII、按码点匹配、
  `\p{...}` Unicode 属性），约 1300 行。
- **元 schema 自校验**：内置 9 份官方元 schema，`lint` 子命令校验 schema 自身。
- **三种用法**：库、CLI（`validate` / `lint` / `metaschema`）、浏览器在线试用页。
- **一致性测试台**：`cmd/conformance` 跑官方套件，支持按文件名过滤与逐条核对。

### format 断言

实现了 15 个 `format` 的值校验：date-time / date / time / duration / ipv4 /
ipv6 / hostname / email / uri / uri-reference / uri-template / uuid /
json-pointer / relative-json-pointer / regex。`format` 默认保持注解语义，仅当
元 schema 声明 `format-assertion` 词汇表（或测试台强制）时才升级为断言。

### 成绩

| 指标 | 结果 |
| --- | --- |
| 官方一致性套件 · 必测 | **1301 / 1301（100.0%）** |
| 官方一致性套件 · 可选 | **929 / 1023（90.8%）** |
| 单元测试 | 61 / 61（wasm + js） |
| `moon check` | 0 警告 0 错误 |

### 已知未实现

- IDN/IRI 格式（`idn-email` / `idn-hostname` / `iri` / `iri-reference`，
  及 hostname 的 `xn--` 标签 punycode 校验）——需完整 IDNA 表，留作后续。
- 跨草案方言（`optional/cross-draft.json` 1 条，要求 2019-09 语义）。
