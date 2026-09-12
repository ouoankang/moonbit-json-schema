# VENDORED — 随仓库版本化的第三方测试数据

`JSON-Schema-Test-Suite/` 是
[JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
的**原样副本**，采用 MIT 许可（原始 `LICENSE` 一并保留在子目录里）。

## 为什么要放进仓库

一致性成绩要能被人复现。如果测试台需要调用者自己去 clone 官方仓库、
还要对上版本，那么「1301/1301」这个数字就只是一个声明，而不是一个可验证的
事实。把数据随仓库版本化之后：

```sh
git clone <this-repo>
cd moonbit-json-schema
moon run --target js cmd/conformance
```

在离线环境下也能得到同样的数字。

## 快照信息

| 项 | 值 |
| --- | --- |
| 快照日期 | 2026-09-12 |
| 保留的目录 | `draft2020-12/`、`remotes/`、`LICENSE` |
| 未保留 | 其它草案的目录（`draft4/`…`draft2019-09/`）、`.github/`、`bin/` 等 |
| 文件数 | 159 个 JSON |
| 大小 | 约 914 KB |

`draft2020-12/` 下 46 个必测文件（1301 条用例）、13 个 `optional/` 文件
与 21 个 `optional/format/` 文件（合计 1023 条用例）；
`remotes/` 下 79 份远程文档，供 `refRemote.json` 等用例的 `$ref` 使用。

## 注意

- **不要就地修改这里的数据。** 需要新增用例时，应该先在官方仓库上游改，
  再整体重新快照——否则本地改动会在下一次快照时丢失，而且没有任何记录。
- 官方套件的 `remotes/draft2019-09/` 等目录在测试台里也会被登记，
  但只有 2020-12 的用例会用到它们的一部分（例如 `optional/cross-draft.json`）。

## 元 schema

官方元 schema（`https://json-schema.org/draft/2020-12/schema` 系列）**不在这里**。
套件的约定是实现自己提供它，所以本仓库把它内联在 `src/metaschema/`，
原始文件见 `src/metaschema/raw/`。
