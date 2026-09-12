// 官方 JSON Schema draft 2020-12 元 schema 的编译期内联版本。
//
// 元 schema 就是「描述 schema 的 schema」。它的用途很具体：**检查一份
// schema 本身写得对不对**。`{"type":"sting"}` 这个笔误、`minLength: -1`
// 这种越界值、`required` 写成字符串而不是数组——这些都不是「校验实例时」
// 才发现的问题，而是 schema 自己的毛病。拿元 schema 校验一遍就能当场报出来。
//
// 数据本体在 meta_docs.mbt（生成物），原始 JSON 在 raw/。

///|
/// 官方 2020-12 元 schema 的绝对 URI。
pub fn metaschema_uri() -> String {
  "https://json-schema.org/draft/2020-12/schema"
}

///|
/// 官方 2020-12 元 schema 系列的全部文档，形如 `(绝对 URI, 文档节点)`。
///
/// 直接交给 `Schema::of_with_documents` 的第二个参数即可：
///
/// ```text
/// let docs = @metaschema.metaschema_documents()
/// let s = Schema::of_with_documents(schema_node, docs)
/// ```
///
/// 覆盖的文档共 9 份：根元 schema，加上 core / applicator / validation /
/// unevaluated / meta-data / format-annotation / format-assertion / content
/// 八个词汇表的元 schema。少任何一份，根元 schema 里那些
/// `{"$ref": "meta/xxx"}` 就解析不到。
pub fn metaschema_documents() -> Array[(String, Json)] {
  let out : Array[(String, Json)] = []
  for entry in metaschema_texts() {
    let uri = entry.0
    let parsed = try {
      Some(@json.parse(entry.1))
    } catch {
      _ => None
    }
    match parsed {
      Some(node) => out.push((uri, node))
      None => ()
    }
  }
  out
}

///|
/// 官方 2020-12 元 schema 的**文本**列表，形如 `(绝对 URI, 原文)`。
///
/// 给需要原文而不是解析结果的场合用（比如原样导出、做指纹比对）。
pub fn metaschema_text_pairs() -> Array[(String, String)] {
  metaschema_texts()
}
