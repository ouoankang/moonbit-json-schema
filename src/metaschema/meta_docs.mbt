// 本文件由 scripts/gen-metaschema.mjs 自动生成，请勿手工编辑。
//
// 内容是 JSON Schema draft 2020-12 的官方元 schema 系列文档，
// 原始文件保存在 src/metaschema/raw/（纯文本、原样下载，便于比对上游）。
//
// 为什么要把它们编进库本体：
//   * 校验 `$schema` 指向官方元 schema 的文档（也就是「检查一份 schema
//     本身写对了没有」）需要它，而这是本库的主要用途之一；
//   * wasm 目标没有文件系统，运行时读不到外部文件，只能编译期内联。

///|
/// 把若干行拼成一个字符串。生成器把每个 JSON 行输出成一个字面量，
/// 靠这个函数还原。
fn join_lines(lines : Array[String]) -> String {
  let buf = StringBuilder()
  let mut first = true
  for line in lines {
    if !first {
      buf.write_char('\n')
    }
    first = false
    buf.write_string(line)
  }
  buf.to_string()
}

///|
/// `https://json-schema.org/draft/2020-12/schema`（源自 raw/schema.json）。
let meta_text_schema : String = join_lines([
  "{", "    \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",", "    \"$id\": \"https://json-schema.org/draft/2020-12/schema\",",
  "    \"$vocabulary\": {", "        \"https://json-schema.org/draft/2020-12/vocab/core\": true,",
  "        \"https://json-schema.org/draft/2020-12/vocab/applicator\": true,", "        \"https://json-schema.org/draft/2020-12/vocab/unevaluated\": true,",
  "        \"https://json-schema.org/draft/2020-12/vocab/validation\": true,", "        \"https://json-schema.org/draft/2020-12/vocab/meta-data\": true,",
  "        \"https://json-schema.org/draft/2020-12/vocab/format-annotation\": true,",
  "        \"https://json-schema.org/draft/2020-12/vocab/content\": true", "    },",
  "    \"$dynamicAnchor\": \"meta\",", "", "    \"title\": \"Core and Validation specifications meta-schema\",",
  "    \"allOf\": [", "        {\"$ref\": \"meta/core\"},", "        {\"$ref\": \"meta/applicator\"},",
  "        {\"$ref\": \"meta/unevaluated\"},", "        {\"$ref\": \"meta/validation\"},",
  "        {\"$ref\": \"meta/meta-data\"},", "        {\"$ref\": \"meta/format-annotation\"},",
  "        {\"$ref\": \"meta/content\"}", "    ],", "    \"type\": [\"object\", \"boolean\"],",
  "    \"$comment\": \"This meta-schema also defines keywords that have appeared in previous drafts in order to prevent incompatible extensions as they remain in common use.\",",
  "    \"properties\": {", "        \"definitions\": {", "            \"$comment\": \"\\\"definitions\\\" has been replaced by \\\"$defs\\\".\",",
  "            \"type\": \"object\",", "            \"additionalProperties\": { \"$dynamicRef\": \"#meta\" },",
  "            \"deprecated\": true,", "            \"default\": {}", "        },",
  "        \"dependencies\": {", "            \"$comment\": \"\\\"dependencies\\\" has been split and replaced by \\\"dependentSchemas\\\" and \\\"dependentRequired\\\" in order to serve their differing semantics.\",",
  "            \"type\": \"object\",", "            \"additionalProperties\": {",
  "                \"anyOf\": [", "                    { \"$dynamicRef\": \"#meta\" },",
  "                    { \"$ref\": \"meta/validation#/$defs/stringArray\" }", "                ]",
  "            },", "            \"deprecated\": true,", "            \"default\": {}",
  "        },", "        \"$recursiveAnchor\": {", "            \"$comment\": \"\\\"$recursiveAnchor\\\" has been replaced by \\\"$dynamicAnchor\\\".\",",
  "            \"$ref\": \"meta/core#/$defs/anchorString\",", "            \"deprecated\": true",
  "        },", "        \"$recursiveRef\": {", "            \"$comment\": \"\\\"$recursiveRef\\\" has been replaced by \\\"$dynamicRef\\\".\",",
  "            \"$ref\": \"meta/core#/$defs/uriReferenceString\",", "            \"deprecated\": true",
  "        }", "    }", "}",
])

