# raw/ — 官方元 schema 的原始副本

这里的 `.json` 是从 <https://json-schema.org/draft/2020-12/> **原样下载**的
官方元 schema，未做任何修改。它们不参与编译，只作为
`../meta_docs.mbt` 的数据来源和比对基准。

重新抓取（`--ssl-no-revoke` 是为了绕过部分 Windows 环境下的吊销列表检查失败）：

```sh
cd src/metaschema/raw
for name in schema meta/core meta/applicator meta/validation meta/unevaluated \
            meta/meta-data meta/format-annotation meta/format-assertion meta/content
do
  out=$(echo "$name" | tr '/' '_')
  curl -sS --ssl-no-revoke -o "$out.json" "https://json-schema.org/draft/2020-12/$name"
done
```

改完之后重新生成 MoonBit 源码：

```sh
node scripts/gen-metaschema.mjs
```

| 文件 | `$id` |
| --- | --- |
| `schema.json` | `https://json-schema.org/draft/2020-12/schema` |
| `meta_core.json` | `https://json-schema.org/draft/2020-12/meta/core` |
| `meta_applicator.json` | `https://json-schema.org/draft/2020-12/meta/applicator` |
| `meta_validation.json` | `https://json-schema.org/draft/2020-12/meta/validation` |
| `meta_unevaluated.json` | `https://json-schema.org/draft/2020-12/meta/unevaluated` |
| `meta_meta-data.json` | `https://json-schema.org/draft/2020-12/meta/meta-data` |
| `meta_format-annotation.json` | `https://json-schema.org/draft/2020-12/meta/format-annotation` |
| `meta_format-assertion.json` | `https://json-schema.org/draft/2020-12/meta/format-assertion` |
| `meta_content.json` | `https://json-schema.org/draft/2020-12/meta/content` |

## 许可证

JSON Schema 规范及其元 schema 由 JSON Schema 组织发布，采用
[BSD-3-Clause](https://github.com/json-schema-org/json-schema-spec/blob/main/LICENSE)
许可。这里的副本保留了原始内容（含各文件内的 `$comment` 等文本），
仅作数据用途。详见仓库根目录 `LICENSE` 与 README 的「第三方资源」一节。