///|
/// `https://json-schema.org/draft/2020-12/meta/core`（源自 raw/meta_core.json）。
let meta_text_core : String = join_lines([
  "{", "    \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",", "    \"$id\": \"https://json-schema.org/draft/2020-12/meta/core\",",
  "    \"$dynamicAnchor\": \"meta\",", "", "    \"title\": \"Core vocabulary meta-schema\",",
  "    \"type\": [\"object\", \"boolean\"],", "    \"properties\": {", "        \"$id\": {",
  "            \"$ref\": \"#/$defs/uriReferenceString\",", "            \"$comment\": \"Non-empty fragments not allowed.\",",
  "            \"pattern\": \"^[^#]*#?$\"", "        },", "        \"$schema\": { \"$ref\": \"#/$defs/uriString\" },",
  "        \"$ref\": { \"$ref\": \"#/$defs/uriReferenceString\" },", "        \"$anchor\": { \"$ref\": \"#/$defs/anchorString\" },",
  "        \"$dynamicRef\": { \"$ref\": \"#/$defs/uriReferenceString\" },", "        \"$dynamicAnchor\": { \"$ref\": \"#/$defs/anchorString\" },",
  "        \"$vocabulary\": {", "            \"type\": \"object\",", "            \"propertyNames\": { \"$ref\": \"#/$defs/uriString\" },",
  "            \"additionalProperties\": {", "                \"type\": \"boolean\"",
  "            }", "        },", "        \"$comment\": {", "            \"type\": \"string\"",
  "        },", "        \"$defs\": {", "            \"type\": \"object\",", "            \"additionalProperties\": { \"$dynamicRef\": \"#meta\" }",
  "        }", "    },", "    \"$defs\": {", "        \"anchorString\": {", "            \"type\": \"string\",",
  "            \"pattern\": \"^[A-Za-z_][-A-Za-z0-9._]*$\"", "        },", "        \"uriString\": {",
  "            \"type\": \"string\",", "            \"format\": \"uri\"", "        },",
  "        \"uriReferenceString\": {", "            \"type\": \"string\",", "            \"format\": \"uri-reference\"",
  "        }", "    }", "}",
])

///|
/// `https://json-schema.org/draft/2020-12/meta/applicator`（源自 raw/meta_applicator.json）。
let meta_text_applicator : String = join_lines([
  "{", "    \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",", "    \"$id\": \"https://json-schema.org/draft/2020-12/meta/applicator\",",
  "    \"$dynamicAnchor\": \"meta\",", "", "    \"title\": \"Applicator vocabulary meta-schema\",",
  "    \"type\": [\"object\", \"boolean\"],", "    \"properties\": {", "        \"prefixItems\": { \"$ref\": \"#/$defs/schemaArray\" },",
  "        \"items\": { \"$dynamicRef\": \"#meta\" },", "        \"contains\": { \"$dynamicRef\": \"#meta\" },",
  "        \"additionalProperties\": { \"$dynamicRef\": \"#meta\" },", "        \"properties\": {",
  "            \"type\": \"object\",", "            \"additionalProperties\": { \"$dynamicRef\": \"#meta\" },",
  "            \"default\": {}", "        },", "        \"patternProperties\": {",
  "            \"type\": \"object\",", "            \"additionalProperties\": { \"$dynamicRef\": \"#meta\" },",
  "            \"propertyNames\": { \"format\": \"regex\" },", "            \"default\": {}",
  "        },", "        \"dependentSchemas\": {", "            \"type\": \"object\",",
  "            \"additionalProperties\": { \"$dynamicRef\": \"#meta\" },", "            \"default\": {}",
  "        },", "        \"propertyNames\": { \"$dynamicRef\": \"#meta\" },", "        \"if\": { \"$dynamicRef\": \"#meta\" },",
  "        \"then\": { \"$dynamicRef\": \"#meta\" },", "        \"else\": { \"$dynamicRef\": \"#meta\" },",
  "        \"allOf\": { \"$ref\": \"#/$defs/schemaArray\" },", "        \"anyOf\": { \"$ref\": \"#/$defs/schemaArray\" },",
  "        \"oneOf\": { \"$ref\": \"#/$defs/schemaArray\" },", "        \"not\": { \"$dynamicRef\": \"#meta\" }",
  "    },", "    \"$defs\": {", "        \"schemaArray\": {", "            \"type\": \"array\",",
  "            \"minItems\": 1,", "            \"items\": { \"$dynamicRef\": \"#meta\" }",
  "        }", "    }", "}",
])

///|
/// `https://json-schema.org/draft/2020-12/meta/validation`（源自 raw/meta_validation.json）。
let meta_text_validation : String = join_lines([
  "{", "    \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",", "    \"$id\": \"https://json-schema.org/draft/2020-12/meta/validation\",",
  "    \"$dynamicAnchor\": \"meta\",", "", "    \"title\": \"Validation vocabulary meta-schema\",",
  "    \"type\": [\"object\", \"boolean\"],", "    \"properties\": {", "        \"type\": {",
  "            \"anyOf\": [", "                { \"$ref\": \"#/$defs/simpleTypes\" },",
  "                {", "                    \"type\": \"array\",", "                    \"items\": { \"$ref\": \"#/$defs/simpleTypes\" },",
  "                    \"minItems\": 1,", "                    \"uniqueItems\": true",
  "                }", "            ]", "        },", "        \"const\": true,",
  "        \"enum\": {", "            \"type\": \"array\",", "            \"items\": true",
  "        },", "        \"multipleOf\": {", "            \"type\": \"number\",",
  "            \"exclusiveMinimum\": 0", "        },", "        \"maximum\": {",
  "            \"type\": \"number\"", "        },", "        \"exclusiveMaximum\": {",
  "            \"type\": \"number\"", "        },", "        \"minimum\": {", "            \"type\": \"number\"",
  "        },", "        \"exclusiveMinimum\": {", "            \"type\": \"number\"",
  "        },", "        \"maxLength\": { \"$ref\": \"#/$defs/nonNegativeInteger\" },",
  "        \"minLength\": { \"$ref\": \"#/$defs/nonNegativeIntegerDefault0\" },",
  "        \"pattern\": {", "            \"type\": \"string\",", "            \"format\": \"regex\"",
  "        },", "        \"maxItems\": { \"$ref\": \"#/$defs/nonNegativeInteger\" },",
  "        \"minItems\": { \"$ref\": \"#/$defs/nonNegativeIntegerDefault0\" },",
  "        \"uniqueItems\": {", "            \"type\": \"boolean\",", "            \"default\": false",
  "        },", "        \"maxContains\": { \"$ref\": \"#/$defs/nonNegativeInteger\" },",
  "        \"minContains\": {", "            \"$ref\": \"#/$defs/nonNegativeInteger\",",
  "            \"default\": 1", "        },", "        \"maxProperties\": { \"$ref\": \"#/$defs/nonNegativeInteger\" },",
  "        \"minProperties\": { \"$ref\": \"#/$defs/nonNegativeIntegerDefault0\" },",
  "        \"required\": { \"$ref\": \"#/$defs/stringArray\" },", "        \"dependentRequired\": {",
  "            \"type\": \"object\",", "            \"additionalProperties\": {",
  "                \"$ref\": \"#/$defs/stringArray\"", "            }", "        }",
  "    },", "    \"$defs\": {", "        \"nonNegativeInteger\": {", "            \"type\": \"integer\",",
  "            \"minimum\": 0", "        },", "        \"nonNegativeIntegerDefault0\": {",
  "            \"$ref\": \"#/$defs/nonNegativeInteger\",", "            \"default\": 0",
  "        },", "        \"simpleTypes\": {", "            \"enum\": [", "                \"array\",",
  "                \"boolean\",", "                \"integer\",", "                \"null\",",
  "                \"number\",", "                \"object\",", "                \"string\"",
  "            ]", "        },", "        \"stringArray\": {", "            \"type\": \"array\",",
  "            \"items\": { \"type\": \"string\" },", "            \"uniqueItems\": true,",
  "            \"default\": []", "        }", "    }", "}",
])

///|
/// `https://json-schema.org/draft/2020-12/meta/unevaluated`（源自 raw/meta_unevaluated.json）。
let meta_text_unevaluated : String = join_lines([
  "{", "    \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",", "    \"$id\": \"https://json-schema.org/draft/2020-12/meta/unevaluated\",",
  "    \"$dynamicAnchor\": \"meta\",", "", "    \"title\": \"Unevaluated applicator vocabulary meta-schema\",",
  "    \"type\": [\"object\", \"boolean\"],", "    \"properties\": {", "        \"unevaluatedItems\": { \"$dynamicRef\": \"#meta\" },",
  "        \"unevaluatedProperties\": { \"$dynamicRef\": \"#meta\" }", "    }", "}",
])

///|
/// `https://json-schema.org/draft/2020-12/meta/meta-data`（源自 raw/meta_meta-data.json）。
let meta_text_meta_data : String = join_lines([
  "{", "    \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",", "    \"$id\": \"https://json-schema.org/draft/2020-12/meta/meta-data\",",
  "    \"$dynamicAnchor\": \"meta\",", "", "    \"title\": \"Meta-data vocabulary meta-schema\",",
  "", "    \"type\": [\"object\", \"boolean\"],", "    \"properties\": {", "        \"title\": {",
  "            \"type\": \"string\"", "        },", "        \"description\": {",
  "            \"type\": \"string\"", "        },", "        \"default\": true,",
  "        \"deprecated\": {", "            \"type\": \"boolean\",", "            \"default\": false",
  "        },", "        \"readOnly\": {", "            \"type\": \"boolean\",",
  "            \"default\": false", "        },", "        \"writeOnly\": {", "            \"type\": \"boolean\",",
  "            \"default\": false", "        },", "        \"examples\": {", "            \"type\": \"array\",",
  "            \"items\": true", "        }", "    }", "}",
])

///|
/// `https://json-schema.org/draft/2020-12/meta/format-annotation`（源自 raw/meta_format-annotation.json）。
let meta_text_format_annotation : String = join_lines([
  "{", "    \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",", "    \"$id\": \"https://json-schema.org/draft/2020-12/meta/format-annotation\",",
  "    \"$dynamicAnchor\": \"meta\",", "", "    \"title\": \"Format vocabulary meta-schema for annotation results\",",
  "    \"type\": [\"object\", \"boolean\"],", "    \"properties\": {", "        \"format\": { \"type\": \"string\" }",
  "    }", "}",
])

///|
/// `https://json-schema.org/draft/2020-12/meta/format-assertion`（源自 raw/meta_format-assertion.json）。
let meta_text_format_assertion : String = join_lines([
  "{", "    \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",", "    \"$id\": \"https://json-schema.org/draft/2020-12/meta/format-assertion\",",
  "    \"$dynamicAnchor\": \"meta\",", "", "    \"title\": \"Format vocabulary meta-schema for assertion results\",",
  "    \"type\": [\"object\", \"boolean\"],", "    \"properties\": {", "        \"format\": { \"type\": \"string\" }",
  "    }", "}",
])

///|
/// `https://json-schema.org/draft/2020-12/meta/content`（源自 raw/meta_content.json）。
let meta_text_content : String = join_lines([
  "{", "    \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",", "    \"$id\": \"https://json-schema.org/draft/2020-12/meta/content\",",
  "    \"$dynamicAnchor\": \"meta\",", "", "    \"title\": \"Content vocabulary meta-schema\",",
  "", "    \"type\": [\"object\", \"boolean\"],", "    \"properties\": {", "        \"contentEncoding\": { \"type\": \"string\" },",
  "        \"contentMediaType\": { \"type\": \"string\" },", "        \"contentSchema\": { \"$dynamicRef\": \"#meta\" }",
  "    }", "}",
])

///|
/// 元 schema 文档的 `(绝对 URI, 原文)` 列表。顺序固定。
pub fn metaschema_texts() -> Array[(String, String)] {
  [
    ("https://json-schema.org/draft/2020-12/schema", meta_text_schema),
    ("https://json-schema.org/draft/2020-12/meta/core", meta_text_core),
    (
      "https://json-schema.org/draft/2020-12/meta/applicator", meta_text_applicator,
    ),
    (
      "https://json-schema.org/draft/2020-12/meta/validation", meta_text_validation,
    ),
    (
      "https://json-schema.org/draft/2020-12/meta/unevaluated", meta_text_unevaluated,
    ),
    (
      "https://json-schema.org/draft/2020-12/meta/meta-data", meta_text_meta_data,
    ),
    (
      "https://json-schema.org/draft/2020-12/meta/format-annotation", meta_text_format_annotation,
    ),
    (
      "https://json-schema.org/draft/2020-12/meta/format-assertion", meta_text_format_assertion,
    ),
    ("https://json-schema.org/draft/2020-12/meta/content", meta_text_content),
  ]
}
